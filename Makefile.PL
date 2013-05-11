use inc::Module::Install;
use Cwd;

name     'kanla';
all_from 'lib/Kanla.pm';
author   'Michael Stapelberg';

requires 'AnyEvent';
requires 'AnyEvent::Util';
requires 'AnyEvent::Handle';
requires 'AnyEvent::XMPP::Client';
requires 'AnyEvent::XMPP::Ext::Disco';
requires 'AnyEvent::XMPP::Ext::Ping';
requires 'AnyEvent::XMPP::Ext::VCard';
requires 'AnyEvent::XMPP::Ext::Version';
requires 'JSON::XS';
requires 'Config::General' => '2.50';
requires 'File::ShareDir';

# plugin requirements
requires 'AnyEvent::HTTP' => '1.5';
requires 'AnyEvent::Socket';
requires 'AnyEvent::DNS';

# test requirements
test_requires 'Test::MockModule';
test_requires 'Test::Deep';

install_script 'kanla';
# Install plugins/ into a distribution-shared directory
install_share('dist', 'plugins');

################################################################################
# We generate make targets for every file in docs/
# so users can use 'make docs'
# to generate docs/*.html from docs/*.txt
################################################################################

my @docs = <docs/*.txt>;
my $alldocfiles = join ' ', map { substr($_, 0, length() - 4) . '.html' } @docs;
my $postamble = '';
my $cwd = getcwd();

for my $file (@docs) {
	my $htmlfile = $file;
	$htmlfile =~ s/\.txt$/.html/;
$postamble .= <<EOT
$htmlfile: $file
	asciidoc -b html5 -f asciidoc.conf -a toc2 -a disable-javascript -a data-uri -a icons -a iconsdir=/etc/asciidoc/images/icons/ -a stylesheet=$cwd/asciidoc-toc.css -n -o - $file | hxtoc -l 2 > $htmlfile
EOT
}

postamble <<END_OF_MAKEFILE;
$postamble

docs: $alldocfiles
END_OF_MAKEFILE

postamble <<'END_OF_MAKEFILE';
install:: extra_install
pure_install:: extra_install
install_vendor:: extra_install

extra_install:
	install -d $(DESTDIR)/etc/kanla
	install -d $(DESTDIR)/etc/kanla/default.d
	install -m 640 default.cfg $(DESTDIR)/etc/kanla/default.cfg
	install -m 640 default.d/* $(DESTDIR)/etc/kanla/default.d/
END_OF_MAKEFILE

WriteAll;
