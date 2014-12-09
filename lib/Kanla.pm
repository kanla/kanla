# -*- Mode: CPerl;
# cperl-indent-level: 4;
# cperl-continued-statement-offset: 4;
# cperl-indent-parens-as-block: t;
# cperl-tabs-always-indent: t;
# cperl-indent-subs-specially: nil;
# -*-
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
# ::Receipts was added in AnyEvent::XMPP 0.54.
# kanla works fine without,
# but it’s nice to have.
# Therefore, load it and fall back if that fails.
my $use_receipts = eval {
    require AnyEvent::XMPP::Ext::Receipts;
    AnyEvent::XMPP::Ext::Receipts->import();
    1;
};

# libfile-sharedir-perl
use File::ShareDir qw(dist_dir);

# libanyevent-perl
use AnyEvent;
use AnyEvent::Util;
use AnyEvent::Handle;

# libconfig-general-perl
use Config::General;

# libjson-xs-perl
use JSON::XS;

# core
use Cwd qw(abs_path);
use Carp;
use Data::Dumper;
use File::Basename qw(basename);
use Encode qw(encode decode);

# see http://www.dagolden.com/index.php/369/version-numbers-should-be-boring/
our $VERSION = "1.5";
$VERSION = eval $VERSION;

binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';

my $conf;
my $xmpp;

# Messages which were produced while no XMPP connection was established (yet).
# They will be sent when a connection is established.
my @queued_messages;

# Returns the path
# to the specified plugin
# by first checking dist_dir('kanla'),
# then 'plugins/',
# just like the configuration
# is searched in /etc/kanla,
# then in '.'.
sub plugin_path {
    my ($plugin) = @_;

    # The custom plugin dir
    # takes precedence.
    for my $dir (qw(share lib)) {
        my $path = "/usr/local/$dir/kanla/$plugin";
        return $path if -e $path;
    }

    my $dist_dir;
    # We eval because
    # dist_dir dies
    # when the dir does not exist.
    eval { $dist_dir = dist_dir('kanla'); };
    if (defined($dist_dir)) {
        return "$dist_dir/$plugin" if -e "$dist_dir/$plugin";
    }

    # NB: This does not imply
    # that the plugin exists.
    return "plugins/$plugin";
}

sub start_plugin {
    my ($plugin, $name) = @_;

    # Save the config for this plugin to string,
    # we will feed it to the plugin via stdin below.
    my $config = $conf->obj('monitor')->obj($name);
    # We need to specifically encode the config string
    # because AnyEvent does not
    # specify an encoding.
    my $config_str = encode('UTF-8', $config->save_string());

    my @dest;
    if ($config->exists('send_alerts_to')) {
        @dest = split("\n", $config->value('send_alerts_to'));
    } else {
        @dest = split("\n", $conf->value('send_alerts_to'));
    }

    say qq|[$plugin/instance "$name"] starting…|;

    my ($pr, $pw) = AnyEvent::Util::portable_pipe;
    fcntl($pr, AnyEvent::F_SETFD, AnyEvent::FD_CLOEXEC);
    my $w;
    $w = AnyEvent::Handle->new(
        fh       => $pr,
        on_error => sub {
            my ($hdl, $fatal, $msg) = @_;
            say STDERR
                qq|[$plugin/instance "$name"] error reading from stderr: $msg|;

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
                cb    => sub {
                    start_plugin($plugin, $name);
                    undef $t;
                });
            $w->destroy;
        });

    my @start_request;
    @start_request = (
        json => sub {
            my ($hdl, $hashref) = @_;
            handle_stderr_msg($name, basename($plugin), \@dest, $hashref);
            $hdl->push_read(@start_request);
        });

    $w->push_read(@start_request);

    my $cv = run_cmd [ plugin_path($plugin) ],

        # feed the config on stdin
        '<', \$config_str,

        # stdout goes to /dev/null for now.
        '>', '/dev/null',

        # TODO: proxy stderr into our log so that one can easily spot plugin failures
        '3>', $pw;
    $cv->cb(
        sub {
            my $status = shift->recv;
            say STDERR
                qq|[$plugin/instance "$name"] exited with exit code $status|;
        });
}

