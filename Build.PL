#!/usr/bin/perl
# $Id: Build.PL,v 1.5 2004/02/02 17:03:07 rcaputo Exp $

use warnings;
use strict;
use Module::Build;

# Accomodate with CPAN autoinstall.  See
# http://www.mail-archive.com/module-authors@perl.org/msg00162.html
shift @ARGV if @ARGV and $ARGV[0] eq 'Build';

my $build = Module::Build->new(
                dist_name => 'POE',
                dist_version_from => 'lib/POE.pm',
                dist_author => 'Rocco Caputo <rcaputo@cpan.org>',

                license => 'perl',

                requires => {
                    'Filter::Util::Call' => 1.04,
                    'Test::More'         => 0,
                },

                recommends => {
                    'Time::HiRes'        => 0,
                },
            );

$build->create_build_script;
