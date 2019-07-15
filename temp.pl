use 5.14.2;
use strict;
use warnings;

use lib 'N:/Nimsoft/perllib';
use lib 'N:/Nimsoft/perl/lib';
use lib 'N:/Nimsoft/perl/site/lib';
use lib 'N:/Nimsoft/perl/vendor/lib';

### CA UIM Packages
use Nimbus::API;
use Nimbus::Session;
use Nimbus::CFG;
use Nimbus::PDS;

use MIME::Base64;
use JSON;
use REST::Client;
use Encode;
use utf8;
use DateTime;
use Data::Dumper;

use constant {
	MANAGED => "managed",
	UNMANAGED => "unmanaged"
};

#====================================================
# Globals
#====================================================
$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME}=0;
my $STR_Prgname  = 'ChangeUIMstatus';
my $STR_Version  = '2.00';
my $STR_Edition  = 'Apr 01 2019';
my $STR_API      = 'http://10.130.37.121:8080';
my $retry;

#====================================================
# Configuration File
#====================================================
my $CFG          = Nimbus::CFG->new($STR_Prgname.".cfg");
my $INT_Loglevel = defined($CFG->{"setup"}->{"loglevel"}) ? $CFG->{"setup"}->{"loglevel"} : 0;
my $INT_Logsize  = defined($CFG->{"setup"}->{"logsize"})  ? $CFG->{"setup"}->{"logsize"}  : 1024;
my $STR_Logfile  = defined($CFG->{"setup"}->{"logfile"})  ? $CFG->{"setup"}->{"logfile"}  : $STR_Prgname.".log";
my $INT_debug    = defined($CFG->{"setup"}->{"debug"})    ? $CFG->{"setup"}->{"debug"}    : 0;
my $STR_Login    = $CFG->{"setup"}->{"nim_login"} || "administrator";
my $STR_Password = $CFG->{"setup"}->{"nim_password"};

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
# Function :: Date Time
#====================================================
sub datetime
{
	my @months = qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );
	my @days = qw( Sun Mon Tue Wed Thu Fri Sat Sun );
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
	# 10/05/2019 - 11:00:48.07
	my $datetime = sprintf("%02d/%02d/%4d - %02d:%02d:%02d.%02d",$mday,$mon+1,$year+1900,$hour,$min,$sec,"00");
	return $datetime
}

#====================================================
# Detect the Server Name and the state
#====================================================
my $ARG1 = lc($ARGV[0]);
my $ARG2 = lc($ARGV[1]);
my $Server;
my $State;
if ( !defined($ARG1) || !defined($ARG2) || $ARG1 eq "" || $ARG2 eq "" )
{
	die("One of the arguments is not consistent.");
}
if ( $ARG1 eq MANAGED || $ARG1 eq UNMANAGED )
{
	$Server = $ARG2;
	$State  = $ARG1;
}
elsif ( $ARG2 eq MANAGED || $ARG2 eq UNMANAGED )
{
	$Server = $ARG1;
	$State  = $ARG2;
}
else
{
	die("One of the arguments is not consistent.");
}

#====================================================
# Function :: Log File
#====================================================
my $time = time;
my $logdir="N:/Nimsoft/probes/application/maintenance/scripts/logs/$time-$Server-$State.log";
sub logit
{
	my $level = shift;
	my $message = shift;
	my @severity = qw( PERL WARN CRIT );
	my $fh;
	open($fh, '>>', $logdir) or die "$logdir: $!";
	my $now = datetime();
	print $fh $now." [".$severity[$level]."] ".$message."\n";
	close($fh);
	print $now." [".$severity[$level]."] ".$message."\n";
}

logit(0, "================ PERL SCRIPT ===============");
logit(0, "Probe $STR_Prgname version $STR_Version");
logit(0, "AXA Invest Manager, Copyright @ 2018-2020");
logit(0, "--------------------------------------------");
logit(0, "Server: $Server");
logit(0, "State: $State");

#====================================================
# Nimsoft :: Authentification
#====================================================
my ($nimLoginID) = nimLogin('administrator', 'NimSoft!01');
if(not defined $nimLoginID) {
    nimLog(0, "Failed to authenticate the script to NimBUS !");
    logit(0,  "Failed to authenticate the script to NimBUS !");
    exit 1;
}

#====================================================
# Retrieve target 'Device ID'
#====================================================
logit(0, "CA UIM API - Get Infos - Web Service Call ...");
my $getinfo = REST::Client->new();
my $auth = encode_base64("maintenance:m8te-nance");
my $header = {
    'Accept'        => 'application/json',
    'Authorization' => 'Basic '.$auth
};
$getinfo->setHost($STR_API);
my $getinfoURL = '/uimapi/devices?type=perspective&name='.$Server.'&probeName=controller';
$retry = 1;
my @json = ();
my $rc;
for (1 .. 3)
{
	$getinfo->GET($getinfoURL,$header);
	$rc = $getinfo->responseCode();
	if ( $rc eq 200 )
	{
		@json = @{ decode_json($getinfo->responseContent()) };
		if ( !defined($json[0]{'masterDeviceId'}) )
		{
			logit(2, "Failed to find the 'Master Device ID' !");
			exit(1);
		}
		last;
	}
	logit(1, "HTTP Request failed with the return code: $rc");
	if ( $retry eq 3 )
	{
		logit(2, "The HTTP request failed. Too many attempt (3)");
		exit(1);
	}
	$retry++;
	sleep 10;
}
my $CorrelationDeviceID = $json[0]{'id'};
my $MasterDeviceID      = $json[0]{'masterDeviceId'};
my $ControllerDeviceID  = $json[0]{'probeProperties'}[0]{'value'};
logit(0, "HTTPS Request :: return code: <$rc> !");
logit(0, "Agent's IDs:");
logit(0, "Correlation: $CorrelationDeviceID");
logit(0, "Master:      $MasterDeviceID");
logit(0, "Controller:  $ControllerDeviceID");

#====================================================
# Call Maintenance Mode (CA UIM Rest API)
#====================================================
logit(0, "CA UIM Callback (LEGACY) - Maintenance($State) - nimNamedRequest() ...");

my $DATA = Nimbus::PDS->new();
$DATA->put("scheduleId", "273",             PDS_PCH);
$DATA->put("csIds",      "$MasterDeviceID", PDS_PCH);

my $Callback = $State == MANAGED ? "remove_computer_systems_from_schedule" : "add_computer_systems_to_schedule";
my ($RC, $RES) = nimNamedRequest("/AXA-IM_PROD/FR1AS1IT1-0047/FR1AS1IT1-0047/maintenance_mode", $Callback, $DATA->data);
logit(0, "The Callback request failed. nimNamedRequest() rc: $RC.") if $RC != NIME_OK;

given ($State) {
	when(UNMANAGED) {
		logit(0, "Server '$Server' successfully placed in maintenance state") if $RC == NIME_OK;
	}
	when(MANAGED) {
		logit(0, "Server '$Server' successfully removed from the maintenance state") if $RC == NIME_OK;
	}
}
exit(0);
