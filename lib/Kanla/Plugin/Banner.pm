# -*- Mode: CPerl;
# cperl-indent-level: 4;
# cperl-continued-statement-offset: 4;
# cperl-indent-parens-as-block: t;
# cperl-tabs-always-indent: t;
# cperl-indent-subs-specially: nil;
# -*-
# vim:ts=4:sw=4:expandtab
package Kanla::Plugin::Banner;

use strict;
use warnings;
use utf8;
use v5.10;

use Kanla::Plugin;

# libanyevent-perl
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;

use Socket qw(SOCK_STREAM);
use Exporter qw(import);
our @EXPORT = qw(
    banner_connect
    banner_disconnect
);

# Filled in banner_connect().
my $timeout = 0;

=head1 NAME

Kanla::Plugin::Banner - Useful functions for banner-based plugins

=head1 SYNOPSIS

    use Kanla::Plugin;
    use Kanla::Plugin::Banner;

    sub run {
        banner_connect(
            host            => 'irc.twice-irc.de',
            default_service => 'ircd',
            cb              => sub {
                my ($handle, $timeout) = @_;
                $handle->push_write("NICK kanla\r\n");
                $handle->push_write("USER kanla kanla kanla :kanla\r\n");
                my @read_line;
                @read_line = (
                    line => sub {
                        my ($handle, $line) = @_;
                        if ($line !~ /^:[^ ]+ 001 /) {
                            $handle->push_read(@read_line);
                            return;
                        }

                        # We successfully signed on.
                        undef $timeout;
                        $handle->push_write("QUIT\r\n");
                        banner_disconnect($handle);
                    });

                $handle->push_read(@read_line);
            });
    }

=head1 METHODS

=cut

sub _banner_connect {
    my ($ip, $service, $cb) = @_;

    tcp_connect $ip, $service, sub {
        my ($fh) = @_;
        if (!$fh) {
            signal_error(
                'critical',
                "Connecting to $ip on port $service failed: $!"
            );
            return;
        }

        my $t;
        $t = AnyEvent->timer(
            after => $timeout,
            cb    => sub {
                signal_error(
                    'critical',

                    # XXX: It is unfortunate that this
                    # error message is so sparse.
                    # we should refactor the code to
                    # allow for better errors here.
                    "Timeout ($timeout s) on [$ip]:$service"
                );
                undef $t;
            });

        my $handle;    # avoid direct assignment so on_eof has it in scope.
        $handle = AnyEvent::Handle->new(
            fh       => $fh,
            on_error => sub {
                signal_error(
                    'critical',
                    "TCP read error on [$ip]:$service: " . $_[2]);
                undef $t;
                $_[0]->destroy;
            },
            on_eof => sub {
                $handle->destroy;    # destroy handle
                signal_error(
                    'critical',
                    "TCP EOF on [$ip]:$service"
                );
                undef $t;
            });

        $cb->($handle, $t, $ip, $service);
    };
}

=head2 banner_connect

Connects to the given address
(parsed by C<AnyEvent::Socket>'s parse_hostport)
using the configured address families.

The caller provides a callback,
which will be called
after the connection was established.
In case there was an error
(DNS name could not be resolved,
connection was refused/timed out,
etc.),
the callback will B<NOT> be called,
but an alert will be signaled.

The callback will be called
with an C<AnyEvent::Handle> and
an C<AnyEvent> timer (timeouts).

The timeout is initialized
to the configured value
(plugin configuration)
or 10s if left unconfigured.

This example connects to one of
Google's SMTP servers
and waits for the SMTP greeting.
It does not resolve MX records,
but that's not the point of the example:

    banner_connect(
        host => 'aspmx.l.google.com',
        default_service => 'smtp',
        cb => sub {
            my ($handle, $timeout) = @_;
            $handle->push_read(line => sub {
                my ($handle, $line) = @_;
                undef $timeout;
                if ($line !~ /^220 /) {
                    signal_error('critical', 'Invalid greeting');
                }
            });
        });

=cut
sub banner_connect {
    my %args = @_;

    $timeout = ($conf->exists('timeout') ? $conf->value('timeout') : 10);

    # Ensure timeout is an int and > 0.
    $timeout += 0;
    $timeout ||= 1;

    my ($host, $service) =
        parse_hostport($args{'host'}, $args{'default_service'});

    my $resolved_cb = sub {

        # family is either A or AAAA
        my $family = shift;
        if (@_ == 0) {
            signal_error(
                'critical',
                "Cannot resolve $args{'host'} ($family) DNS record"
            );
            return;
        }
        for my $record (@_) {
            my ($service, $host) =
                AnyEvent::Socket::unpack_sockaddr($record->[3]);
            _banner_connect(format_address($host), $service, $args{'cb'});
        }
    };

    if ($conf->obj('family')->value('ipv4')) {
        AnyEvent::Socket::resolve_sockaddr(
            $host, $service, "tcp", 4, SOCK_STREAM,
            sub { $resolved_cb->('A', @_) });
    }
    if ($conf->obj('family')->value('ipv6')) {
        AnyEvent::Socket::resolve_sockaddr(
            $host, $service, "tcp", 6, SOCK_STREAM,
            sub { $resolved_cb->('AAAA', @_) });
    }
}

=head2 banner_disconnect($handle)

Properly disconnects
the specified C<AnyEvent::Handle>.

=cut
sub banner_disconnect {
    my ($handle) = @_;

    $handle->on_drain(
        sub {
            shutdown $handle->{fh}, 1;
            $handle->destroy;
            undef $handle;
        });
}

1
