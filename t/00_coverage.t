#!/usr/bin/perl -w
# $Id: 00_coverage.t,v 1.5 2000/11/19 17:05:15 rcaputo Exp $

# This test merely loads as many modules as possible so that the
# coverage tester will see them.  It's performs a similar function as
# the FreeBSD LINT kernel configuration.

use strict;
use lib qw(./lib ../lib);
use TestSetup;
&test_setup(17);

sub load_optional_module {
  my ($test_number, $module) = @_;
  eval "package Test::Number_$test_number; use $module";
  my $reason = $@;
  $reason =~ s/[\x0a\x0d]+/ \/ /g;
  $reason =~ tr[ ][ ]s;
  print( "ok $test_number",
         ( (length $reason) ? " # skipped: $reason" : '' ),
         "\n"
       );
}

sub load_required_module {
  my ($test_number, $module) = @_;
  eval "package Test::Number_$test_number; use $module";
  my $reason = $@;
  $reason =~ s/[\x0a\x0d]+/ \/ /g;
  $reason =~ tr[ ][ ]s;
  if (length $reason) {
    print "not ok $test_number # $reason\n";
  }
  else {
    print "ok $test_number\n";
  }
}

# Required modules first.

sub POE::Kernel::ASSERT_DEFAULT () { 1 }

&load_required_module( 1, 'POE'); # includes POE::Kernel and POE::Session
&load_required_module( 2, 'POE::NFA');
&load_required_module( 3, 'POE::Filter::Line');
&load_required_module( 4, 'POE::Filter::Stream');
&load_required_module( 5, 'POE::Wheel::ReadWrite');
&load_required_module( 6, 'POE::Wheel::SocketFactory');

# Optional modules now.

&load_optional_module( 7, 'POE::Component::Server::TCP');
&load_optional_module( 8, 'POE::Filter::HTTPD');
&load_optional_module( 9, 'POE::Filter::Reference');
&load_optional_module(10, 'POE::Wheel::FollowTail');
&load_optional_module(11, 'POE::Wheel::ListenAccept');
&load_optional_module(12, 'POE::Filter::Block');

# Seriously optional modules.

&load_optional_module(13, 'POE::Component');
&load_optional_module(14, 'POE::Driver');
&load_optional_module(15, 'POE::Wheel');
&load_optional_module(16, 'POE::Filter');

# And one to grow on.

print "ok 17\n";

exit;
