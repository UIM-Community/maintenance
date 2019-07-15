package AXA::utils;

# Perl packages
use strict;
use Exporter qw(import);

# CA UIM Packages
use Nimbus::API;
use Nimbus::PDS;

# Third-party packages
use MIME::Base64;
use JSON;
use REST::Client;
use Encode;
use utf8;
use DateTime;
use Data::Dumper;

# Export utils functions
our @EXPORT_OK = qw(getMasterDeviceId parseAlarmVariable generateAlarm);

our $AUTH = "maintenance:m8te-nance";
our $HTTP_ADDR = "";

sub getMasterDeviceId {
    my ($Server) = @_;

    my $getinfo = REST::Client->new();
    my $header = {
        'Accept'        => 'application/json',
        'Authorization' => 'Basic '.encode_base64($AUTH)
    };
    $getinfo->setHost($HTTP_ADDR);
    my @json = ();

    $getinfo->GET('/uimapi/devices?type=perspective&name='.$Server.'&probeName=controller', $header);
    my $rc = $getinfo->responseCode();
    nimLog(0, "HTTP Request failed with the return code: $rc") if $rc ne 200;
    if ($rc eq 200) {
        @json = @{ decode_json($getinfo->responseContent()) };
        return $json[0]{'masterDeviceId'} if defined($json[0]{'masterDeviceId'});
        nimLog(1, "Failed to find the 'Master Device ID' !");
    }

    return undef;
}

sub parseAlarmVariable {
    my ($message, $hashRef) = @_;
    my $finalMsg    = $message;
    my $tMessage    = $message;
    my @matches     = ( $tMessage =~ /\$([A-Za-z0-9]+)/g );
    foreach (@matches) {
        next if not exists($hashRef->{"$_"});
        $finalMsg =~ s/\$\Q$_/$hashRef->{$_}/g;
    }
    return $finalMsg;
}

sub rndStr {
    return join '', @_[ map { rand @_ } 1 .. shift ];
}

sub nimId {
    my $A = rndStr(10, 'A'..'Z', 0..9);
    my $B = rndStr(5, 0..9);
    return "$A-$B";
}

sub generateAlarm {
    my ($subject, $hashRef) = @_;

    my $PDS = Nimbus::PDS->new(); 
    my $nimid = nimId();

    $PDS->string("nimid", $nimid);
    $PDS->number("nimts", time());
    $PDS->number("tz_offset", 0);
    $PDS->string("subject", $subject);
    $PDS->string("md5sum", "");
    $PDS->string("user_tag_1", $hashRef->{usertag1});
    $PDS->string("user_tag_2", $hashRef->{usertag2});
    $PDS->string("source", $hashRef->{source});
    $PDS->string("robot", $hashRef->{robot});
    $PDS->string("prid", $hashRef->{probe});
    $PDS->number("pri", $hashRef->{severity});
    $PDS->string("dev_id", $hashRef->{dev_id});
    $PDS->string("met_id", $hashRef->{met_id} || "");
    if (defined $hashRef->{supp_key}) { 
        $PDS->string("supp_key", $hashRef->{supp_key}) 
    };
    $PDS->string("suppression", $hashRef->{suppression});
    $PDS->string("origin", $hashRef->{origin});
    $PDS->string("domain", $hashRef->{domain});

    my $AlarmPDS = Nimbus::PDS->new(); 
    $AlarmPDS->number("level", $hashRef->{severity});
    $AlarmPDS->string("message", $hashRef->{message});
    $AlarmPDS->string("subsys", $hashRef->{subsystem} || "1.1.");
    if(defined $hashRef->{token}) {
        $AlarmPDS->string("token", $hashRef->{token});
    }

    $PDS->put("udata", $AlarmPDS, PDS_PDS);

    return ($PDS, $nimid);
}

1;
