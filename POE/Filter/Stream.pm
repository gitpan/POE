# $Id: Stream.pm,v 1.3 1999/01/28 03:37:41 troc Exp $

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Filter::Stream;

use strict;

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $self = bless { }, $type;
  $self;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $stream) = @_;
  my $buffer = join('', @$stream);
  [ $buffer ];
}

#------------------------------------------------------------------------------

sub put {
  my ($self, $chunks) = @_;
  $chunks;
}

###############################################################################
1;
