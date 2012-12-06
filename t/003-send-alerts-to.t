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
use Kanla;

setsid();

sub test_send_alerts_to {
    my ($config, $expected) = @_;

    my $num_jids = scalar @$expected;

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
            ok($jid ~~ @$expected, 'JID expected');
            @$expected = grep { $_ ne $jid } @$expected;
            is(
                $args{body},
'Hello, this is the "fail" plugin. If you read this message, your setup seems to be working :-).',
                'message relayed untouched'
            );

            # Terminate this test successfully,
            # if @$expected is empty now
            # (meaning all JIDs were messaged).
            $cv->send(scalar @$expected == 0);
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

    # Timeout this test after 1s
    my $timeout = AnyEvent->timer(after => 1, cb => sub { $cv->send(1) });

    for (1 .. $num_jids) {
        last if ($cv->recv);
    }
}

################################################################################
# First test with send_alerts_to on global scope
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

test_send_alerts_to($config, ['testJID@example.com']);

################################################################################
# Then test with send_alerts_to overwritten
# on module level
################################################################################

$config = <<'EOCONF';
# kanla testcase config file
<jabber>
    jid      = "kanla@example.com"
    password = "kV9eJ4LZ9KRYOCec5W2witq"
</jabber>

send_alerts_to = "testJID@example.com"

<monitor always fail>
    send_alerts_to = "overwritten@example.com"
    plugin = fail
</monitor>
EOCONF

test_send_alerts_to($config, ['overwritten@example.com']);

################################################################################
# Test with multiple destination JIDs
################################################################################

$config = <<'EOCONF';
# kanla testcase config file
<jabber>
    jid      = "kanla@example.com"
    password = "kV9eJ4LZ9KRYOCec5W2witq"
</jabber>

send_alerts_to = <<EOT
testJID@example.com
test2@example.com
EOT

<monitor always fail>
    plugin = fail
</monitor>
EOCONF

test_send_alerts_to(
    $config,
    [
        'testJID@example.com',
        'test2@example.com',
    ]);

################################################################################
# Test with amended multiple JIDs
################################################################################

$config = <<'EOCONF';
# kanla testcase config file
<jabber>
    jid      = "kanla@example.com"
    password = "kV9eJ4LZ9KRYOCec5W2witq"
</jabber>

send_alerts_to = <<EOT
testJID@example.com
test2@example.com
EOT

<monitor always fail>
    send_alerts_to = <<EOT
$send_alerts_to
amended@example.com
EOT
    plugin = fail
</monitor>
EOCONF

test_send_alerts_to(
    $config,
    [
        'testJID@example.com',
        'test2@example.com',
        'amended@example.com',
    ]);

done_testing;

# Kill all child processes,
# otherwise a 'prove' process hangs.
$SIG{TERM} = sub { };
kill('TERM', 0);