sub message_silenced {
    my ($message, $counts) = @_;

    my $pattern = $message->{silenced_by};
    if (!defined($pattern) &&
        $conf->exists('silenced_by')) {
        $pattern = $conf->value('silenced_by');
    }

    return unless defined($pattern);

    my @matches;
    my @ids = grep { $_ ne $message->{failure_id} } keys %$counts;
    if (my ($re) = ($pattern =~ m,^/(.*)/$,)) {
        # Regular expression matching
        my $compiled = qr/$re/;
        @matches = grep { /$compiled/ } @ids;
    } else {
        # String prefix matching
        my $prefix = quotemeta($pattern);
        @matches = grep { m,^$prefix, } @ids;
    }

    return @matches > 0;
}

sub xmpp_empty_queue {
    my @leftover;

    my $consecutive_failures = (
        $conf->exists('consecutive_failures') ?
            $conf->value('consecutive_failures') :
            0
    );

    @queued_messages = grep { $_->{expiration} >= time() } @queued_messages;

    my %counts;
    for my $entry (@queued_messages) {
        my ($jid, $message) = @$entry;
        $counts{ $message->{failure_id} }++;
    }

    for my $entry (@queued_messages) {
        my ($jid, $message) = @$entry;

        next if message_silenced($message, \%counts);

        if ($counts{ $message->{failure_id} } < $consecutive_failures) {
            push @leftover, $entry;
            next;
        }

        # Find the account,
        # if unsuccessful,
        # no account
        # is connected.
        my $account = $xmpp->find_account_for_dest_jid($jid);
        if (!defined($account) || !defined($account->connection)) {
            push @leftover, $entry;
            next;
        }

        my $presence = $xmpp->get_priority_presence_for_jid($jid);
        if (!defined($presence)) {
            say "[XMPP] No presence found for $jid, skipping";
            push @leftover, $entry;
            next;
        }

        # NB: We cannot use $xmpp->send_message here because
        # that will make the JID a bare JID and use its own
        # conversation tracking technique.
        $account->connection->send_message(
            $presence->jid,
            'chat',
            undef,
            body => $message->{body});
    }

    @queued_messages = @leftover;
}

sub handle_stderr_msg {
    my ($name, $module, $dest, $data) = @_;
    if (!exists($data->{severity}) ||
        !exists($data->{message})) {
        say STDERR
"Malformed JSON output from module $module (missing severity or messages property).";
        return;
    }

    my $module_config = $conf->obj('monitor')->obj($name);
    my $interval      = 60;
    if ($module_config->exists('interval')) {
        $interval = $module_config->value('interval');
    }
    my $silenced_by = undef;
    if ($module_config->exists('silenced_by')) {
        $silenced_by = $module_config->value('silenced_by');
    }

    if ($data->{severity} eq 'critical') {
        say "read from plugin: " . $data->{message};
        my $message = {
            body        => $data->{message},
            expiration  => time() + $interval,
            failure_id  => $data->{id} // $data->{message},
            silenced_by => $silenced_by,
        };

        for my $jid (@$dest) {
            push @queued_messages, [ $jid, $message ];
        }
        xmpp_empty_queue();
    }
}

