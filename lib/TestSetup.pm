# Standard test setup things.
# $Id: TestSetup.pm,v 1.1 2000/03/08 19:04:23 rcaputo Exp $

package TestSetup;

sub import {
  my $something_poorly_documented = shift;
  $ENV{PERL_DL_NONLAZY} = 0 if ($^O eq 'freebsd');
  select(STDOUT); $|=1;
  print "1..$_[0]\n";
}

1;
