# -*- Mode: CPerl;
# cperl-indent-level: 4;
# cperl-continued-statement-offset: 4;
# cperl-indent-parens-as-block: t;
# cperl-tabs-always-indent: t;
# cperl-indent-subs-specially: nil;
# -*-
# vim:ts=4:sw=4:expandtab
package Kanla::Plugin;

use strict;
use warnings;
use utf8;
use v5.10;

# libanyevent-perl
use AnyEvent;

# libconfig-general-perl
use Config::General;

# libjson-xs-perl
use JSON::XS;

# core
use IO::Handle;

use Exporter ();
our @EXPORT = qw(
    signal_error
    $conf
);

our $conf;

# see http://www.dagolden.com/index.php/369/version-numbers-should-be-boring/
our $VERSION = "1.3";
$VERSION = eval $VERSION;

# This will be set to a true value
# after initialization is complete,
# so that multiple callers can
# "use Kanla::Plugin"
# and all of them actually work :).
# (We do read STDIN for example,
#  which can only be done once.)
my $initialized;
my $errorfh;
my $main_timer;

sub signal_error {
    my ($severity, $message) = @_;
    say $errorfh encode_json({
            severity => $severity,
            message  => $message
    });
}

sub import {
    my ($class, %args) = @_;

    say "kanla::plugin import";
    say "second!" if (defined($conf));

    my $pkg = caller;

    # Enable 5.10 features,
    # strict,
    # warnings,
    # utf8
    # for the caller.
    feature->import(":5.10");
    strict->import;
    warnings->import;
    utf8->import;

    # Setup the error fd
    if (!$initialized) {
        $errorfh = IO::Handle->new_from_fd(3, 'w');
        $errorfh->autoflush(1);

        # Parse the configuration
        my $config_str;
        {
            local $/;
            $config_str = <STDIN>;
        }

        do {
            $conf = Config::General->new(
                -String => $config_str,

                # open all files in utf-8 mode
                -UTF8 => 1,

                # normalize yes, on, 1, true and no, off, 0, false to 1 resp. 0
                -AutoTrue => 1,

                # case-insensitive key names by lowercasing everything
                -LowerCaseNames => 1,

                # provide the ->array, ->hash, etc. methods
                -ExtendedAccess => 1,

                -FlagBits => {
                    family => {
                        ipv4 => 1,
                        ipv6 => 1,
                    },
                },
            );

            if (!$conf->exists('family')) {
                $config_str .= <<'EOT';

family = ipv4 | ipv6
EOT
            }
        } until ($conf->exists('family'));

        # TODO: parse interval from config
        my $interval = 60;

        # Periodically run the check, but don’t wait for the first $interval seconds to
        # pass, but run it right now, too.
        my $run;
        {
            no strict 'refs';
            $run = *{ $pkg . "::run" };
        }
        $main_timer = AnyEvent->timer(
            after    => 0,
            interval => $interval,
            cb       => \&$run,
        );

        $initialized = 1;
    }

    @_ = ($class);
    goto \&Exporter::import;
}

END {
    AnyEvent->condvar->recv;
}

1
