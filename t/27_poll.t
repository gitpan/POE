#!/usr/bin/perl -w
# $Id: 27_poll.t,v 1.6 2003/02/01 04:52:07 cwest Exp $

# Rerun t/04_selects.t but with IO::Poll instead.

use strict;
use lib qw(./lib ../lib .. .);
use TestSetup;

#sub POE::Kernel::TRACE_SELECT () { 1 }

BEGIN {
  eval 'use IO::Poll';
  test_setup(0, "IO::Poll is needed for these tests")
    if length($@) or not exists $INC{'IO/Poll.pm'};
  test_setup(0, "IO::Poll 0.05 or newer is needed for these tests")
    if $IO::Poll::VERSION < 0.05;
}

require 't/04_selects.t';

exit;
