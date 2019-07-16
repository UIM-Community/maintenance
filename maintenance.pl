use 5.14.2;
use strict;
use warnings;

use lib '../../../perllib';
use lib '../../../perl/lib';
use lib '../../../perl/site/lib';
use lib '../../../perl/vendor/lib';
use lib './lib';

# CA UIM Packages
use Nimbus::API;
use Nimbus::Session;
use Nimbus::CFG;
use Nimbus::PDS;

# Perl packages
use threads;
use Thread::Queue;
use threads::shared;

# Internal Packages
use AXA::utils;

# CONSTANTS
use constant {
	MANAGED => "managed",
	UNMANAGED => "unmanaged"
};

#====================================================
# Globals
#====================================================
my $STR_Prgname   = 'maintenance';
my $STR_Version   = '1.00';
my $STR_Edition   = '15/07/2019';
my $MNT_QUEUE     = Thread::Queue->new();
my $STR_NBThreads = 3;
my $INT_GroupID   = 273;

#====================================================
# Configuration File
#====================================================
my $CFG           = Nimbus::CFG->new($STR_Prgname.".cfg");
my $INT_Loglevel  = defined($CFG->{"setup"}->{"loglevel"}) ? $CFG->{"setup"}->{"loglevel"} : 3;
my $INT_Logsize   = defined($CFG->{"setup"}->{"logsize"})  ? $CFG->{"setup"}->{"logsize"}  : 1024;
my $STR_Logfile   = defined($CFG->{"setup"}->{"logfile"})  ? $CFG->{"setup"}->{"logfile"}  : $STR_Prgname.".log";
my $STR_Login     = $CFG->{"setup"}->{"nim_login"} || "administrator";
my $STR_Password  = $CFG->{"setup"}->{"nim_password"};
my $CALLBACK_ADDR = $CFG->{"setup"}->{"maintenance_mode"} || "maintenance_mode";

my $HTTP_HOST     = $CFG->{"uimapi"}->{"api_host"} || '127.0.0.1';
my $HTTP_USER     = $CFG->{"uimapi"}->{"api_user"} || 'maintenance';
my $HTTP_PASS     = $CFG->{"uimapi"}->{"api_pass"};
my $HTTP_PORT     = $CFG->{"uimapi"}->{"api_port"} || 8080;
my $HTTP_PROTOCOL = $CFG->{"uimapi"}->{"api_protocol"} || 'http';

my $MESSAGES      = defined($CFG->{"messages"}) ? $CFG->{"messages"} : {};

my $HTTP_ADDR     = "$HTTP_PROTOCOL://$HTTP_HOST:$HTTP_PORT";
$AXA::utils::HTTP_ADDR = $HTTP_ADDR;
$AXA::utils::AUTH = "$HTTP_USER:$HTTP_PASS";

# Authenticate if nim_login & nim_password are defined
nimLogin("$STR_Login","$STR_Password") if defined($STR_Login) && defined($STR_Password);

#====================================================
# Log File
#====================================================
nimLogSet($STR_Logfile, $STR_Prgname, $INT_Loglevel, 0);
nimLogTruncateSize($INT_Logsize * 1024);
nimLog(0, "****************[ Starting ]****************");
nimLog(0, "Probe $STR_Prgname version $STR_Version");
nimLog(0, "AXA Invest Manager, Copyright @ 2018-2020");

#====================================================
# DIE HANDLER
#====================================================
$SIG{__DIE__} = \&scriptDieHandler;
sub scriptDieHandler {
    my ($err) = @_;
    print STDERR "$err\n";
    nimLog(0, "$err");
    exit(1);
}

#====================================================
# Create alarm
#====================================================
sub createAlarm {
    my ($alarmName, $robot, $source, $addVars) = @_;
    my $currAlarm = $MESSAGES->{$alarmName};

    my $defaultVars = {
        robot => $robot, source => $source
    };
    $defaultVars = { %$defaultVars, %$addVars };
    my $suppkey = AXA::utils::parseAlarmVariable($currAlarm->{supp_key}, $defaultVars);
    my $message = AXA::utils::parseAlarmVariable($currAlarm->{message}, $defaultVars); 

    my ($PDSAlarm, $nimid) = AXA::utils::generateAlarm("alarm", {
        robot       => $robot,
        source      => $source,
        met_id      => "",
        dev_id      => "",
        hubName     => $localAgent->{hubname},
        domain      => $localAgent->{domain},
        usertag1    => $localAgent->{os_user1},
        usertag2    => $localAgent->{os_user2},
        severity    => $currAlarm->{severity},
        subsys      => $currAlarm->{subsystem},
        origin      => $MESSAGES->{default_origin},
        probe       => $STR_Prgname,
        message     => $message,
        supp_key    => $suppkey,
        suppression => $suppkey
    });
    nimLog(3, "Generate new (raw) alarm with id $nimid");

    # Launch alarm!
    my ($RC) = nimRequest($localAgent->{robotname}, 48001, "post_raw", $PDSAlarm->data);
    if($RC != NIME_OK) {
        my $errorTxt = nimError2Txt($RC);
        nimLog(2, "Failed to generate alarm, RC => $RC :: $errorTxt");
    }
}

