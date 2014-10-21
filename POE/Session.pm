# $Id: Session.pm,v 1.6 1998/08/18 15:50:15 troc Exp $
# Documentation exists after __END__

package POE::Session;

use strict;
use Carp;

#------------------------------------------------------------------------------

sub new {
  my ($type, $kernel, %states) = @_;

  my $self = bless {
                    'kernel'    => $kernel,
                    'namespace' => { },
                   }, $type;

  while (my ($state, $handler) = each(%states)) {
    $self->register_state($state, $handler);
  }

  if (exists $self->{'states'}->{'_start'}) {
    $kernel->session_alloc($self);
  }
  else {
    carp "discarding session $self - no '_start' state";
  }

  undef;
}

#------------------------------------------------------------------------------

sub DESTROY {
  my $self = shift;
  delete $self->{'kernel'};
  delete $self->{'namespace'};
  delete $self->{'states'};
}

#------------------------------------------------------------------------------

sub _invoke_state {
  my ($self, $kernel, $source_session, $state, $etc) = @_;

  if ($self->{'namespace'}->{'_debug'}) {
    print "$self -> $state\n";
  }

  if (exists $self->{'states'}->{$state}) {
    &{$self->{'states'}->{$state}}($kernel, $self->{'namespace'},
                                   $source_session, @$etc
                                  );
  }
  elsif (exists $self->{'states'}->{'_default'}) {
    &{$self->{'states'}->{'_default'}}($kernel, $self->{'namespace'},
                                       $source_session, $state, @$etc
                                      );
  }
}

#------------------------------------------------------------------------------

sub register_state {
  my ($self, $state, $handler) = @_;

  if ($handler) {
    if (ref($handler) eq 'CODE') {
      carp "redefining state($state) for session($self)"
        if (exists $self->{'states'}->{$state});
      $self->{'states'}->{$state} = $handler;
    }
    elsif ($self->{'namespace'}->{'_debug'}) {
      print "$self : state($state) is not a CODE ref - not registered\n";
    }
  }
  else {
    delete $self->{'states'}->{$state};
  }
}

###############################################################################
1;
__END__

=head1 NAME

POE::Session - a state machine, driven by C<POE::Kernel>

=head1 SYNOPSIS

  new POE::Session(
    $kernel,
    '_start' => sub {
      my ($k, $me, $from) = @_;
      # initialize the session
    },
    '_stop'  => sub {
      my ($k, $me, $from) = @_;
      # shut down the session
    },
    '_default' => sub {
      my ($k, $me, $from, $state, @etc) = @_;
      # catches states for which no handlers are registered
    },
  );
                  
=head1 DESCRIPTION

C<POE::Session> builds an initial state table and registers it as a full
session with C<POE::Kernel>.  The Kernel will invoke C<_start> after the
session is registered, and C<_stop> just before destroying it.  C<_default>
is called when a signal is dispatched to a nonexistent handler.

States are invoked as:
C<&$state_code_ref($kernel, $namespace, $source_session, @$etc)>.

=head1 PUBLIC METHODS

=over 4

=item new POE::Session($kernel, 'state' => sub { ... }, ....);

Build an initial state table, and register it with a C<$kernel>.  Returns undef
always since C<$kernel> maintains it.

=back

=head1 SPECIAL NAMESPACE VARIABLES

=over 4

=item _debug

This will set the runtime debugging level for the C<POE::Session>.

Currently it only toggles (true/false) displaying states as they are
dispatched, and maybe some minor harmless warnings.

=back

=head1 SPECIAL STATES

All states except _start are optional.  Events will be discarded quietly
for any states that do not exist.

=over 4

=item _start ($kernel, $namespace, $from)

Informs a C<POE::Session> that it has been added to a C<POE::Kernel>.

C<$kernel> is a reference to the kernel that owns this session; C<$namespace>
is a reference to a hash that has been set aside for this session to store
persistent information; C<$from> is the session that sent the _start event
(usually a C<POE::Kernel>).

This is the only required state.

=item _stop ($kernel, $namespace, $from)

Informs a C<POE::Session> that is about to be removed from a C<POE::Kernel>.
Anything in C<$namespace> that Perl cannot garbage-collect should be destroyed
here to avoid leaking memory.

C<$kernel>, C<$namespace> and C<$from> are the same as for _start.

=item _default ($kernel, $namespace, $from, $state, @etc)

Informs a C<POE::Session> that it has received an event for which no state
has been registered.  Without a _default state, C<POE::Kernel> will silently
drop undeliverable events.

C<$kernel>, C<$namespace> and C<$from> are the same as for _start.  C<$state>
is the state name that would have received the event.  C<@etc> are any
additional parameters (other than C<$kernel>, C<$namespace> and C<$from>) that
would have been sent to C<$state>.

=item _child ($kernel, $namespace, $departing_session)

Informs a C<POE::Session> that a session it created (or inherited) is about
to be stopped.  One use for this is maintaining a limited pool of parallel
sub-sessions, starting new sessions when old ones go away.

C<$kernel> and C<$namespace> are the same as for _start.  C<$departing_session>
is a reference to the session going away.

=item _parent ($kernel, $namespace, $new_parent)

Informs a C<POE::Session> that its parent session is stopping, and that its
new parent will be C<$new_parent>.

C<$kernel> and C<$namespace> are the same as for _start.  C<$new_parent> is
the new parent of this session.

=back

=head1 SPECIAL STATE CLASSES

=over 4

=item Special States

These states are generated by C<POE::Kernel> and mainly deal with session
management.  Construction, destruction, and parent/child relationships.

=item Signal States

These are states that have been registered as C<%SIG> handlers by
C<POE::Kernel::sig(...)>.

=item Select States

These states are registerd to C<signal(2)> logic by C<POE::Kernel::select(...)>
and related functions.

=item Alarm States

These are states that accept delayed events sent by C<POE::Kernel::alarm(...)>,
but any state can do this, so why is it listed separately?

=item Wheel States

These states are added to and removed from sessions whenever C<POE::Wheel>
derivatives are created or destroyed.  They can last the entire life of a
session, or they can come and go depending on the current needs of a session.

=back

=head1 PROTECTED METHODS

=over 4

=item $session->_invoke_state($kernel, $source_session, $state, \@etc)

Called by C<POE::Kernel> to invoke state C<$state> generated from
C<$source_session> with a list of optional parameters in C<\@etc>.
Invokes the _defaul state if it exists and C<$state> does not.

=item $session->register_state($state, $handler)

Called back by C<POE::Kernel> to add, change or remove states from this
session.

=back

=head1 PRIVATE METHODS

=over 4

=item DESTROY

Destroys the session.  Deletes internal storage.

=back

=head1 EXAMPLES

All the programs in F<tests/> use C<POE::Session>, but especially see
F<tests/sessions.perl> and F<tests/forkbomb.perl>.

=head1 BUGS

None known.

=head1 CONTACT AND COPYRIGHT

Copyright 1998 Rocco Caputo E<lt>troc@netrus.netE<gt>.  All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
