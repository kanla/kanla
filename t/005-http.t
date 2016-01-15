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
    if (!cmp_deeply(\@messages, $expected, 'plugin messages match expectation'))
    {
        diag('messages = ' . Dumper(\@messages));
        diag('expected = ' . Dumper($expected));
    }
}

sub serve {
    my ($content) = @_;
    my $host;

    tcp_server(
        "127.0.0.1",
        undef,
        sub {
            my ($fh, $host, $port) = @_;
            syswrite(
                $fh,
                $content,
            );
            close($fh);
        },
        sub {
            my ($fh, $thishost, $thisport) = @_;
            $host = "localhost:$thisport";
            return undef;
        });

    return $host;
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

sub serve_with_basic_authentication {
    my $host;
    tcp_server(
        "127.0.0.1",
        undef,
        sub {
            my ($fh, $host, $port) = @_;
            my $handle;
            $handle = AnyEvent::Handle->new(
                fh     => $fh,
                on_eof => sub {
                    $handle->destroy;
                });

            $handle->push_read(
                line => "\015\012\015\012",
                sub {
                    my ($handle, $headers) = @_;
                    # i.e. ilove:kanla
                    if ($headers =~ /Authorization: Basic aWxvdmU6a2FubGE=/) {
                        $handle->push_write(
"HTTP/1.0 200 OK\r\nContent-Length: 16\r\n\r\nYes, yes you do."
                        );
                    } else {
                        $handle->push_write(
"HTTP/1.0 401 Unauthorized\r\nContent-Length: 19\r\n\r\nYou are not worthy."
                        );
                    }
                });
        },
        sub {
            my ($fh, $thishost, $thisport) = @_;
            $host = "localhost:$thisport";
            return undef;
        });

    return $host;
}

my $check_ipv4_unauthorized = {
    'severity' => 'critical',
    'message' =>
        re(qr#^HTTP reply 401 for http://localhost:[0-9]+ \(127.0.0.1\)#),
    'id' => ignore(),
};
my $check_ipv4_fail = {
    'severity' => 'critical',
    'message'  => re(
qr#^Error while connecting to http://localhost:[0-9]+ \(127.0.0.1\): (Connection refused|Connection timed out|Broken pipe)#
    ),
    'id' => ignore(),
};
my $check_ipv6_fail = {
    'severity' => 'critical',
    'message'  => re(
qr#^Error while connecting to http://localhost:[0-9]+ \(::1\): (Connection refused|Connection timed out|Broken pipe)#
    ),
    'id' => ignore(),
};

################################################################################
# Bind to a port,
# but immediately close incoming connections.
# Verify that the plugin fails
# with the appropriate message.
################################################################################

my $host = serve_and_close_connections();

my $config = <<EOCONF;
plugin = http
url = http://$host
timeout = 1
EOCONF

test_plugin('http', $config, 2, set($check_ipv4_fail, $check_ipv6_fail));

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

test_plugin('http', $config, 2, set($check_ipv4_fail, $check_ipv6_fail));

################################################################################
# Bind to a port,
# but send a wrong greeting.
# Verify that the plugin fails
# with the appropriate message.
################################################################################

$host = serve("PROPRIETARY SERVICE READY. SEND CLEARTEXT PASSWORDS NOW!\r\n");

$config = <<EOCONF;
plugin = http
url = http://$host
timeout = 1
EOCONF

test_plugin('http', $config, 2, set($check_ipv4_fail, $check_ipv6_fail));

################################################################################
# Bind to a port,
# send correct greeting.
# Verify that the plugin
# does not fail.
################################################################################

$host = serve("HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n");

$config = <<EOCONF;
plugin = http
url = http://$host
timeout = 1
EOCONF

test_plugin('http', $config, 1, set($check_ipv6_fail));

################################################################################
# Bind to a port,
# send correct greeting,
# but error message in body.
# Verify that the plugin
# fails with the appropriate error message.
################################################################################

$host = serve(
    "HTTP/1.0 200 OK\r\nContent-Length: 24\r\n\r\nFailed to query backend.");

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
qr#^HTTP body of http://localhost:[0-9]+ \(127.0.0.1\) does not match regexp /Latest release: \\d/#,
            ),
            'id' => ignore(),
        },

        $check_ipv6_fail,
    ));

################################################################################
# Bind to a port,
# send correct greeting,
# and correct message in body.
# Verify that the plugin
# does not fail.
################################################################################

$host = serve("HTTP/1.0 200 OK\r\nContent-Length: 17\r\n\r\nLatest release: 3");

$config = <<EOCONF;
plugin = http
url = http://$host
timeout = 1
EOCONF
$config .= q#body = "/Latest release: \\d/"#;

test_plugin('http', $config, 1, set($check_ipv6_fail));

################################################################################
# Bind to a port,
# but immediately close incoming connections.
# Verify that the plugin
# removes username and password from error messages.
################################################################################

$host = serve_and_close_connections();

$config = <<EOCONF;
plugin = http
url = http://Sending:ClearTextPasswordsNOW\@$host
timeout = 1
EOCONF

test_plugin('http', $config, 2, set($check_ipv4_fail, $check_ipv6_fail));

################################################################################
# Bind to a port,
# and check http basic authorization header.
# Verify that the plugin
# does not fail with valid credentials.
################################################################################

$host = serve_with_basic_authentication();

$config = <<EOCONF;
plugin = http
url = http://ilove:kanla\@$host
timeout = 1
EOCONF
$config .= q#body = "/Yes, yes you do\./"#;

test_plugin('http', $config, 1, set($check_ipv6_fail));

################################################################################
# Bind to a port,
# and check http basic authorization header.
# Verify that the plugin
# successfully logs in with valid credentials
# and fails with the appropriate error message.
################################################################################

$host = serve_with_basic_authentication();

$config = <<EOCONF;
plugin = http
url = http://ilove:kanla\@$host
timeout = 1
EOCONF
$config .= q#body = "/this regex should fail/"#;

test_plugin(
    'http', $config, 2,
    set({
            'severity' => 'critical',
            'message'  => re(
qr#^HTTP body of http://localhost:[0-9]+ \(127.0.0.1\) does not match regexp /this regex should fail/#,
            ),
            'id' => ignore(),
        },

        $check_ipv6_fail
    ));

################################################################################
# Bind to a port,
# and check http basic authorization header.
# Verify that the plugin
# fails with incorrect credentials.
################################################################################

$host = serve_with_basic_authentication();

$config = <<EOCONF;
plugin = http
url = http://idislike:kanla\@$host
timeout = 1
EOCONF

test_plugin(
    'http', $config, 2,
    set($check_ipv4_unauthorized, $check_ipv6_fail));

done_testing;

# Kill all child processes,
# otherwise a 'prove' process hangs.
$SIG{TERM} = sub { };
kill('TERM', 0);
