#!perl
# vim:ts=4:sw=4:expandtab
# core
use Test::More;
use Test::Deep;
use File::Temp qw(tempfile);
use IO::Handle;
use POSIX qw(setsid);
use Data::Dumper;
use strict;
use warnings;
use utf8;
use Kanla;

# libanyevent-perl
use AnyEvent;
use AnyEvent::Util;
use AnyEvent::Socket;
use Time::HiRes qw/ time sleep /;


setsid();


# This is a simplified version of Kanla.pm’s start_plugin.
sub test_plugin {
    my ($plugin, $config, $num_msgs) = @_;
    my $finished = 0;

    my ($pr, $pw) = AnyEvent::Util::portable_pipe;
    fcntl($pr, AnyEvent::F_SETFD, AnyEvent::FD_CLOEXEC);
    my $w;
    $w = AnyEvent::Handle->new(
        fh       => $pr,
        on_error => sub {
            my ($hdl, $fatal, $msg) = @_;
            diag("error reading from stderr: $msg");
            $w->destroy;
        });

    my @messages;
    my $test_cv = AnyEvent->condvar;

    my @start_request;
    @start_request = (
        json => sub {
            my ($hdl, $hashref) = @_;
            return if($finished);

            push @messages, $hashref;
            # do not end early
            # to check that plugins don’t produce additional messages
            if (scalar @messages == $num_msgs + 1) {
                diag("Produced additional message for plugin=$plugin");
                $test_cv->send(0);
            }
            $hdl->push_read(@start_request);
        });

    $w->push_read(@start_request);

    my $cv = run_cmd ["plugins/$plugin"],
        # feed the config on stdin
        '<', \$config,

        # stdout goes to /dev/null for now.
        '>', '/dev/null',

        # TODO: proxy stderr into our log so that one can easily spot plugin failures
        '3>', $pw;
    $cv->cb(
        sub {
            my $status = shift->recv;
            diag("exited with exit code $status");
            $test_cv->send(0);
        });

    # Timeout this test after 1.5s,
    # plugins have a timeout of 1s.
    # With an interval of 1s
    # this allows a plugin to fail two times
    # without running into race conditions.
    my $timeout = AnyEvent->timer(
        after => 1.5,
        cb    => sub {
            $test_cv->send(1);
        });

    $test_cv->recv;
    $finished = 1;
    ok(scalar @messages eq $num_msgs, 'plugin sends expected amount of messages');
}


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

################################################################################
# Verify that the http plugin
# repeats test after configured interval.
################################################################################

my $host = serve_and_close_connections();

my $config = <<EOCONF;
plugin = http
url = http://$host
timeout = 1
interval = 1
family = ipv4
EOCONF

test_plugin('http', $config, 2);

################################################################################
# Verify that the redis plugin
# repeats test after configured interval.
################################################################################

$host = serve_and_close_connections();

$config = <<EOCONF;
plugin = redis
host = $host
family = ipv4
timeout = 1
interval = 1
EOCONF

test_plugin('redis', $config, 2);

################################################################################
# Verify that the smtp plugin
# repeats test after configured interval.
################################################################################

$host = serve_and_close_connections();

$config = <<EOCONF;
plugin = smtp
host = $host
timeout = 1
interval = 1
family = ipv4
EOCONF

test_plugin('smtp', $config, 2);

done_testing;

# Kill all child processes,
# otherwise a 'prove' process hangs.
$SIG{TERM} = sub { };
kill('TERM', 0);
