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

setsid();

# This is a simplified version of Kanla.pm’s start_plugin.
sub test_plugin {
    my ($plugin, $config, $num_msgs, $expected) = @_;

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
            push @messages, $hashref;
            if (scalar @messages == $num_msgs) {
                $test_cv->send(1);
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

    # Timeout this test after 2s,
    # plugins have a timeout of 1s.
    my $timeout = AnyEvent->timer(
        after => 2,
        cb    => sub {
            diag('plugin timeout (2s)');
            $test_cv->send(0);
        });

    $test_cv->recv;
    cmp_deeply(\@messages, $expected, 'plugin messages match expectation');
}

################################################################################
# Bind to a port,
# but immediately close incoming connections.
# Verify that the plugin fails
# with the appropriate message.
################################################################################

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

my $config = <<EOCONF;
plugin = http
url = http://$host
timeout = 1
EOCONF

test_plugin(
    'http', $config, 2,
    set({
            'severity' => 'critical',
            'message'  => re(
                qr#^HTTP reply 59\d for http://localhost:[0-9]+ \(127.0.0.1\)#),
        },
        {
            'severity' => 'critical',
            'message'  => re(
                qr#^HTTP reply 59\d for http://localhost:[0-9]+ \(::1\)#
            ),
        },

    ));

################################################################################
# Bind to a port,
# but don’t send anything.
# Verify that the plugin fails
# with the appropriate message.
################################################################################

tcp_server(
    "127.0.0.1",
    undef,
    sub {
        my ($fh, $host, $port) = @_;
        my $t;
        $t = AnyEvent->timer(
            after => 10,
            cb    => sub {
                syswrite($fh, "timeout exceeded.\r\n");
                undef $t;
            });
    },
    sub {
        my ($fh, $thishost, $thisport) = @_;
        $host = "localhost:$thisport";
        return undef;
    });

$config = <<EOCONF;
plugin = http
url = http://$host
timeout = 1
EOCONF

test_plugin(
    'http', $config, 2,
    set({
            'severity' => 'critical',
            'message'  => re(
                qr#^HTTP reply 59\d for http://localhost:[0-9]+ \(127.0.0.1\)#),
        },
        {
            'severity' => 'critical',
            'message'  => re(
                qr#^HTTP reply 59\d for http://localhost:[0-9]+ \(::1\)#
            ),
        },

    ));

################################################################################
# Bind to a port,
# but send a wrong greeting.
# Verify that the plugin fails
# with the appropriate message.
################################################################################

tcp_server(
    "127.0.0.1",
    undef,
    sub {
        my ($fh, $host, $port) = @_;
        syswrite(
            $fh,
            "PROPRIETARY SERVICE READY. SEND CLEARTEXT PASSWORDS NOW!\r\n"
        );
        close($fh);
    },
    sub {
        my ($fh, $thishost, $thisport) = @_;
        $host = "localhost:$thisport";
        return undef;
    });

$config = <<EOCONF;
plugin = http
url = http://$host
timeout = 1
EOCONF

test_plugin(
    'http', $config, 2,
    set({
            'severity' => 'critical',
            'message'  => re(
                qr#^HTTP reply 59\d for http://localhost:[0-9]+ \(127.0.0.1\)#),
        },
        {
            'severity' => 'critical',
            'message'  => re(
                qr#^HTTP reply 59\d for http://localhost:[0-9]+ \(::1\)#
            ),
        },

    ));

################################################################################
# Bind to a port,
# send correct greeting.
# Verify that the plugin
# does not fail.
################################################################################

tcp_server(
    "127.0.0.1",
    undef,
    sub {
        my ($fh, $host, $port) = @_;
        syswrite(
            $fh,
            "HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n",
        );
        close($fh);
    },
    sub {
        my ($fh, $thishost, $thisport) = @_;
        $host = "localhost:$thisport";
        return undef;
    });

$config = <<EOCONF;
plugin = http
url = http://$host
timeout = 1
EOCONF

test_plugin(
    'http', $config, 1,
    set({
            'severity' => 'critical',
            'message'  => re(
                qr#^HTTP reply 59\d for http://localhost:[0-9]+ \(::1\)#
            ),
        },

    ));

################################################################################
# Bind to a port,
# send correct greeting,
# but error message in body.
# Verify that the plugin
# fails with the appropriate error message.
################################################################################

tcp_server(
    "127.0.0.1",
    undef,
    sub {
        my ($fh, $host, $port) = @_;
        syswrite(
            $fh,
"HTTP/1.0 200 OK\r\nContent-Length: 24\r\n\r\nFailed to query backend.",
        );
        close($fh);
    },
    sub {
        my ($fh, $thishost, $thisport) = @_;
        $host = "localhost:$thisport";
        return undef;
    });

$config = <<EOCONF;
plugin = http
url = http://$host
timeout = 1
EOCONF
$config .= <<'EOCONF';
body = <<EOT
/Latest release: \d/
EOT
EOCONF

test_plugin(
    'http', $config, 2,
    set({
            'severity' => 'critical',
            'message'  => re(
qr#^HTTP body of http://localhost:[0-9]+ \(127.0.0.1\) does not match regexp /Latest release: \\d/#
            ),
        },
        {
            'severity' => 'critical',
            'message'  => re(
                qr#^HTTP reply 59\d for http://localhost:[0-9]+ \(::1\)#
            ),
        },

    ));

################################################################################
# Bind to a port,
# send correct greeting,
# but error message in body.
# Verify that the plugin
# fails with the appropriate error message.
################################################################################

tcp_server(
    "127.0.0.1",
    undef,
    sub {
        my ($fh, $host, $port) = @_;
        syswrite(
            $fh,
            "HTTP/1.0 200 OK\r\nContent-Length: 17\r\n\r\nLatest release: 3",
        );
        close($fh);
    },
    sub {
        my ($fh, $thishost, $thisport) = @_;
        $host = "localhost:$thisport";
        return undef;
    });

$config = <<EOCONF;
plugin = http
url = http://$host
timeout = 1
EOCONF
$config .= q#body = "/Latest release: \\d/"#;

test_plugin(
    'http', $config, 1,
    set({
            'severity' => 'critical',
            'message'  => re(
                qr#^HTTP reply 59\d for http://localhost:[0-9]+ \(::1\)#
            ),
        },

    ));

done_testing;

# Kill all child processes,
# otherwise a 'prove' process hangs.
$SIG{TERM} = sub { };
kill('TERM', 0);
