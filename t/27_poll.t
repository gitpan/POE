#!/usr/bin/perl -w
# $Id: 27_poll.t,v 1.4 2002/06/30 20:24:11 rcaputo Exp $

# Rerun t/04_selects.t but with IO::Poll instead.

use strict;
use lib qw(./lib ../lib);
use TestSetup;

#sub POE::Kernel::TRACE_SELECT () { 1 }

BEGIN {
  eval 'use IO::Poll';
  test_setup(0, "need IO::Poll to test POE's support for that module")
    if length($@) or not exists $INC{'IO/Poll.pm'};
  test_setup(0, "need IO::Poll 0.05 (you have version $IO::Poll::VERSION)")
    if $IO::Poll::VERSION < 0.05;
}

require 't/04_selects.t';

exit;
