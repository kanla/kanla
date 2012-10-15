# vim:ts=4:sw=4:expandtab
package Kanla;

use strict;
use warnings;
use utf8;
use v5.10;
# libanyevent-xmpp-perl
use AnyEvent::XMPP::Client;
use AnyEvent::XMPP::Ext::Disco;
use AnyEvent::XMPP::Ext::Ping;
use AnyEvent::XMPP::Ext::VCard;
use AnyEvent::XMPP::Ext::Version;
use lib qw(.);
use AnyEvent::XMPP::Ext::Receipts;
# libanyevent-perl
use AnyEvent;
use AnyEvent::Util;
use AnyEvent::Handle;
# libconfig-general-perl
use Config::General;
# libjson-xs-perl
use JSON::XS;
# core
use Carp;
use Data::Dumper;
use File::Basename qw(basename);

# see http://www.dagolden.com/index.php/369/version-numbers-should-be-boring/
our $VERSION = "1.0";
$VERSION = eval $VERSION;

binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';

sub run {
    my $conf = Config::General->new(
        # XXX: Not sure if '.' is a good idea. It makes development easier.
        -ConfigPath => [ '/etc/kanla', '.' ],
        -ConfigFile => "default.cfg",
        # open all files in utf-8 mode
        -UTF8 => 1,
        # normalize yes, on, 1, true and no, off, 0, false to 1 resp. 0
        -AutoTrue => 1,
        # case-insensitive key names by lowercasing everything
        -LowerCaseNames => 1,
        # include files relative to the location
        -IncludeRelative => 1,
        # allow glob patterns in include statements
        -IncludeGlob => 1,
        # allow "include <path>"
        -UseApacheInclude => 1,
        # provide the ->array, ->hash, etc. methods
        -ExtendedAccess => 1,
        # interpolate config options when referred to as $foobar
        -InterPolateVars => 1,
    );

    say 'FYI: Configuration was read from the following files:';
    say "  $_" for $conf->files;

    # sanity check: are there any plugins configured?
    if (scalar $conf->keys('monitor') == 0) {
        say STDERR 'Your configuration does not contain any <monitor> blocks.';
        say STDERR 'Without these blocks, running this program does not make sense.';
        exit 1;
    }

    # TODO: config + multi-account support

    my @destination_accounts = qw(
        michael@stapelberg.de
    );

    # Messages which were produced while no XMPP connection was established (yet).
    # They will be sent when a connection is established.
    my @queued_messages;
    # An AnyEvent->timer which will send @queued_messages. We need that because we
    # need to wait for presence updates to finish before we can determine an
    # inidividual user’s presence with the highest priority. While it would be
    # easier to send to a bare JID, we also need full JIDs for message receipts.
    my $queued_timer;

    my $xmpp = AnyEvent::XMPP::Client->new(debug => 1);

    my @accounts;
    if (!$conf->is_array('jabber')) {
        @accounts = ({ $conf->hash('jabber') });
    } else {
        @accounts = $conf->array('jabber');
    }

    for my $account (@accounts) {
        $xmpp->add_account(
            $account->{jid},
            $account->{password},
            $account->{host},
            $account->{port},
            { initial_presence => undef });
    }

    my $ping = AnyEvent::XMPP::Ext::Ping->new();
    $xmpp->add_extension($ping);
    # Sends a ping request every 60 seconds. If the server does not respond within
    # another 60 seconds, reconnect.
    $ping->auto_timeout(60);

    # We are a good jabber citizen and mark this client as a bot.
    my $disco = AnyEvent::XMPP::Ext::Disco->new();
    $xmpp->add_extension($disco);
    $disco->set_identity('client', 'bot');

    # Advertise VCard support for a nice real name plus an avatar later.
    my $vcard = AnyEvent::XMPP::Ext::VCard->new();
    $disco->enable_feature($vcard->disco_feature);

    my $version = AnyEvent::XMPP::Ext::Version->new();
    $version->set_name("zkj-monitor");
    $version->set_version("0.1");
    $version->set_os("Linux");
    $xmpp->add_extension($version);
    $disco->enable_feature($version->disco_feature);

    my $receipts = AnyEvent::XMPP::Ext::Receipts->new(disco => $disco, debug => 1);
    $xmpp->add_extension($receipts);

    $xmpp->set_presence(undef, 'okay (17:32:00, 2012-10-09)', 11);

    $xmpp->reg_cb(
        stream_ready => sub {
            my ($cl, $account) = @_;
            $vcard->hook_on($account->connection(), 1);
        },

        connected => sub {
            my ($self, $account) = @_;
            say "connected, adding contacts";

            # TODO: vcard avatar should be our logo as soon as we got one :)
            $vcard->store($account->connection(), {
                    NICKNAME => 'zkj-monitor',
                    FN => 'zkj-monitor',
                }, sub {
                    my ($error) = @_;
                    if ($error) {
                        say "[XMPP] VCard upload failed: " . $error->string;
                    }
                });

            for my $jid (@destination_accounts) {
                $account->connection()->get_roster()->new_contact($jid, undef, undef,
                    sub {
                        my ($contact, $err) = @_;
                        if (defined($contact)) {
                            say "Added $jid, sending presence subscription";
                            $contact->send_subscribe();
                        } else {
                            say "Error adding $jid: $err";
                        }
                    });
            }

        },

        presence_update => sub {
            my ($cl, $account, $roster, $contact, $old_presence, $new_presence) = @_;

            return if defined($queued_timer);
            $queued_timer = AnyEvent->timer(
                # We wait 5 seconds for the presence updates to trickle in. On very
                # slow uplinks, that might be too short, but then again, monitoring
                # will likely not work very well anyways in that situation.
                after => 5,
                cb => sub {
                    for my $msg (@queued_messages) {
                        xmpp_msg_all($account, $msg);
                    }
                    undef $queued_timer;
                });
        },

        contact_request_subscribe => sub {
            my ($cl, $acc, $roster, $contact) = @_;
            # Ignore subscription requests from people who are not in
            # @destination_accounts.
            return unless ($contact->jid ~~ @destination_accounts);

            # Acknowledge everything else.
            say "Acknowledging subscription request from " . $contact->jid;
            $contact->send_subscribed;
            $contact->send_subscribe;
        },

        disconnect => sub {
            my ($self, $account, $host, $port, $message) = @_;
            say "[XMPP] Disconnected: $message";

            # Try to reconnect, if necessary.
            $xmpp->update_connections();
        },

        error => sub {
            my ($self, $account, $error) = @_;
            say "[XMPP] Error: " . $error->string();

            # Try to reconnect, if necessary.
            $xmpp->update_connections();
        },
    );
    $xmpp->start;

    sub xmpp_msg_all {
        my ($account, $message) = @_;

        for my $dest (@destination_accounts) {
            my $presence = $xmpp->get_priority_presence_for_jid($dest);
            if (!defined($presence)) {
                say "[XMPP] No presence found for $dest, skipping";
                next;
            }

            # NB: We cannot use $xmpp->send_message here because
            # that will make the JID a bare JID and use its own
            # conversation tracking technique.
            $account->connection->send_message(
                $presence->jid,
                'chat',
                undef,
                body => $message);
        }
    }

    sub handle_stderr_msg {
        my ($module, $data) = @_;
        if (!exists($data->{severity}) ||
            !exists($data->{message})) {
            say STDERR "Malformed JSON output from module $module (missing severity or messages property).";
            return;
        }

        if ($data->{severity} eq 'critical') {
            say "relaying: " . $data->{message};
            my $acc = $xmpp->find_account_for_dest_jid($destination_accounts[0]);
            if (!defined($acc)) {
                push @queued_messages, $data->{message};
                return;
            }
            xmpp_msg_all($acc, $data->{message});
        }
    }

    sub start_plugin {
        my ($plugin, $name) = @_;

        # Save the config for this plugin to string,
        # we will feed it to the plugin via stdin below.
        my $config_str = $conf->obj('monitor')->obj($name)->save_string();

        say qq|[$plugin/instance "$name"] starting…|;

        my ($pr, $pw) = AnyEvent::Util::portable_pipe;
        fcntl($pr, AnyEvent::F_SETFD, AnyEvent::FD_CLOEXEC);
        my $w;
        $w = AnyEvent::Handle->new(
            fh => $pr,
            on_error => sub {
                my ($hdl, $fatal, $msg) = @_;
                say STDERR qq|[$plugin/instance "$name"] error reading from stderr: $msg|;

                # Restart the plugin,
                # so that you can just kill plugins
                # after changing their code.
                #
                # The delay of 2 seconds avoids
                # spamming the user with errors
                # when a plugin exits immediately.
                my $t;
                $t = AnyEvent->timer(
                    after => 2,
                    cb => sub {
                        start_plugin($plugin, $name);
                        undef $t;
                    });
                $w->destroy;
            });

        my @start_request; @start_request = (json => sub {
            my ($hdl, $hashref) = @_;
            handle_stderr_msg(basename($plugin), $hashref);
            $hdl->push_read(@start_request);
        });

        $w->push_read(@start_request);

        my $cv = run_cmd [ "plugins/$plugin" ],
            # feed the config on stdin
            '<', \$config_str,
            # stdout goes to /dev/null for now.
            '>', '/dev/null',
            '2>', $pw;
        $cv->cb(sub {
            my $status = shift->recv;
            say STDERR qq|[$plugin/instance "$name"] exited with exit code $status|;
        });
    }

    # Start all the monitoring modules,
    # read their stderr, relay errors to XMPP.
    my $plugin_cfgs = $conf->obj('monitor');
    for my $name ($conf->keys('monitor')) {
        my $plugin_cfg = $plugin_cfgs->obj($name);
        my $plugin = $plugin_cfg->value('plugin');

        # TODO: handle send_alerts_to per plugin

        if (!defined($plugin) || $plugin eq '') {
            say STDERR qq|Invalid <monitor> block: 'plugin' not specified for "$name"|;
            next;
        }

        if (! -e "plugins/$plugin") {
            say STDERR qq|Invalid <monitor> block: plugin "$plugin" not found|;
            next;
        }

        if (! -X "plugins/$plugin") {
            say STDERR qq|Invalid <monitor> block: plugin "$plugin" not executable (try chmod +x?)|;
            next;
        }

        start_plugin($plugin, $name);
    }

    # Run forever.
    AnyEvent->condvar->recv;
}

1

__END__

=encoding utf-8

=head1 NAME

kanla - small-scale alerting daemon

=head1 DESCRIPTION

kanla is a daemon which peridiocally checks
whether your website, mail server, etc.
are still up and running.

In case a health check fails,
kanla will notify you
via jabber (XMPP).

Focus of kanla lies on
being light-weight,
being simple,
using a sane configuration file,
being well-documented.

=head1 DOCUMENTATION

kanla's documentation can be found at
http://kanla.zekjur.net/docs/

We have decided to use asciidoc for kanla,
and to not maintain both POD and asciidoc,
the POD documentation is intentionally sparse.

=head1 VERSION

Version 1.0

=head1 AUTHOR

Michael Stapelberg, C<< <michael at stapelberg.de> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2012 Michael Stapelberg.

This program is free software; you can redistribute it and/or modify it
under the terms of the BSD license.

=cut
