#!perl
# vim:ts=4:sw=4:expandtab
# core
use Test::More;
use File::Temp qw(tempfile);
use IO::Handle;
use POSIX qw(setsid);
use Data::Dumper;

# libtest-mockmodule-perl
use Test::MockModule;
use Test::Deep;
use strict;
use warnings;
use AnyEvent::XMPP;
use AnyEvent::Util;
use AnyEvent::Socket;
use Kanla;

setsid();

sub test_send_alerts_to {
    my ($config, $num_msgs, $timeout_secs) = @_;

    # Provide a configuration file
    my ($fh, $filename) = tempfile(UNLINK => 1);
    $fh->autoflush(1);
    binmode($fh, ':utf8');
    say $fh $config;

    Kanla::run(configfile => $filename);

    my @messages;
    my $cv = AnyEvent->condvar;

    # Mock a lot of AnyEvent::XMPP modules
    # to ensure that messages from plugins
    # are actually sent over the wire
    # (in case we had a proper account configured).
    my $mock_conn = Test::MockModule->new('AnyEvent::XMPP::Connection');
    $mock_conn->mock(
        'send_message',
        sub {
            my ($self, $jid, $type, $unused, %args) = @_;
            push @messages, \%args;
            if (scalar @messages == $num_msgs) {
                $cv->send(1);
            }
        });

    my $conn = AnyEvent::XMPP::Connection->new();

    my $mock_account = Test::MockModule->new('AnyEvent::XMPP::IM::Account');
    $mock_account->mock('connection', sub { $conn });

    my $account = AnyEvent::XMPP::IM::Account->new();

    my $mockjid;
    my $mock_presence = Test::MockModule->new('AnyEvent::XMPP::IM::Presence');
    $mock_presence->mock('jid', sub { $mockjid });

    my $mock_xmpp = Test::MockModule->new('AnyEvent::XMPP::Client');
    $mock_xmpp->mock('find_account_for_dest_jid', sub { $account });
    $mock_xmpp->mock(
        'get_priority_presence_for_jid',
        sub {
            my ($self, $jid) = @_;
            $mockjid = $jid;
            AnyEvent::XMPP::IM::Presence->new();
        });

    my $timeout = AnyEvent->timer(
        after => $timeout_secs,
        cb    => sub { $cv->send(0) });

    $cv->recv;
    return @messages;
}

################################################################################
# Don’t specify silenced_by and check messages are sent.
################################################################################

my $fail_msg = {
    'body' => re(qr#If you read this message#),
};

my $http_msg = {
    'body' => re(qr#^(HTTP reply|Error while connecting to)#),
};

my $config = <<'EOCONF';
# kanla testcase config file
<jabber>
    jid      = "kanla@example.com"
    password = "kV9eJ4LZ9KRYOCec5W2witq"
</jabber>

consecutive_failures = 2
send_alerts_to = "testJID@example.com"

<monitor always fail>
    plugin = fail
    interval = 1
</monitor>
EOCONF

my @messages = test_send_alerts_to($config, 2, 2);
cmp_deeply([ \@messages ], set([ $fail_msg, $fail_msg ]), 'message received');

sub serve_and_close_connections {
    my $host;

    tcp_server(
        "127.0.0.1",
        undef,
        sub {
            my ($fh, $host, $port) = @_;
            shutdown($fh, 2);
            close($fh);
        },
        sub {
            my ($fh, $thishost, $thisport) = @_;
            $host = "localhost:$thisport";
            return undef;
        });

    return $host;
}

my $host = serve_and_close_connections();

################################################################################
# Silence “fail” by “http.*”
################################################################################

$config = <<EOCONF;
# kanla testcase config file
<jabber>
    jid      = "kanla\@example.com"
    password = "kV9eJ4LZ9KRYOCec5W2witq"
</jabber>

consecutive_failures = 2
send_alerts_to = "testJID\@example.com"

<monitor always fail>
    plugin = fail
    interval = 1
    silenced_by = http.http://localhost
</monitor>

<monitor always fail regexp>
    plugin = fail
    interval = 1
    silenced_by = /http..+/
</monitor>

<monitor http>
    plugin = http
    interval = 1
    url = http://$host
</monitor>
EOCONF

@messages = test_send_alerts_to($config, 2, 2);
cmp_deeply([ \@messages ], set([ $http_msg, $http_msg ]), 'no fail messages received');

################################################################################
# Silence “fail” by “http.*” globally
################################################################################

$config = <<EOCONF;
# kanla testcase config file
<jabber>
    jid      = "kanla\@example.com"
    password = "kV9eJ4LZ9KRYOCec5W2witq"
</jabber>

consecutive_failures = 2
silenced_by = /http..+/
send_alerts_to = "testJID\@example.com"

<monitor always fail>
    plugin = fail
    interval = 1
</monitor>

<monitor always fail regexp>
    plugin = fail
    interval = 1
</monitor>

<monitor http>
    plugin = http
    interval = 1
    url = http://$host
</monitor>
EOCONF

@messages = test_send_alerts_to($config, 2, 2);
cmp_deeply([ \@messages ], set([ $http_msg, $http_msg ]), 'no fail messages received');

done_testing;

# Kill all child processes,
# otherwise a 'prove' process hangs.
$SIG{TERM} = sub { };
kill('TERM', 0);
