# $Id: Makefile.PL,v 1.2 1998/08/15 20:34:09 troc Exp $

use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile
  (
   'NAME'         => 'POE',
   'VERSION_FROM' => 'POE.pm',
   'dist'         => { 'COMPRESS' => 'gzip -9',
                       'SUFFIX'   => 'gz',
                     },
  );
