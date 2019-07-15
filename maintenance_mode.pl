use 5.14.2;
use strict;
use warnings;

use lib 'N:/Nimsoft/perllib';
use lib 'N:/Nimsoft/perl/lib';
use lib 'N:/Nimsoft/perl/site/lib';
use lib 'N:/Nimsoft/perl/vendor/lib';

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
use src::utils;

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

#====================================================
# Configuration File
#====================================================
my $CFG           = Nimbus::CFG->new($STR_Prgname.".cfg");
my $INT_Loglevel  = defined($CFG->{"setup"}->{"loglevel"}) ? $CFG->{"setup"}->{"loglevel"} : 3;
my $INT_Logsize   = defined($CFG->{"setup"}->{"logsize"})  ? $CFG->{"setup"}->{"logsize"}  : 1024;
my $STR_Logfile   = defined($CFG->{"setup"}->{"logfile"})  ? $CFG->{"setup"}->{"logfile"}  : $STR_Prgname.".log";
my $STR_Login     = $CFG->{"setup"}->{"nim_login"} || "administrator";
my $STR_Password  = $CFG->{"setup"}->{"nim_password"};

my $CALLBACK_ADDR = $CFG->{"config"}->{"addr"} || "/AXA-IM_PROD/FR1AS1IT1-0047/FR1AS1IT1-0047/maintenance_mode";
my $HTTP_ADDR     = $CFG->{"config"}->{"http_addr"} || 'http://10.130.37.121:8080';

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

# Execute the routine scriptDieHandler if the script die for any reasons
$SIG{__DIE__} = \&scriptDieHandler;

# Routine triggered when the script have to die
sub scriptDieHandler {
    my ($err) = @_;
    print STDERR "$err\n";
    nimLog(0, "$err");
    exit(1);
}

my $thrHandler;
$thrHandler = sub {
    nimLog(3, "Thread started!");
    while ( defined ( my $options = $MNT_QUEUE->dequeue() ) ) {
        my $Server = $options->{server};
        my $State = $options->{state};

        # Retrieve Server Master Id
        my $MasterDeviceID = src::utils::getMasterDeviceId($HTTP_ADDR, $Server);
        if (!defined($MasterDeviceID)) {
            next;
        }
        nimLog(3, "[$Server] MasterDeviceID => $MasterDeviceID");

        my $DATA = Nimbus::PDS->new();
        $DATA->put("scheduleId", "273", PDS_PCH);
        $DATA->put("csIds", "$MasterDeviceID", PDS_PCH);

        my $callbackName = $State eq MANAGED ? 
            "remove_computer_systems_from_schedule" :
            "add_computer_systems_to_schedule";
        my ($RC, $RES) = nimNamedRequest($CALLBACK_ADDR, $callbackName, $DATA->data);
        if ($RC != NIME_OK) {
            nimLog(0, "The Callback request failed. nimNamedRequest() rc: $RC.");
            next;
        }

        my $SuccessMsg = $State == MANAGED ?
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
    my ($hMsg, $serverName) = @_;
    nimLog(3, "managed callback triggered with server '$serverName'");
    $MNT_QUEUE->enqueue({
        server => $serverName, state => MANAGED
    });

    nimSendReply($hMsg);
}

sub unmanaged {
    my ($hMsg, $serverName) = @_;
    nimLog(3, "unmanaged callback triggered with server '$serverName'");
    $MNT_QUEUE->enqueue({
        server => $serverName, state => UNMANAGED
    });

    nimSendReply($hMsg);
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
    $sess->addCallback("managed", "serverName");
    $sess->addCallback("unmanaged", "serverName");

    nimLog(3, "Dispatch timeout callback at 10,000ms");
    $sess->dispatch(10000);
}
