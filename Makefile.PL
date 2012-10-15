use inc::Module::Install;

name     'kanla';
all_from 'monitor';
author   'Michael Stapelberg';

requires 'AnyEvent';
requires 'AnyEvent::Handle';
requires 'AnyEvent::Socket';
requires 'JSON::XS';

WriteAll;