#====================================================
# Retrieve local NimSoft agent
#====================================================
my ($RC_INFO, $getInfoPDS) = nimNamedRequest("controller", "get_info");
scriptDieHandler(
    "Failed to establish a communication with the local controller probe!"
) if $RC_INFO != NIME_OK;
my $localAgent = Nimbus::PDS->new($getInfoPDS)->asHash();

#====================================================
# Threads pools
#====================================================
my $thrHandler;
$thrHandler = sub {
    nimLog(3, "Thread started!");
    while ( defined ( my $options = $MNT_QUEUE->dequeue() ) ) {
        my $Server = $options->{server};
        my $State = $options->{state};

        # Retrieve Server Master Id
        my $result = AXA::utils::getMasterDeviceId($Server);
        my $MasterDeviceID = $result->{devId};
        if ($result->{statusCode} eq "200" && not defined($MasterDeviceID)) {
            nimLog(0, "[$Server] MasterDeviceID not found");
            createAlarm("device_not_found", $localAgent->{robotname}, $Server, {
                api => $HTTP_ADDR
            });
            next;
        }
        else if ($result->{statusCode} ne "200") {
            nimLog(0, "[$Server] http request for MasterDeviceID failed (reason: $result->{statusCode})");
            createAlarm("http_request_fail", $localAgent->{robotname}, $Server, {
                api => $HTTP_ADDR,
                statusCode => $result->{statusCode},
                reason => $result->{reason}
            });
        }
        nimLog(3, "[$Server] MasterDeviceID => $MasterDeviceID");

        my $DATA = Nimbus::PDS->new();
        $DATA->put("scheduleId", "$INT_GroupID", PDS_PCH);
        $DATA->put("csIds", "$MasterDeviceID", PDS_PCH);

        my $callbackName = $State eq MANAGED ? 
            "remove_computer_systems_from_schedule" :
            "add_computer_systems_to_schedule";
        my ($RC, $RES) = nimNamedRequest($CALLBACK_ADDR, $callbackName, $DATA->data);
        if ($RC != NIME_OK) {
            nimLog(0, "The Callback request failed. nimNamedRequest() rc: $RC.");
            createAlarm("callback_failed", $Server, $localAgent->{robotname}, {
                callback => $callbackName,
            });

            next;
        }

        my $SuccessMsg = $State eq MANAGED ?
            "Server '$Server' successfully removed from the maintenance state" :
            "Server '$Server' successfully placed in maintenance state";
        nimLog(1, $SuccessMsg);
    }
    nimLog(3, "Thread finished!");
};

# Wait for group threads
my @thr = map {
    threads->create(\&$thrHandler);
} 1..$STR_NBThreads;
$_->detach() for @thr;

# CALLBACK Declarations
sub managed {
    my ($hMsg, $hostname) = @_;
    nimLog(3, "managed callback triggered with hostname '$hostname'");

    $MNT_QUEUE->enqueue({ server => $hostname, state => MANAGED });
    nimSendReply($hMsg);
}

sub unmanaged {
    my ($hMsg, $hostname) = @_;
    nimLog(3, "unmanaged callback triggered with hostname '$hostname'");

    $MNT_QUEUE->enqueue({ server => $hostname, state => UNMANAGED });
    nimSendReply($hMsg);
}

sub get_master_device_id {
    my ($hMsg, $hostname) = @_;
    nimLog(3, "Get Master Device ID for hostname: '$hostname'");

    my $result = AXA::utils::getMasterDeviceId($hostname);
    my $PDS = Nimbus::PDS->new();
    if (result->{statusCode} eq "200") {
        if (defined $result->{devId}) {
            $PDS->number("id", $result->{devId});
            nimSendReply($hMsg, NIME_OK, $PDS->data);
        }
        else {
            $PDS->string("reason", "Unable to found Device ID for hostname '$hostname'");
            nimSendReply($hMsg, NIME_ERROR, $PDS->data);
        }
    }
    else {
        $PDS->string("reason", $result->{reason});
        nimSendReply($hMsg, NIME_ERROR);
    }
}

sub timeout {
    # Do something, normally you would put your monitoring code
    # here, checking the elapsed time.
}

sub restart {
    # Reload configuration, etc...
}

my $sess = Nimbus::Session->new($STR_Prgname);
$sess->setInfo($STR_Version, "AXA IM");
 
if ($sess->server (NIMPORT_ANY,\&timeout,\&restart)==0) {
    $sess->addCallback("managed", "hostname");
    $sess->addCallback("unmanaged", "hostname");
    $sess->addCallback("get_master_device_id", "hostname");
    $sess->dispatch();
}
