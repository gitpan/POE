# $Id: Signals.pm,v 1.12 2004/09/08 05:59:58 rcaputo Exp $

# The data necessary to manage signals, and the accessors to get at
# that data in a sane fashion.

package POE::Resources::Signals;

use vars qw($VERSION);
$VERSION = do {my@r=(q$Revision: 1.12 $=~/\d+/g);sprintf"%d."."%04d"x$#r,@r};

# These methods are folded into POE::Kernel;
package POE::Kernel;

use strict;

### Map watched signal names to the sessions that are watching them
### and the events that must be delivered when they occur.

my %kr_signals;
#  ( $signal_name =>
#    { $session_reference => $event_name,
#      ...,
#    },
#    ...,
#  );

my %kr_sessions_to_signals;
#  ( $session =>
#    { $signal_name => $event_name,
#      ...,
#    },
#    ...,
#  );

# Bookkeeping per dispatched signal.

my @kr_signaled_sessions;           # The sessions touched by a signal.
my $kr_signal_total_handled;        # How many sessions handled a signal.
my $kr_signal_type;                 # The type of signal being dispatched.

sub _data_sig_preload {
  $poe_kernel->[KR_SIGNALS] = \%kr_signals;
}
use POE::API::ResLoader \&_data_sig_preload;

# A list of special signal types.  Signals that aren't listed here are
# benign (they do not kill sessions at all).  "Terminal" signals are
# the ones that UNIX defaults to killing processes with.  Thus STOP is
# not terminal.

sub SIGTYPE_BENIGN      () { 0x00 }
sub SIGTYPE_TERMINAL    () { 0x01 }
sub SIGTYPE_NONMASKABLE () { 0x02 }

my %_signal_types =
  ( QUIT => SIGTYPE_TERMINAL,
    INT  => SIGTYPE_TERMINAL,
    KILL => SIGTYPE_TERMINAL,
    TERM => SIGTYPE_TERMINAL,
    HUP  => SIGTYPE_TERMINAL,
    IDLE => SIGTYPE_TERMINAL,
    ZOMBIE    => SIGTYPE_NONMASKABLE,
    UIDESTROY => SIGTYPE_NONMASKABLE,
  );

# Build a list of useful, real signals.  Nonexistent signals, and ones
# which are globally unhandled, usually cause segmentation faults if
# perl was poorly configured.  Some signals aren't available in some
# environments.

my %_safe_signals;

sub _data_sig_initialize {
  my $self = shift;

  # In case we're called multiple times.
  unless (keys %_safe_signals) {
    foreach my $signal (keys %SIG) {

      # Nonexistent signals, and ones which are globally unhandled.
      next if ($signal =~ /^( NUM\d+
                              |__[A-Z0-9]+__
                              |ALL|CATCHALL|DEFER|HOLD|IGNORE|MAX|PAUSE
                              |RTMIN|RTMAX|SETS
                              |SEGV
                              |
                            )$/x
              );

      # Windows doesn't have a SIGBUS, but the debugger causes SIGBUS
      # to be entered into %SIG.  It's fatal to register its handler.
      next if $signal eq 'BUS' and RUNNING_IN_HELL;

      # Apache uses SIGCHLD and/or SIGCLD itself, so we can't.
      next if $signal =~ /^CH?LD$/ and exists $INC{'Apache.pm'};

      $_safe_signals{$signal} = 1;
    }
  }

  # Must always watch SIGCHLD because it fires up the event polling
  # loop in POE::Kernel.  That loop's events are taken into
  # consideration when looking for an "idle" system, so it must always
  # run.

  $self->loop_watch_signal("CHLD");
}

### Return signals that are safe to manipulate.

sub _data_sig_get_safe_signals {
  return keys %_safe_signals;
}

### End-run leak checking.

sub _data_sig_finalize {
  my $finalized_ok = 1;

  while (my ($sig, $sig_rec) = each(%kr_signals)) {
    $finalized_ok = 0;
    _warn "!!! Leaked signal $sig\n";
    while (my ($ses, $event) = each(%{$kr_signals{$sig}})) {
      _warn "!!!\t$ses = $event\n";
    }
  }

  while (my ($ses, $sig_rec) = each(%kr_sessions_to_signals)) {
    $finalized_ok = 0;
    _warn "!!! Leaked signal cross-reference: $ses\n";
    while (my ($sig, $event) = each(%{$kr_signals{$ses}})) {
      _warn "!!!\t$sig = $event\n";
    }
  }

  return $finalized_ok;
}

### Add a signal to a session.

sub _data_sig_add {
  my ($self, $session, $signal, $event) = @_;
  $kr_sessions_to_signals{$session}->{$signal} = $event;
  $kr_signals{$signal}->{$session} = $event;

  # First session to watch the signal.  Set the signal handler in the
  # event loop.
  if (
    (keys %{$kr_signals{$signal}} == 1) and
    (exists $_safe_signals{$signal}) and
    $signal ne "CHLD" and
    $signal ne "CLD"
  ) {
    $self->loop_watch_signal($signal);
  }
}

### Remove a signal from a session.

sub _data_sig_remove {
  my ($self, $session, $signal) = @_;

  delete $kr_sessions_to_signals{$session}->{$signal};
  delete $kr_sessions_to_signals{$session}
    unless keys(%{$kr_sessions_to_signals{$session}});

  delete $kr_signals{$signal}->{$session};

  # Last watcher for that signal.  Stop watching it internally.
  unless (keys %{$kr_signals{$signal}}) {
    delete $kr_signals{$signal};
    if (exists $_safe_signals{$signal}) {
      $self->loop_ignore_signal($signal);
    }
  }
}

### Clear all the signals from a session.

# XXX - It's ok to clear signals from a session that doesn't exist.
# Usually it means that the signals are being cleared, but it might
# mean that the session really doesn't exist.  Should we care?

sub _data_sig_clear_session {
  my ($self, $session) = @_;
  return unless exists $kr_sessions_to_signals{$session}; # avoid autoviv
  foreach (keys %{$kr_sessions_to_signals{$session}}) {
    $self->_data_sig_remove($session, $_);
  }
}

### Return a signal's type, or SIGTYPE_BENIGN if it's not special.

sub _data_sig_type {
  my ($self, $signal) = @_;
  return $_signal_types{$signal} || SIGTYPE_BENIGN;
}

### Flag a signal as being handled by some session.

sub _data_sig_handled {
  my $self = shift;
  $kr_signal_total_handled++;
}

### Clear the structures associated with a signal's "handled" status.

sub _data_sig_reset_handled {
  my ($self, $signal) = @_;
  undef $kr_signal_total_handled;
  $kr_signal_type = $self->_data_sig_type($signal);
  undef @kr_signaled_sessions;
}

### Is the signal explicitly watched?

sub _data_sig_explicitly_watched {
  my ($self, $signal) = @_;
  return exists $kr_signals{$signal};
}

### Return the signals watched by a session and the events they
### generate.  -><- Used mainly for testing, but may also be useful
### for introspection.

sub _data_sig_watched_by_session {
  my ($self, $session) = @_;
  return %{$kr_sessions_to_signals{$session}};
}

### Which sessions are watching a signal?

sub _data_sig_watchers {
  my ($self, $signal) = @_;
  return %{$kr_signals{$signal}};
}

### Return the current signal's handled status.
### -><- Used for testing.

sub _data_sig_handled_status {
  return(
    $kr_signal_total_handled,
    $kr_signal_type,
    \@kr_signaled_sessions,
  );
}

### Determine if a given session is watching a signal.  This uses a
### two-step exists so that the longer one does not autovivify keys in
### the shorter one.

sub _data_sig_is_watched_by_session {
  my ($self, $signal, $session) = @_;
  return(
    exists($kr_signals{$signal}) &&
    exists($kr_signals{$signal}->{$session})
  );
}

### Destroy sessions touched by a nonmaskable signal or by an
### unhandled terminal signal.  Check for garbage-collection on
### sessions which aren't to be terminated.

sub _data_sig_free_terminated_sessions {
  my $self = shift;

  if (
    ($kr_signal_type & SIGTYPE_NONMASKABLE) or
    ($kr_signal_type & SIGTYPE_TERMINAL and !$kr_signal_total_handled)
  ) {
    foreach my $dead_session (@kr_signaled_sessions) {
      next unless $self->_data_ses_exists($dead_session);
      if (TRACE_SIGNALS) {
        _warn(
          "<sg> stopping signaled session ",
          $self->_data_alias_loggable($dead_session)
        );
      }

      $self->_data_ses_stop($dead_session);
    }
  }
  else {
    # -><- Implicit signal reaping.  This is deprecated behavior and
    # will eventually be removed.  See the commented out tests in
    # t/res/signals.t.
    foreach my $touched_session (@kr_signaled_sessions) {
      next unless $self->_data_ses_exists($touched_session);
      $self->_data_ses_collect_garbage($touched_session);
    }
  }

  # Erase @kr_signaled_sessions, or they will leak until the next
  # signal.
  undef @kr_signaled_sessions;
}

### A signal has touched a session.  Record this fact for later
### destruction tests.

sub _data_sig_touched_session {
  my ($self, $session) = @_;
  push @kr_signaled_sessions, $session;
}

1;

__END__

=head1 NAME

POE::Resources::Signals - signal management for POE::Kernel

=head1 SYNOPSIS

Used internally by POE::Kernel.  Better documentation will be
forthcoming.

=head1 DESCRIPTION

This module encapsulates and provides accessors for POE::Kernel's data
structures that manage signals.  It is used internally by POE::Kernel
and has no public interface.

=head1 SEE ALSO

See L<POE::Kernel> for documentation on signals.

=head1 BUGS

Probably.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut