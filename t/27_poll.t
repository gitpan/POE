#!/usr/bin/perl -w
# $Id: 27_poll.t,v 1.8 2003/07/09 18:20:41 rcaputo Exp $

# Rerun t/04_selects.t but with IO::Poll instead.

use strict;
use lib qw(./lib ../lib .. .);
use TestSetup;

BEGIN {
  eval 'use IO::Poll';
  test_setup(0, "IO::Poll is needed for these tests")
    if length($@) or not exists $INC{'IO/Poll.pm'};
  test_setup(0, "IO::Poll 0.05 or newer is needed for these tests")
    if $IO::Poll::VERSION < 0.05;
}

require 't/04_selects.t';

exit;
