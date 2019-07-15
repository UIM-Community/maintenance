package src::utils;

# Perl packages
use strict;
use Exporter qw(import);

# Third-party packages
use MIME::Base64;
use JSON;
use REST::Client;
use Encode;
use utf8;
use DateTime;
use Data::Dumper;

# Export utils functions
our @EXPORT_OK = qw(getMasterDeviceId);

# CONSTANTS
my $STR_API = 'http://10.130.37.121:8080';

sub getMasterDeviceId {
    my ($Server) = @_;

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

    for (1..3) {
        $getinfo->GET($getinfoURL, header);
        my $rc = $getinfo->responseCode();
        nimLog(0, "HTTP Request failed with the return code: $rc") if $rc ne 200;
        if ($rc eq 200) {
            @json = @{ decode_json($getinfo->responseContent()) };
            last if defined($json[0]{'masterDeviceId'});
            nimLog(1, "Failed to find the 'Master Device ID' !");
        }

        return undef if $retry eq 3;

        $retry++;
        sleep 10;
    }

    return $json[0]{'masterDeviceId'};
}

1;