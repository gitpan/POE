# $Id: test.t,v 1.3 1998/11/23 05:34:16 troc Exp $
# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

######################### We start with some black magic to print on failure.

# Change 1..1 below to 1..last_test_to_print .
# (It may become useful if the test is moved to ./t subdirectory.)

BEGIN { $| = 1; print "1..1\n"; }
END { print "not ok 1\n" unless $loaded; }

use POE qw(Kernel Session Driver::SysRW Filter::Line Wheel::ListenAccept Wheel::ReadWrite);
$loaded = 1;
print "ok 1\n";

######################### End of black magic.

print STDERR "\n***\n*** ";
print STDERR "please see the programs in tests/ for examples and tests\n";
print STDERR "***\n";
