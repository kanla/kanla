use inc::Module::Install;
use Cwd;

name     'kanla';
all_from 'monitor';
author   'Michael Stapelberg';

requires 'AnyEvent';
requires 'AnyEvent::Handle';
requires 'AnyEvent::Socket';
requires 'JSON::XS';

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
	asciidoc -b html5 -f asciidoc.conf -a toc2 -a disable-javascript -a stylesheet=$cwd/asciidoc-toc.css -n -o - $file | hxtoc -l 2 > $htmlfile
EOT
}

postamble <<END_OF_MAKEFILE;
$postamble

docs: $alldocfiles
END_OF_MAKEFILE

WriteAll;
