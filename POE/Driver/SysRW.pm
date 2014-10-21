# $Id: SysRW.pm,v 1.6 1999/01/28 03:35:57 troc Exp $

# Copyright 1998 Rocco Caputo <troc@netrus.net>.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.

package POE::Driver::SysRW;

use strict;
use POSIX qw(EAGAIN);

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $self = bless { 'out queue'  => [ ],
                     'bytes done' => 0,
                     'bytes left' => 0,
                   }, $type;
  $self;
}

#------------------------------------------------------------------------------

sub put {
  my ($self, $chunks) = @_;
  my $old_queue_length = @{$self->{'out queue'}};
  my $new_queue_length = push @{$self->{'out queue'}}, @$chunks;
  if ($new_queue_length && (!$old_queue_length)) {
    $self->{'bytes left'} = length($self->{'out queue'}->[0]);
    $self->{'bytes done'} = 0;
  }
  $new_queue_length;
}

#------------------------------------------------------------------------------

sub get {
  my ($self, $handle) = @_;

  my $result = sysread($handle, my $buffer = '', 512);
  if ($result || ($! == EAGAIN)) {
    $! = 0;
    [ $buffer ];
  }
  else {
    undef;
  }
}

#------------------------------------------------------------------------------

sub flush {
  my ($self, $handle) = @_;
                                        # syswrite it, like we're supposed to
  while (@{$self->{'out queue'}}) {
    my $wrote_count = syswrite($handle,
                               $self->{'out queue'}->[0],
                               $self->{'bytes left'},
                               $self->{'bytes done'}
                              );

    unless ($wrote_count) {
      $! = 0 if ($! == EAGAIN);
      last;
    }

    $self->{'bytes done'} += $wrote_count;
    unless ($self->{'bytes left'} -= $wrote_count) {
      shift(@{$self->{'out queue'}});
      if (@{$self->{'out queue'}}) {
        $self->{'bytes done'} = 0;
        $self->{'bytes left'} = length($self->{'out queue'}->[0]);
      }
      else {
        $self->{'bytes done'} = $self->{'bytes left'} = 0;
      }
    }
  }

  scalar(@{$self->{'out queue'}});
}

###############################################################################
1;