sub run {
    my %args = @_;

    $args{configfile} //= 'default.cfg';

    $conf = Config::General->new(

        # XXX: Not sure if '.' is a good idea. It makes development easier.
        -ConfigPath => [ '/etc/kanla', '.' ],
        -ConfigFile => $args{configfile},

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

        # allow including the same file multiple times,
        # since we might have different variables set.
        -IncludeAgain => 1,

        # allow "include <path>"
        -UseApacheInclude => 1,

        # provide the ->array, ->hash, etc. methods
        -ExtendedAccess => 1,

        # interpolate config options when referred to as $foobar
        -InterPolateVars => 1,
    );

    say 'FYI: Configuration was read from the following files:';
    say '  ' . abs_path($_) for $conf->files;

    # sanity check: are there any plugins configured?
    if (!defined($conf->keys('monitor')) ||
        scalar $conf->keys('monitor') == 0) {
        say STDERR 'Your configuration does not contain any <monitor> blocks.';
        say STDERR
            'Without these blocks, running this program does not make sense.';
        exit 1;
    }

    # also: are there any jabber accounts configured?
    if (!$conf->exists('jabber')) {
        say STDERR 'Your configuration does not contain any <jabber> blocks.';
        say STDERR
            'Without these blocks, running this program does not make sense.';
        exit 1;
    }

    # Collect all jabber IDs
    # to add them to our roster
    # and allow subscription requests.
    my @all_jids;
    my $sat_global;
    if ($conf->exists('send_alerts_to')) {

        # Remember that there is a global send_alerts_to directive,
        # so that we can throw errors
        # when a module does not have its own
        # and there is no global send_alerts_to.
        $sat_global = 1;
        @all_jids = (@all_jids, split("\n", $conf->value('send_alerts_to')));
    }

    my $plugin_cfgs = $conf->obj('monitor');
    for my $name ($conf->keys('monitor')) {
        my $plugin_cfg = $plugin_cfgs->obj($name);
        if (ref $plugin_cfg eq 'ARRAY') {
            say STDERR
                "ERROR: You have two <monitor> blocks with name “$name”.";
            say STDERR
"ERROR: This is not supported. Please rename one of the blocks.";
            exit 1;
        }
        if (!$plugin_cfg->exists('send_alerts_to')) {
            if (!$sat_global) {
                say STDERR
"The <monitor $name> block is missing the send_alerts_to directive";
                exit 1;
            }
            next;
        }
        @all_jids =
            (@all_jids, split("\n", $plugin_cfg->value('send_alerts_to')));
    }

    # An AnyEvent->timer which will send @queued_messages. We need that because we
    # need to wait for presence updates to finish before we can determine an
    # inidividual user’s presence with the highest priority. While it would be
    # easier to send to a bare JID, we also need full JIDs for message receipts.
    my $queued_timer;

    $xmpp = AnyEvent::XMPP::Client->new();

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
    $version->set_name("kanla");
    $version->set_version("0.1");
    $version->set_os("Linux");
    $xmpp->add_extension($version);
    $disco->enable_feature($version->disco_feature);

    if ($use_receipts) {
        my $receipts =
            AnyEvent::XMPP::Ext::Receipts->new(disco => $disco, debug => 1);
        $xmpp->add_extension($receipts);
    } else {
        say STDERR
"WARNING: XEP-0184 message receipts are not available because AnyEvent::XMPP is too old.";
    }

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
            $vcard->store(
                $account->connection(),
                {
                    NICKNAME => 'kanla',
                    FN       => 'kanla',
                },
                sub {
                    my ($error) = @_;
                    if ($error) {
                        say "[XMPP] VCard upload failed: " . $error->string;
                    }
                });

            for my $jid (@all_jids) {
                $account->connection()->get_roster()->new_contact(
                    $jid, undef, undef,
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
            my ($cl, $account, $roster, $contact, $old_presence, $new_presence)
                = @_;

            return if defined($queued_timer);
            $queued_timer = AnyEvent->timer(

                # We wait 5 seconds for the presence updates to trickle in. On very
                # slow uplinks, that might be too short, but then again, monitoring
                # will likely not work very well anyways in that situation.
                after => 5,
                cb    => sub {
                    xmpp_empty_queue();
                    undef $queued_timer;
                });
        },

        contact_request_subscribe => sub {
            my ($cl, $acc, $roster, $contact) = @_;

            # Ignore subscription requests from people who are not in
            # @all_jids.
            return unless (scalar grep { $_ eq $contact->jid } @all_jids) > 0;

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

            # TODO: we might want to handle presence errors in a special way.
            # in case of a 404 they probably mean the user has a typo in his jid.
            say "[XMPP] Error: " . $error->string();

            # Try to reconnect, if necessary.
            $xmpp->update_connections();
        },
    );
    $xmpp->start;

    # Start all the monitoring modules,
    # read their stderr, relay errors to XMPP.
    for my $name ($conf->keys('monitor')) {
        my $plugin_cfg = $plugin_cfgs->obj($name);
        my $plugin     = $plugin_cfg->value('plugin');

        # TODO: handle send_alerts_to per plugin

        if (!defined($plugin) || $plugin eq '') {
            say STDERR
                qq|Invalid <monitor> block: 'plugin' not specified for "$name"|;
            next;
        }

        my $path = plugin_path($plugin);
        if (!-e $path) {
            say STDERR qq|Invalid <monitor> block: plugin "$plugin" not found|;
            next;
        }

        if (!-X $path) {
            say STDERR
qq|Invalid <monitor> block: plugin "$plugin" not executable (try chmod +x?)|;
            next;
        }

        start_plugin($plugin, $name);
    }
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

Version 1.5

=head1 AUTHOR

Michael Stapelberg, C<< <michael at stapelberg.de> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2012-2014 Michael Stapelberg.

This program is free software; you can redistribute it and/or modify it
under the terms of the BSD license.

=cut

# vim:ts=4:sw=4:expandtab
