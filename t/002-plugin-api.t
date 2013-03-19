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

# Provide a configuration file
my ($fh, $filename) = tempfile(UNLINK => 1);
$fh->autoflush(1);
binmode($fh, ':utf8');
say $fh <<'EOT';
# kanla testcase config file
<jabber>
    jid      = "kanla@example.com"
    password = "kV9eJ4LZ9KRYOCec5W2witq"
</jabber>

send_alerts_to = "testJID@example.com"

<monitor always fail>
    plugin = fail
</monitor>
EOT

Kanla::run(configfile => $filename);

my $cv = AnyEvent->condvar;

# Mock a lot of AnyEvent::XMPP modules
# to ensure that messages from plugins
# are actually sent over the wire
# (in case we had a proper account configured).
my $mock_conn = Test::MockModule->new('AnyEvent::XMPP::Connection');
$mock_conn->mock('send_message', sub {
    my ($self, $jid, $type, $unused, %args) = @_;
    is($args{body}, 'Hello, this is the "fail" plugin. If you read this message, your setup seems to be working :-).', 'message relayed untouched');
    # Terminate this test successfully
    $cv->send(1)
});

my $conn = AnyEvent::XMPP::Connection->new();

my $mock_account = Test::MockModule->new('AnyEvent::XMPP::IM::Account');
$mock_account->mock('connection', sub { $conn });

my $account = AnyEvent::XMPP::IM::Account->new();

my $mock_presence = Test::MockModule->new('AnyEvent::XMPP::IM::Presence');
$mock_presence->mock('jid', sub { 'michael@stapelberg.de' });

my $mock_xmpp = Test::MockModule->new('AnyEvent::XMPP::Client');
$mock_xmpp->mock('find_account_for_dest_jid', sub { $account });
$mock_xmpp->mock('get_priority_presence_for_jid', sub {
    AnyEvent::XMPP::IM::Presence->new()
});

# Timeout this test after 1s
my $timeout = AnyEvent->timer(after => 1, cb => sub { $cv->send() });

my $retval = $cv->recv;
ok($retval, 'mocked send_message was called');

done_testing;

# Kill all child processes,
# otherwise a 'prove' process hangs.
$SIG{TERM} = sub { };
kill('TERM', 0);
