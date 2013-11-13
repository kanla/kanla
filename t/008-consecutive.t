#!perl
# vim:ts=4:sw=4:expandtab
# core
use Test::More;
use File::Temp qw(tempfile);
use IO::Handle;
use POSIX qw(setsid);

# libtest-mockmodule-perl
use Test::MockModule;
use strict;
use warnings;
use AnyEvent::XMPP;
use Kanla;

setsid();

sub test_send_alerts_to {
    my ($config, $timeout_secs) = @_;

    # Provide a configuration file
    my ($fh, $filename) = tempfile(UNLINK => 1);
    $fh->autoflush(1);
    binmode($fh, ':utf8');
    say $fh $config;

    Kanla::run(configfile => $filename);

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
            is(
                $args{body},
'Hello, this is the "fail" plugin. If you read this message, your setup seems to be working :-).',
                'message relayed untouched'
            );

            $cv->send(1);
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

    return $cv->recv;
}

################################################################################
# Don’t specify consecutive_failures and check messages are sent right away.
################################################################################

my $config = <<'EOCONF';
# kanla testcase config file
<jabber>
    jid      = "kanla@example.com"
    password = "kV9eJ4LZ9KRYOCec5W2witq"
</jabber>

send_alerts_to = "testJID@example.com"

<monitor always fail>
    plugin = fail
</monitor>
EOCONF

ok(test_send_alerts_to($config, 0.9), 'message received within 0.9s');

################################################################################
# Check the message is sent after $interval with consecutive_failures = 2
################################################################################

$config = <<'EOCONF';
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

ok(
    !test_send_alerts_to($config, 0.9),
    'no message received within the first 0.9s'
);

ok(test_send_alerts_to($config, 1.9), 'message received after 1.9s');

done_testing;

# Kill all child processes,
# otherwise a 'prove' process hangs.
$SIG{TERM} = sub { };
kill('TERM', 0);
