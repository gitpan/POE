# $Id: Kernel.pm,v 1.107 2000/11/19 17:05:13 rcaputo Exp $

package POE::Kernel;

use strict;
use POSIX qw(errno_h fcntl_h sys_wait_h uname signal_h);
use Carp;
use vars qw( $poe_kernel $poe_main_window );

use Exporter;
@POE::Kernel::ISA = qw(Exporter);
@POE::Kernel::EXPORT = qw( $poe_kernel $poe_main_window );

use POE::Preprocessor;

#------------------------------------------------------------------------------
# Debugging and configuration constants.  Uses two macros to assist.

macro define_trace (<const>) {
  defined &TRACE_<const> or eval 'sub TRACE_<const> () { TRACE_DEFAULT }';
}

macro define_assert (<const>) {
  defined &ASSERT_<const> or eval 'sub ASSERT_<const> () { ASSERT_DEFAULT }';
}

# Debugging flags for subsystems.  They're done as double evals here
# so that someone may define them before using POE, and the
# pre-defined value will take precedence over the defaults here.
BEGIN {

  # TRACE_DEFAULT changes the default value for other TRACE_*
  # constants.  Since the define_trace macro uses TRACE_DEFAULT
  # internally, it can't be used to define TRACE_DEFAULT itself.

  defined &TRACE_DEFAULT or eval 'sub TRACE_DEFAULT () { 0 }';

  {% define_trace EVENTS   %}
  {% define_trace GARBAGE  %}
  {% define_trace PROFILE  %}
  {% define_trace QUEUE    %}
  {% define_trace REFCOUNT %}
  {% define_trace SELECT   %}
  {% define_trace REFCOUNT %}

  # See the notes for TRACE_DEFAULT, except read ASSERT and assert
  # where you see TRACE and trace.

  defined &ASSERT_DEFAULT or eval 'sub ASSERT_DEFAULT () { 0 }';

  {% define_assert GARBAGE     %}
  {% define_assert REFCOUNT    %}
  {% define_assert RELATIONS   %}
  {% define_assert SELECT      %}
  {% define_assert SESSIONS    %}
}

# Determine which event loop is loaded (or whether none is) and set
# compile-time constants which will short-circuit the code for ones
# which aren't.  Also define dummy functions so that the
# short-circuited code can compile, even though it never will run.

BEGIN {

  # Set constants depending on which event loop we use.
  if (exists $INC{'Gtk.pm'}) {
    croak "POE can't use Tk and Gtk at once"    if exists $INC{'Tk.pm'};
    croak "POE can't use Event and Gtk at once" if exists $INC{'Event.pm'};
    eval 'sub POE_USES_GTK    () { 1 }';
    eval 'sub POE_USES_ITSELF () { 0 }';
  }
  elsif (exists $INC{'Tk.pm'}) {
    croak "POE: Can't use Tk and Event at once" if exists $INC{'Event.pm'};
    eval 'sub POE_USES_TK     () { 1 }';
    eval 'sub POE_USES_ITSELF () { 0 }';
  }
  elsif (exists $INC{'Event.pm'}) {
    eval 'sub POE_USES_EVENT  () { 1 }';
    eval 'sub POE_USES_ITSELF () { 0 }';
  }
  else {
    eval 'sub POE_USES_ITSELF () { 1 }';
  }

  # Disable behaviors for event loops which aren't loaded.
  eval 'sub POE_USES_GTK   () { 0 }' unless exists $INC{'Gtk.pm'};
  eval 'sub POE_USES_TK    () { 0 }' unless exists $INC{'Tk.pm'};
  eval 'sub POE_USES_EVENT () { 0 }' unless exists $INC{'Event.pm'};
};

#------------------------------------------------------------------------------
# Macro definitions.

macro sig_remove (<session>,<signal>) {
  delete $self->[KR_SESSIONS]->{<session>}->[SS_SIGNALS]->{<signal>};
  delete $self->[KR_SIGNALS]->{<signal>}->{<session>};
}

macro sid (<session>) {
  "session " . <session>->ID
}

macro ssid {
  "session " . $session->ID
}

macro ses_leak_hash (<field>) {
  if (my $leaked = keys(%{$sessions->{$session}->[<field>]})) {
    warn {% ssid %}, " leaked $leaked <field>\a\n";
    $errors++;
  }
}

macro kernel_leak_hash (<field>) {
  if (my $leaked = keys %{$self->[<field>]}) {
    warn "*** KERNEL HASH LEAK: <field> = $leaked\a\n";
  }
}

macro kernel_leak_vec (<field>) {
  { my $bits = unpack('b*', $self->[KR_VECTORS]->[<field>]);
    if (index($bits, '1') >= 0) {
      warn "*** KERNEL VECTOR LEAK: <field> = $bits\a\n";
    }
  }
}

macro kernel_leak_array (<field>) {
  if (my $leaked = @{$self->[<field>]}) {
    warn "*** KERNEL ARRAY LEAK: <field> = $leaked\a\n";
  }
}

macro assert_session_refcount (<session>,<count>) {
  if (ASSERT_REFCOUNT) { # include
    die {% sid <session> %}, " reference count <count> went below zero\n"
      if $self->[KR_SESSIONS]->{<session>}->[<count>] < 0;
  } # include
}


macro ses_refcount_dec (<session>) {
  $self->[KR_SESSIONS]->{<session>}->[SS_REFCOUNT]--;
  {% assert_session_refcount <session>, SS_REFCOUNT %}
}

macro ses_refcount_dec2 (<session>,<count>) {
  $self->[KR_SESSIONS]->{<session>}->[<count>]--;
  {% assert_session_refcount <session>, <count> %}
  {% ses_refcount_dec <session> %}
}

macro ses_refcount_inc (<session>) {
  $self->[KR_SESSIONS]->{<session>}->[SS_REFCOUNT]++;
}

macro ses_refcount_inc2 (<session>,<count>) {
  $self->[KR_SESSIONS]->{<session>}->[<count>]++;
  {% ses_refcount_inc <session> %}
}

macro remove_extra_reference (<session>,<tag>) {
  delete $self->[KR_SESSIONS]->{<session>}->[SS_EXTRA_REFS]->{<tag>};

  {% ses_refcount_dec <session> %}

  $self->[KR_EXTRA_REFS]--;
  if (ASSERT_REFCOUNT) { # include
    die( "--- ", {% ssid %}, " refcounts for kernel dropped below 0")
      if $self->[KR_EXTRA_REFS] < 0;
  } # include
}

# There is an string equality test in alias_resolve that should not be
# made into a numeric equality test.  <name> is often a string.

macro alias_resolve (<name>) {
  # Resolve against sessions.
  ( (exists $self->[KR_SESSIONS]->{<name>})
    ? $self->[KR_SESSIONS]->{<name>}->[SS_SESSION]
    # Resolve against IDs.
    : ( (exists $self->[KR_SESSION_IDS]->{<name>})
        ? $self->[KR_SESSION_IDS]->{<name>}
        # Resolve against aliases.
        : ( (exists $self->[KR_ALIASES]->{<name>})
            ? $self->[KR_ALIASES]->{<name>}
            # Resolve against self.
            : ( (<name> eq $self)
                ? $self
                # Game over!
                : undef
              )
          )
      )
  )
}

macro collect_garbage (<session>) {
  if (<session> != $self) {
    # The next line is necessary for some strange reason.  This feels
    # like a kludge, but I'm currently not smart enough to figure out
    # what it's working around.
    if (exists $self->[KR_SESSIONS]->{<session>}) {
      if (TRACE_GARBAGE) { # include
        $self->trace_gc_refcount(<session>);
      } # include
      if (ASSERT_GARBAGE) { # include
        $self->assert_gc_refcount(<session>);
      } # include

      if ( (exists $self->[KR_SESSIONS]->{<session>})
           and (!$self->[KR_SESSIONS]->{<session>}->[SS_REFCOUNT])
         ) {
        $self->session_free(<session>);
      }
    }
  }
}

macro validate_handle (<handle>,<vector>) {
  # Don't bother if the kernel isn't tracking the file.
  return 0 unless exists $self->[KR_HANDLES]->{<handle>};

  # Don't bother if the kernel isn't tracking the file mode.
  return 0 unless $self->[KR_HANDLES]->{<handle>}->[HND_VECCOUNT]->[<vector>];
}

macro remove_alias (<session>,<alias>) {
  delete $self->[KR_ALIASES]->{<alias>};
  delete $self->[KR_SESSIONS]->{<session>}->[SS_ALIASES]->{<alias>};
  {% ses_refcount_dec <session> %}
}

macro state_to_enqueue {
  [ @_[1..8], ++$queue_seqnum ]
}

macro test_resolve (<name>,<resolved>) {
  unless (defined <resolved>) {
    if (ASSERT_SESSIONS) { # include
      confess "Cannot resolve <name> into a session reference\n";
    } # include
    $! = ESRCH;
    return undef;
  }
}

macro test_for_idle_poe_kernel {
  if (TRACE_REFCOUNT) { # include
    warn( ",----- Kernel Activity -----\n",
          "| States : ", scalar(@{$self->[KR_STATES]}), "\n",
          "| Alarms : ", scalar(@{$self->[KR_ALARMS]}), "\n",
          "| Files  : ", scalar(keys(%{$self->[KR_HANDLES]})), "\n",
          "|   `--> : ", join(', ', keys(%{$self->[KR_HANDLES]})), "\n",
          "| Extra  : ", $self->[KR_EXTRA_REFS], "\n",
          "`---------------------------\n",
          " ..."
         );
  } # include

  unless ( @{$self->[KR_STATES]} or
           @{$self->[KR_ALARMS]} or
           keys(%{$self->[KR_HANDLES]}) or
           $self->[KR_EXTRA_REFS]
         ) {
    $self->_enqueue_state( $self, $self,
                           EN_SIGNAL, ET_SIGNAL,
                           [ 'IDLE' ],
                           time(), __FILE__, __LINE__
                         )
      if keys %{$self->[KR_SESSIONS]};
  }
}

macro post_plain_signal (<destination>,<signal_name>) {
  $poe_kernel->_enqueue_state( <destination>, $poe_kernel,
                               EN_SIGNAL, ET_SIGNAL,
                               [ <signal_name> ],
                               time(), __FILE__, __LINE__
                             );
}

macro dispatch_one_from_fifo {
  # Pull an event off the queue, and dispatch it.
  if ( @{ $self->[KR_STATES] } ) {
    my $event = shift @{ $self->[KR_STATES] };
    {% ses_refcount_dec2 $event->[ST_SESSION], SS_EVCOUNT %}
    $self->_dispatch_state(@$event);
  }
}

macro dispatch_due_alarms {
  # Pull due alarms off the queue, and dispatch them.
  my $now = time();
  while ( @{ $self->[KR_ALARMS] } and
          ($self->[KR_ALARMS]->[0]->[ST_TIME] <= $now)
        ) {
    my $event = shift @{ $self->[KR_ALARMS] };
    {% ses_refcount_dec2 $event->[ST_SESSION], SS_ALCOUNT %}
    $self->_dispatch_state(@$event);
  }
}

macro dispatch_ready_selects {
  my @selects =
    values %{ $self->[KR_HANDLES]->{$handle}->[HND_SESSIONS]->[$vector] };

  foreach my $select (@selects) {
    $self->_dispatch_state
      ( $select->[HSS_SESSION], $select->[HSS_SESSION],
        $select->[HSS_STATE], ET_SELECT,
        [ $select->[HSS_HANDLE] ],
        time(), __FILE__, __LINE__, undef
      );
  }
}

# MACROS END <-- search tag for editing

#------------------------------------------------------------------------------

# Perform some optional setup.
BEGIN {
  local $SIG{'__DIE__'} = 'DEFAULT';

  # Include Time::HiRes, which is pretty darned cool, if it's
  # available.  Life goes on without it.
  eval {
    require Time::HiRes;
    import  Time::HiRes qw(time);
  };

  # Set a constant to indicate the presence of Time::HiRes.  This
  # enables some runtime optimization.
  if ($@) {
    eval 'sub POE_USES_TIME_HIRES () { 0 }';
  }
  else {
    eval 'sub POE_USES_TIME_HIRES () { 1 }';
  }

  # http://support.microsoft.com/support/kb/articles/Q150/5/37.asp
  # defines EINPROGRESS as 10035.  We provide it here because some
  # Win32 users report POSIX::EINPROGRESS is not vendor-supported.
  if ($^O eq 'MSWin32') {
    eval '*EINPROGRESS = sub { 10036 };';
    eval '*EWOULDBLOCK = sub { 10035 };';
    eval '*F_GETFL     = sub {     0 };';
    eval '*F_SETFL     = sub {     0 };';
  }
}

#------------------------------------------------------------------------------
# globals

$poe_kernel = undef;                    # only one active kernel; sorry

#------------------------------------------------------------------------------

# Handles and vectors sub-fields.
enum VEC_RD VEC_WR VEC_EX

# Session structure
enum   SS_SESSION SS_REFCOUNT SS_EVCOUNT SS_PARENT SS_CHILDREN SS_HANDLES
enum + SS_SIGNALS SS_ALIASES  SS_PROCESSES SS_ID SS_EXTRA_REFS SS_ALCOUNT

# session handle structure
enum   SH_HANDLE SH_REFCOUNT SH_VECCOUNT

# The Kernel object.  KR_SIZE goes last (it's the index count).
enum   KR_SESSIONS KR_VECTORS KR_HANDLES KR_STATES KR_SIGNALS KR_ALIASES
enum + KR_ACTIVE_SESSION KR_PROCESSES KR_ALARMS KR_ID KR_SESSION_IDS
enum + KR_ID_INDEX KR_WATCHER_TIMER KR_WATCHER_IDLE KR_EXTRA_REFS KR_SIZE

# Handle structure.
enum HND_HANDLE HND_REFCOUNT HND_VECCOUNT HND_SESSIONS HND_WATCHERS

# Handle session structure.
enum HSS_HANDLE HSS_SESSION HSS_STATE

# State transition events.
enum ST_SESSION ST_SOURCE ST_NAME ST_TYPE ST_ARGS

# These go towards the end, in this order, because they're optional
# parameters in some cases.
enum + ST_TIME ST_OWNER_FILE ST_OWNER_LINE ST_SEQ

# These are names of internal events.

const EN_START  '_start'
const EN_STOP   '_stop'
const EN_SIGNAL '_signal'
const EN_GC     '_garbage_collect'
const EN_PARENT '_parent'
const EN_CHILD  '_child'
const EN_SCPOLL '_sigchld_poll'

# These are ways a child may come or go.

const CHILD_GAIN   'gain'
const CHILD_LOSE   'lose'
const CHILD_CREATE 'create'

# These are event classes (types).  They often shadow actual event
# names, but they can encompass a large group of events.  For example,
# ET_ALARM describes anything posted by an alarm call.  Types are
# preferred over names because bitmask tests tend to be faster than
# string equality checks.

const ET_USER     0x0001
const ET_CALL     0x0002
const ET_START    0x0004
const ET_STOP     0x0008
const ET_SIGNAL   0x0010
const ET_GC       0x0020
const ET_PARENT   0x0040
const ET_CHILD    0x0080
const ET_SCPOLL   0x0100
const ET_ALARM    0x0200
const ET_SELECT   0x0400

# The amount of time to spend dispatching FIFO events.  Increasing
# this value will improve POE's FIFO dispatch performance by
# increasing the time between select and alarm checks.

const FIFO_DISPATCH_TIME 0.01

#------------------------------------------------------------------------------
# Here is a roadmap of POE's internal data structures.  It's complex
# enough that even the author needs a scorecard.
#------------------------------------------------------------------------------
#
# states:
# [ [ $session, $source_session, $state, $type, \@etc, $time,
#     $poster_file, $poster_line, $debug_sequence
#   ],
#   ...
# ]
#
# alarms:
# [ [ $session, $source_session, $state, $type, \@etc, $time,
#     $poster_file, $poster_line, $debug_sequence
#   ],
#   ...
# ]
#
# processes: { $pid => $parent_session, ... }
#
# kernel ID: { $kernel_id }
#
# session IDs: { $id => $session, ... }
#
# files:
# { $handle =>
#   [ $handle,
#     $refcount,
#     [ $ref_r, $ref_w, $ref_x ],
#     [ { $session => [ $handle, $session, $state ], .. },
#       { $session => [ $handle, $session, $state ], .. },
#       { $session => [ $handle, $session, $state ], .. }
#     ],
#     [ $watcher_r, $watcher_w, $watcher_x ],
#   ]
# };
#
# vectors: [ $read_vector, $write_vector, $expedite_vector ];
#
# signals: { $signal => { $session => $state, ... } };
#
# sessions:
# { $session =>
#   [ $session,     # blessed version of the key
#     $refcount,    # number of things keeping this alive
#     $evcnt,       # event count
#     $parent,      # parent session
#     { $child => $child, ... },
#     { $handle =>
#       [ $handle,
#         $refcount,
#         [ $r, $w, $e ]
#       ],
#       ...
#     },
#     { $signal => $state, ... },
#     { $name => 1, ... },
#     { $pid => 1, ... },          # child processes
#     $session_id,                 # session ID
#     { $tag => $count, ... },     # extra reference counts
#     $alarm_count,                # alarm count
#   ]
# };
#
# names: { $name => $session };
#
#------------------------------------------------------------------------------

#==============================================================================
# SIGNALS
#==============================================================================

# This is a list of signals that will terminate sessions that don't
# handle them.

my %_terminal_signals =
  ( QUIT => 1, INT => 1, KILL => 1, TERM => 1, HUP => 1, IDLE => 1 );

### POE's signal handlers.  These are just plain old Perl.

sub _poe_signal_handler_generic {
  if (defined $_[0]) {
    {% post_plain_signal $poe_kernel, $_[0] %}
    $SIG{$_[0]} = \&_poe_signal_handler_generic;
  }
  else {
    warn "POE::Kernel::_signal_handler_generic detected an undefined signal";
  }
}

# SIGPIPE is handled a little differently.  It tends to be
# synchronous, so it's posted at the current active session.  We can
# do this better by generating a pseudo SIGPIPE whenever a driver
# returns EPIPE, but that requires people to use Wheel::ReadWrite or
# similar dilligence.

sub _poe_signal_handler_pipe {
  if (defined $_[0]) {
    {% post_plain_signal $poe_kernel->[KR_ACTIVE_SESSION], $_[0] %}
    $SIG{$_[0]} = \&_poe_signal_handler_pipe;
  }
  else {
    warn "POE::Kernel::_signal_handler_pipe detected an undefined signal";
  }
}

# SIGCH?LD are normalized to SIGCHLD and include the child process'
# PID and return code.  Philip Gwyn rewrote most of the SIGCH?LD code
# for version 0.1006; it got rewritten again while the patches were
# manually applied.  I expect it to be rewritten a few more times as
# it approaches Philip's original code.

sub _poe_signal_handler_child {
  if (defined $_[0]) {

    # The default SIGCH?LD action is "discard".  We set it here to
    # prevent Perl from catching more SIGCHLD signals while the Kernel
    # polls for child processes.
    $SIG{$_[0]} = 'DEFAULT';
    $poe_kernel->_enqueue_state( $poe_kernel, $poe_kernel,
                                 EN_SCPOLL, ET_SCPOLL,
                                 [ ],
                                 time(), __FILE__, __LINE__
                               );
  }
  else {
    warn "POE::Kernel::_signal_handler_child detected an undefined signal";
  }
}

### Event's signal handlers.

sub _event_signal_handler_generic {
  {% post_plain_signal $poe_kernel, $_[0]->w->signal %}
}

sub _event_signal_handler_pipe {
  {% post_plain_signal $poe_kernel->[KR_ACTIVE_SESSION], $_[0]->w->signal %}
}

sub _event_signal_handler_child {
  $poe_kernel->_enqueue_state( $poe_kernel, $poe_kernel,
                               EN_SCPOLL, ET_SCPOLL,
                               [ ],
                               time(), __FILE__, __LINE__
                             );
}

#------------------------------------------------------------------------------
# Register or remove signals.

# Public interface for adding or removing signal handlers.

sub sig {
  my ($self, $signal, $state) = @_;
  if (defined $state) {
    my $session = $self->[KR_ACTIVE_SESSION];
    $self->[KR_SESSIONS]->{$session}->[SS_SIGNALS]->{$signal} = $state;
    $self->[KR_SIGNALS]->{$signal}->{$session} = $state;
  }
  else {
    {% sig_remove $self->[KR_ACTIVE_SESSION], $signal %}
  }
}

# Public interface for posting signal events.  5.6.0 places a signal
# symbol in our table; the BEGIN block deletes it to prevent
# "Subroutine signal redefined" warnings.

BEGIN { delete $POE::Kernel::{signal}; }
sub POE::Kernel::signal {
  my ($self, $destination, $signal) = @_;

  my $session = {% alias_resolve $destination %};
  {% test_resolve $destination, $session %}

  $self->_enqueue_state( $session, $self->[KR_ACTIVE_SESSION],
                         EN_SIGNAL, ET_SIGNAL,
                         [ $signal ],
                         time(), (caller)[1,2]
                       );
}

#==============================================================================
# KERNEL
#==============================================================================

# This is a UI callback.  It maps UI destruction to a non-maskable
# virtual UIDESTROY signal.  Don't bother broadcasting UIDESTROY if
# there are no sessions remaining.  This is the case when POE exits
# before its main window.
sub signal_ui_destroy {
  if (keys %{$poe_kernel->[KR_SESSIONS]}) {
    $poe_kernel->_dispatch_state
      ( $poe_kernel, $poe_kernel,
        EN_SIGNAL, ET_SIGNAL, [ 'UIDESTROY' ],
        time(), __FILE__, __LINE__, undef
      );
  }

  # Undef allows Gtk to destroy the window.
  return undef;
}

sub new {
  my $type = shift;

  # Prevent multiple instances, no matter how many times it's called.
  # This is a backward-compatibility enhancement for programs that
  # have used versions prior to 0.06.
  unless (defined $poe_kernel) {

    if (POE_USES_GTK) { # include
      Gtk->init;

      $poe_main_window = Gtk::Window->new('toplevel');
      die "could not create a main Gk window" unless defined $poe_main_window;

      $poe_main_window->signal_connect(delete_event => \&signal_ui_destroy );

    } elsif (POE_USES_TK) { # include
      $poe_main_window = Tk::MainWindow->new();
      die "could not create a main Tk window" unless defined $poe_main_window;

      $poe_main_window->OnDestroy( \&signal_ui_destroy );

    } # include
    
    my $self = $poe_kernel = bless
      [ { },                            # KR_SESSIONS
        [ '', '', '' ],                 # KR_VECTORS
        { },                            # KR_HANDLES
        [ ],                            # KR_STATES
        { },                            # KR_SIGNALS
        { },                            # KR_ALIASES
        undef,                          # KR_ACTIVE_SESSION
        { },                            # KR_PROCESSES
        [ ],                            # KR_ALARMS
        undef,                          # KR_ID
        { },                            # KR_SESSION_IDS
        1,                              # KR_ID_INDEX
        undef,                          # KR_WATCHER_TIMER
        undef,                          # KR_WATCHER_IDLE
        0,                              # KR_EXTRA_REFS
      ], $type;

    # If POE uses Event to drive its queues, then one-time initialize
    # watchers for idle and timed events.

    if (POE_USES_EVENT) { # include
      $self->[KR_WATCHER_TIMER] = Event->timer
        ( cb     => \&_event_alarm_callback,
          after  => 0,
          parked => 1,
        );

      $self->[KR_WATCHER_IDLE] = Event->idle
        ( cb     => \&_event_fifo_callback,
          repeat => 1,
          min    => 0,
          max    => 0,
          parked => 1,
        );

    } # include

    # Kernel ID, based on Philip Gwyn's code.  I hope he still can
    # recognize it.  KR_SESSION_IDS is a hash because it will almost
    # always be sparse.
    $self->[KR_ID] = ( (uname)[1] . '-' .
                       unpack 'H*', pack 'N*', time, $$
                     );
    $self->[KR_SESSION_IDS]->{$self->[KR_ID]} = $self;

    # Initialize the vectors as vectors.
    vec($self->[KR_VECTORS]->[VEC_RD], 0, 1) = 0;
    vec($self->[KR_VECTORS]->[VEC_WR], 0, 1) = 0;
    vec($self->[KR_VECTORS]->[VEC_EX], 0, 1) = 0;

    # Register all known signal handlers, except the troublesome ones.
    foreach my $signal (keys(%SIG)) {

      # Some signals aren't real, and the act of setting handlers for
      # them can have strange, even fatal side effects.  Recognize and
      # ignore them.
      next if ($signal =~ /^( NUM\d+
                              |__[A-Z0-9]+__
                              |ALL|CATCHALL|DEFER|HOLD|IGNORE|MAX|PAUSE
                              |RTMIN|RTMAX|SETS
                              |SEGV
                              |
                            )$/x
              );

      # Artur has been experiencing problems where POE programs crash
      # after resizing xterm windows.  It was discovered that the
      # xterm resizing was sending several WINCH signals, which
      # eventually causes Perl to become unstable.  Ignoring SIGWINCH
      # seems to prevent the problem, but it's only a temporary
      # solution.  At some point, POE will include a set of Curses
      # widgets, and SIGWINCH will be needed...
      if ($signal eq 'WINCH') {

        # Event polls signals in some XS, which means they ought not
        # kill Perl.  Use an Event->signal watcher if Event is
        # available.

        if (POE_USES_EVENT) { # include
          Event->signal( signal => $signal,
                         cb     => \&_event_signal_handler_generic
                       );

        } else { # include
          # Otherwise ignore WINCH.
          $SIG{$signal} = 'IGNORE';
          next;

        } # include
      }

      # Windows doesn't have a SIGBUS, but the debugger causes SIGBUS
      # to be entered into %SIG.  Registering a handler for it becomes
      # a fatal error.  Don't do that!
      if ($signal eq 'BUS' and $^O eq 'MSWin32') {
        next;
      }

      # Register signal handlers by type.
      if ($signal =~ /^CH?LD$/) {

        # Leave SIGCHLD alone if running under apache.
        unless (exists $INC{'Apache.pm'}) {

          # Register an Event signal watcher on it.  Rename the signal
          # 'CHLD' regardless whether it's CHLD or CLD.

          if (POE_USES_EVENT) { # include
            Event->signal( signal => $signal,
                           cb     => \&_event_signal_handler_child
                         );

          } else { # include
            # Otherwise register a regular Perl signal handler.
            $SIG{$signal} = \&_poe_signal_handler_child;

          } # include
        }
      }
      elsif ($signal eq 'PIPE') {

        # Register an Event signal watcher.
        if (POE_USES_EVENT) { # include
          Event->signal( signal => $signal,
                         cb     => \&_event_signal_handler_pipe
                       );

        } else { # include
          # Otherwise register a plain Perl signal handler.
          $SIG{$signal} = \&_poe_signal_handler_pipe;

        } # include

      }
      else {
        if (POE_USES_EVENT) { # include
          # If Event is available, register a signal watcher with it.
          # Don't register a SIGKILL handler, though, because Event
          # doesn't like that.
          if ($signal ne 'KILL' and $signal ne 'STOP') {
            Event->signal( signal => $signal,
                           cb     => \&_event_signal_handler_generic
                         );
          }

        } else { # include
          # Otherwise register a plain signal handler.
          $SIG{$signal} = \&_poe_signal_handler_generic;

        } # include
      }

      $self->[KR_SIGNALS]->{$signal} = { };
    }

    # The kernel is a session, sort of.
    $self->[KR_ACTIVE_SESSION] = $self;
    $self->[KR_SESSIONS]->{$self} =
      [ $self,                          # SS_SESSION
        0,                              # SS_REFCOUNT
        0,                              # SS_EVCOUNT
        undef,                          # SS_PARENT
        { },                            # SS_CHILDREN
        { },                            # SS_HANDLES
        { },                            # SS_SIGNALS
        { },                            # SS_ALIASES
        { },                            # SS_PROCESSES
        $self->[KR_ID],                 # SS_ID
        { },                            # SS_EXTRA_REFS
        0,                              # SS_ALCOUNT
      ];
  }

  # Return the global instance.
  $poe_kernel;
}

#------------------------------------------------------------------------------
# Send a state to a session right now.  Used by _disp_select to
# expedite select() states, and used by run() to deliver posted states
# from the queue.

if (TRACE_PROFILE) { # include
  # This is for collecting state frequencies if TRACE_PROFILE is enabled.
  my %profile;
} # include

# Dispatch a state transition event to its session.  A lot of work
# goes on here.

sub _dispatch_state {
  my ( $self, $session, $source_session, $state, $type, $etc, $time,
       $file, $line, $seq
     ) = @_;

  # A copy of the state name, in case we have to change it.
  my $local_state = $state;

  # We do a lot with the sessions structure.  Cache it in a lexical to
  # save on dereferences.
  my $sessions = $self->[KR_SESSIONS];

  if (TRACE_PROFILE) { # include
    $profile{$state}++;
  } # include

  # Pre-dispatch processing.

  unless ($type & (ET_USER | ET_CALL)) {

    # The _start state is dispatched immediately as part of allocating
    # a session.  Set up the kernel's tables for this session.

    if ($type & ET_START) {
      my $new_session = $sessions->{$session} =
        [ $session,                     # SS_SESSION
          0,                            # SS_REFCOUNT
          0,                            # SS_EVCOUNT
          $source_session,              # SS_PARENT
          { },                          # SS_CHILDREN
          { },                          # SS_HANDLES
          { },                          # SS_SIGNALS
          { },                          # SS_ALIASES
          { },                          # SS_PROCESSES
          $self->[KR_ID_INDEX]++,       # SS_ID
          { },                          # SS_EXTRA_REFS
          0,                            # SS_ALCOUNT
        ];

      # For the ID to session reference lookup.
      $self->[KR_SESSION_IDS]->{$new_session->[SS_ID]} = $session;

      if (ASSERT_RELATIONS) { # include
        # Ensure sanity.
        die {% ssid %}, " is its own parent\a" if $session == $source_session;

        die( {% ssid %},
             " already is a child of ", {% sid $source_session %}, "\a"
           )
          if (exists $sessions->{$source_session}->[SS_CHILDREN]->{$session});

      } # include

      # Add the new session to its parent's children.
      $sessions->{$source_session}->[SS_CHILDREN]->{$session} = $session;
      {% ses_refcount_inc $source_session %}
    }

    # Some sessions don't do anything in _start and expect their
    # creators to provide a start-up event.  This means we can't
    # &_collect_garbage at _start time.  Instead, we post a
    # garbage-collect event at start time, and &_collect_garbage at
    # delivery time.  This gives the session's creator time to do
    # things with it before we reap it.

    elsif ($type & ET_GC) {
      {% collect_garbage $session %}
      return 0;
    }

    # A session's about to stop.  Notify its parents and children of
    # the impending change in their relationships.  Incidental _stop
    # events are handled before the dispatch.

    elsif ($type & ET_STOP) {

      # Tell child sessions that they have a new parent (the departing
      # session's parent).  Tell the departing session's parent that
      # it has new child sessions.

      my $parent   = $sessions->{$session}->[SS_PARENT];
      my @children = values %{$sessions->{$session}->[SS_CHILDREN]};
      foreach my $child (@children) {
        $self->_dispatch_state( $parent, $self,
                                EN_CHILD, ET_CHILD,
                                [ CHILD_GAIN, $child ],
                                time(), $file, $line, undef
                              );
        $self->_dispatch_state( $child, $self,
                                EN_PARENT, ET_PARENT,
                                [ $sessions->{$child}->[SS_PARENT], $parent, ],
                                time(), $file, $line, undef
                              );
      }

      # Tell the departing session's parent that the departing session
      # is departing.
      if (defined $parent) {
        $self->_dispatch_state( $parent, $self,
                                EN_CHILD, ET_CHILD,
                                [ CHILD_LOSE, $session ],
                                time(), $file, $line, undef
                              );
      }
    }

    # Preprocess signals.  This is where _signal is translated into
    # its registered handler's state name, if there is one.

    elsif ($type & ET_SIGNAL) {
      my $signal = $etc->[0];

      # Propagate the signal to this session's children.  This happens
      # first, making the signal's traversal through the parent/child
      # tree depth first.  It ensures that signals posted to the
      # Kernel are delivered to the Kernel last.

      my @children = values %{$sessions->{$session}->[SS_CHILDREN]};
      foreach (@children) {
        $self->_dispatch_state( $_, $self,
                                $state, ET_SIGNAL,
                                $etc,
                                time(), $file, $line, undef
                              );
      }

      # Translate the '_signal' state to its handler's name.

      if (exists $self->[KR_SIGNALS]->{$signal}->{$session}) {
        $local_state = $self->[KR_SIGNALS]->{$signal}->{$session};
      }
    }
  }

  # The destination session doesn't exist.  This indicates sloppy
  # programming.

  unless (exists $self->[KR_SESSIONS]->{$session}) {

    if (TRACE_EVENTS) { # include
      warn ">>> discarding $state to nonexistent ", {% ssid %}, "\n";
    } # include

    return;
  }

  if (TRACE_EVENTS) { # include
    warn ">>> dispatching $state to $session ", {% ssid %}, "\n";
    if ($state eq EN_SIGNAL) {
      warn ">>>     signal($etc->[0])\n";
    }
  } # include

  # Prepare to call the appropriate state.  Push the current active
  # session on Perl's call stack.
  my $hold_active_session = $self->[KR_ACTIVE_SESSION];
  $self->[KR_ACTIVE_SESSION] = $session;

  # Dispatch the event, at long last.
  my $return =
    $session->_invoke_state($source_session, $local_state, $etc, $file, $line);

  # Stringify the state's return value if it belongs in the POE
  # namespace.  $return's scope exists beyond the post-dispatch
  # processing, which includes POE's garbage collection.  The scope
  # bleed was known to break determinism in surprising ways.

  if (defined $return) {
    if (substr(ref($return), 0, 5) eq 'POE::') {
      $return = "$return";
    }
  }
  else {
    $return = '';
  }

  # Pop the active session, now that it's not active anymore.
  $self->[KR_ACTIVE_SESSION] = $hold_active_session;

  if (TRACE_EVENTS) { # include
    warn "<<< ", {% ssid %}, " -> $state returns ($return)\n";
  } # include

  # Post-dispatch processing.  This is a user event (but not a call),
  # so garbage collect it.

  if ($type & ET_USER) {
    {% collect_garbage $session %}
  }

  # A new session has started.  Tell its parent.  Incidental _start
  # events are fired after the dispatch.  Garbage collection is
  # delayed until ET_GC.

  if ($type & ET_START) {
    $self->_dispatch_state( $sessions->{$session}->[SS_PARENT], $self,
                            EN_CHILD, ET_CHILD,
                            [ CHILD_CREATE, $session, $return ],
                            time(), $file, $line, undef
                          );
  }

  # This session has stopped.  Clean up after it.  There's no
  # garbage collection necessary since the session's stopped.

  elsif ($type & ET_STOP) {

    # Remove the departing session from its parent.

    my $parent = $sessions->{$session}->[SS_PARENT];
    if (defined $parent) {

      if (ASSERT_RELATIONS) { # include
        die {% ssid %}, " is its own parent\a" if ($session == $parent);
        die {% ssid %}, " is not a child of ", {% sid $parent %}, "\a"
          unless ( ($session == $parent) or
                   exists($sessions->{$parent}->[SS_CHILDREN]->{$session})
                 );
      } # include

      delete $sessions->{$parent}->[SS_CHILDREN]->{$session};
      {% ses_refcount_dec $parent %}
    }

    # Give the departing session's children to its parent.

    my @children = values %{$sessions->{$session}->[SS_CHILDREN]};
    foreach (@children) {

      if (ASSERT_RELATIONS) { # include
        die {% sid $_ %}, " is already a child of ", {% sid $parent %}, "\a"
          if (exists $sessions->{$parent}->[SS_CHILDREN]->{$_});
      } # include

      $sessions->{$_}->[SS_PARENT] = $parent;
      if (defined $parent) {
        $sessions->{$parent}->[SS_CHILDREN]->{$_} = $_;
        {% ses_refcount_inc $parent %}
      }

      delete $sessions->{$session}->[SS_CHILDREN]->{$_};
      {% ses_refcount_dec $session %}
    }

    # Free any signals that the departing session allocated.

    my @signals = keys %{$sessions->{$session}->[SS_SIGNALS]};
    foreach (@signals) {
      {% sig_remove $session, $_ %}
    }

    # Free any events that the departing session has in the queue.

    my $states = $self->[KR_STATES];
    my $index = @$states;
    while ($index-- && $sessions->{$session}->[SS_EVCOUNT]) {
      if ($states->[$index]->[ST_SESSION] == $session) {
        {% ses_refcount_dec2 $session, SS_EVCOUNT %}
        splice(@$states, $index, 1);
      }
    }

    # Free any alarms that the departing session has in its queue.

    my $alarms = $self->[KR_ALARMS];
    $index = @$alarms;
    while ($index-- && $sessions->{$session}->[SS_ALCOUNT]) {
      if ($alarms->[$index]->[ST_SESSION] == $session) {
        {% ses_refcount_dec2 $session, SS_ALCOUNT %}
        splice(@$alarms, $index, 1);
      }
    }

    # Close any selects that the session still has open.  -><- This is
    # heavy handed; it does work it doesn't need to do.  There must be
    # a better way.

    my @handles = values %{$sessions->{$session}->[SS_HANDLES]};
    foreach (@handles) {
      $self->_internal_select($session, $_->[SH_HANDLE], undef, VEC_RD);
      $self->_internal_select($session, $_->[SH_HANDLE], undef, VEC_WR);
      $self->_internal_select($session, $_->[SH_HANDLE], undef, VEC_EX);
    }

    # Close any lingering extra references.
    my @extra_refs = keys %{$sessions->{$session}->[SS_EXTRA_REFS]};
    foreach (@extra_refs) {
      {% remove_extra_reference $session, $_ %}
    }

    # Release any aliases still registered to the session.

    my @aliases = keys %{$sessions->{$session}->[SS_ALIASES]};
    foreach (@aliases) {
      {% remove_alias $session, $_ %}
    }

    # Clear the session ID.  The undef part is completely gratuitous;
    # I don't know why I put it there.  -><- The defined test is a
    # kludge; it appears to be undefined when running in Tk mode.

    delete $self->[KR_SESSION_IDS]->{$sessions->{$session}->[SS_ID]}
      if defined $sessions->{$session}->[SS_ID];
    $session->[SS_ID] = undef;

    # And finally, check all the structures for leakage.  POE's pretty
    # complex internally, so this is a happy fun check.

    if (ASSERT_GARBAGE) { # include
      my $errors = 0;

      if (my $leaked = $sessions->{$session}->[SS_REFCOUNT]) {
        warn {% ssid %}, " has a refcount leak: $leaked\a\n";
        $errors++;
      }

      foreach my $l (sort keys %{$sessions->{$session}->[SS_EXTRA_REFS]}) {
        my $count = $sessions->{$session}->[SS_EXTRA_REFS]->{$l};
        if ($count) {
          warn( {% ssid %}, " leaked an extra reference: ",
                "(tag=$l) (count=$count)\a\n"
              );
          $errors++;
        }
      }

      {% ses_leak_hash SS_CHILDREN %}
      {% ses_leak_hash SS_HANDLES  %}
      {% ses_leak_hash SS_SIGNALS  %}
      {% ses_leak_hash SS_ALIASES  %}

      die "\a" if ($errors);

    } # include

    # Remove the session's structure from the kernel's structure.
    delete $sessions->{$session};

    # See if the parent should leave, too.

    if (defined $parent) {
      {% collect_garbage $parent %}
    }

    # Finally, if there are no more sessions, stop the main loop.
    unless (keys %$sessions) {

      if (POE_USES_GTK) { # include
        # Stop Gtk's loop.  ->gtk<- I'm working on voodoo here.
        $poe_main_window->destroy();
        Gtk->main_quit();

      } elsif (POE_USES_TK) { # include
        # Stop Tk's loop.
        $self->[KR_WATCHER_IDLE]  = undef;
        $self->[KR_WATCHER_TIMER] = undef;
        $poe_main_window->destroy();

      } elsif (POE_USES_EVENT) { # include
        # Stop Event's loop.
        $self->[KR_WATCHER_IDLE]->stop();
        $self->[KR_WATCHER_TIMER]->stop();
        Event::unloop_all(0);

      } # include

      # POE's own loop stops on its own.
    }
  }

  # Check for death by terminal signal.

  elsif ($type & ET_SIGNAL) {
    my $signal = $etc->[0];

    # Determine if the signal is fatal and some junk.
    if ( ($signal eq 'ZOMBIE') or
         ($signal eq 'UIDESTROY') or
         (!$return && exists($_terminal_signals{$signal}))
       ) {
      $self->session_free($session);
    }

    # It's not fatal.  Collect garbage.
    else {
      {% collect_garbage $session %}
    }
  }

  # It's an alarm being dispatched.

  elsif ($type & ET_ALARM) {
    {% collect_garbage $session %}
  }

  # It's a select being dispatched.
  elsif ($type & ET_SELECT) {
    {% collect_garbage $session %}
  }

  # Return what the state did.  This is used for call().
  $return;
}

#------------------------------------------------------------------------------
# POE's main loop!  Now with Tk and Event support!

sub run {
  my $self = shift;

  if (POE_USES_GTK) { # include
    # Use Gtk's main loop, if Gtk is loaded.
    Gtk->main;

  } elsif (POE_USES_TK) { # include
    # Use Tk's main loop, if Tk is loaded.
    Tk::MainLoop;

  } elsif (POE_USES_EVENT) { # include
    # Use Event's main loop, if Event is loaded.
    Event::loop();

  } elsif (POE_USES_ITSELF) { # include
    # Otherwise use POE's main loop.

    # Cache some references.  Adds about 15 events/second to a trivial
    # benchmark.  -><- It probably would be even faster if I flattened
    # POE::Kernel's data structure and made them all lexicals instead
    # of members of $self.
    my $kr_states   = $self->[KR_STATES];
    my $kr_handles  = $self->[KR_HANDLES];
    my $kr_sessions = $self->[KR_SESSIONS];
    my $kr_vectors  = $self->[KR_VECTORS];
    my $kr_alarms   = $self->[KR_ALARMS];

    # Continue running while there are sessions that need to be
    # serviced.

    while (keys %$kr_sessions) {

      # Check for a hung kernel.
      {% test_for_idle_poe_kernel %}

      # Set the select timeout based on current queue conditions.  If
      # there are FIFO events, then the timeout is zero to poll select
      # and move on.  Otherwise set the select timeout until the next
      # pending alarm, if any are in the alarm queue.  If no FIFO
      # events or alarms are pending, then time out after some
      # constant number of seconds.

      my $now = time();
      my $timeout;

      if (@$kr_states) {
        $timeout = 0;
      }
      elsif (@$kr_alarms) {
        $timeout = $kr_alarms->[0]->[ST_TIME] - $now;
        $timeout = 0 if $timeout < 0;
      }
      else {
        $timeout = 3600;
      }

      if (TRACE_QUEUE) { # include

        warn( '*** Kernel::run() iterating.  ' .
              sprintf("now(%.2f) timeout(%.2f) then(%.2f)\n",
                      $now-$^T, $timeout, ($now-$^T)+$timeout
                     )
            );
        warn( '*** Alarm times: ' .
              join( ', ',
                    map { sprintf('%d=%.2f',
                                  $_->[ST_SEQ], $_->[ST_TIME] - $now
                                 )
                        } @$kr_alarms
                  ) .
              "\n"
            );

      } # include

      if (TRACE_SELECT) { # include

        warn ",----- SELECT BITS IN -----\n";
        warn "| READ    : ", unpack('b*', $kr_vectors->[VEC_WR]), "\n";
        warn "| WRITE   : ", unpack('b*', $kr_vectors->[VEC_WR]), "\n";
        warn "| EXPEDITE: ", unpack('b*', $kr_vectors->[VEC_EX]), "\n";
        warn "`--------------------------\n";

      } # include

      # Avoid looking at filehandles if we don't need to.

      if ($timeout || keys(%$kr_handles)) {

        # Check filehandles, or wait for a period of time to elapse.
        my $hits = select( my $rout = $kr_vectors->[VEC_RD],
                           my $wout = $kr_vectors->[VEC_WR],
                           my $eout = $kr_vectors->[VEC_EX],
                           ($timeout < 0) ? 0 : $timeout
                         );

        if (ASSERT_SELECT) { # include

          if ($hits < 0) {
            confess "select error: $!"
              unless ( ($! == EINPROGRESS) or
                       ($! == EWOULDBLOCK) or
                       ($! == EINTR)
                     );
          }

        } # include

        if (TRACE_SELECT) { # include

          if ($hits > 0) {
            warn "select hits = $hits\n";
          }
          elsif ($hits == 0) {
            warn "select timed out...\n";
          }
          warn ",----- SELECT BITS OUT -----\n";
          warn "| READ    : ", unpack('b*', $rout), "\n";
          warn "| WRITE   : ", unpack('b*', $wout), "\n";
          warn "| EXPEDITE: ", unpack('b*', $eout), "\n";
          warn "`---------------------------\n";

        } # include

        # If select has seen filehandle activity, then gather up the
        # active filehandles and synchronously dispatch events to the
        # appropriate states.

        if ($hits > 0) {

          # This is where they're gathered.  It's a variant on a neat
          # hack Silmaril came up with.

          # -><- This does extra work.  Some of $%kr_handles don't have
          # all their bits set (for example; VEX_EX is rarely used).
          # It might be more efficient to split this into three greps,
          # for just the vectors that need to be checked.

          # -><- It has been noted that map is slower than foreach
          # when the size of a list is grown.  The list is exploded on
          # the stack and manipulated with stack ops, which are slower
          # than just pushing on a list.  Evil probably ensues here.

          my @selects =
            map { ( ( vec($rout, fileno($_->[HND_HANDLE]), 1)
                      ? values(%{$_->[HND_SESSIONS]->[VEC_RD]})
                      : ( )
                    ),
                    ( vec($wout, fileno($_->[HND_HANDLE]), 1)
                      ? values(%{$_->[HND_SESSIONS]->[VEC_WR]})
                      : ( )
                    ),
                    ( vec($eout, fileno($_->[HND_HANDLE]), 1)
                      ? values(%{$_->[HND_SESSIONS]->[VEC_EX]})
                      : ( )
                    )
                  )
                } values %$kr_handles;

          if (TRACE_SELECT) { # include

            if (@selects) {
              warn "found pending selects: @selects\n";
            }

          } # include

          if (ASSERT_SELECT) { # include

            unless (@selects) {
              die "found no selects, with $hits hits from select???\a\n";
            }

          } # include

          # Dispatch the gathered selects.  They're dispatched right
          # away because files will continue to unblock select until
          # they're taken care of.  The idea is for select handlers to
          # do whatever is needed to shut up select, and then they
          # post something indicating what input was got.  Nobody
          # seems to use them this way, though, not even the author.

          foreach my $select (@selects) {
            $self->_dispatch_state
              ( $select->[HSS_SESSION], $select->[HSS_SESSION],
                $select->[HSS_STATE], ET_SELECT,
                [ $select->[HSS_HANDLE] ],
                time(), __FILE__, __LINE__, undef
              );
          }
        }
      }

      # Dispatch whatever alarms are due.

      $now = time();
      while ( @$kr_alarms and ($kr_alarms->[0]->[ST_TIME] <= $now) ) {
        my $event;

        if (TRACE_QUEUE) { # include

          $event = $kr_alarms->[0];
          warn( sprintf('now(%.2f) ', $now - $^T) .
                sprintf('sched_time(%.2f)  ', $event->[ST_TIME] - $^T) .
                "seq($event->[ST_SEQ])  " .
                "name($event->[ST_NAME])\n"
              );

        } # include

        # Pull an alarm off the queue, and dispatch it.
        $event = shift @$kr_alarms;
        {% ses_refcount_dec2 $event->[ST_SESSION], SS_ALCOUNT %}
        $self->_dispatch_state(@$event);
      }

      # Dispatch one or more FIFOs, if they are available.  There is a
      # lot of latency between executions of this code block, so we'll
      # dispatch more than one event if we can.

      my $stop_time = time() + FIFO_DISPATCH_TIME;
      while (@$kr_states) {

        if (TRACE_QUEUE) { # include

          my $event = $kr_states->[0];
          warn( sprintf('now(%.2f) ', $now - $^T) .
                sprintf('sched_time(%.2f)  ', $event->[ST_TIME] - $^T) .
                "seq($event->[ST_SEQ])  " .
                "name($event->[ST_NAME])\n"
              );

        } # include

        # Pull an event off the queue, and dispatch it.
        my $event = shift @$kr_states;
        {% ses_refcount_dec2 $event->[ST_SESSION], SS_EVCOUNT %}
        $self->_dispatch_state(@$event);

        if (POE_USES_TIME_HIRES) { # include

          # Otherwise, dispatch more FIFO events until $stop_time is
          # reached.
          last unless time() < $stop_time;
          
        } else { # include
        
          # If Time::HiRes isn't available, then the fairest thing to do
          # is loop immediately.
          last;

        } # include

      }
    }

  } # include

  # The main loop is done, no matter which event library ran it.
  # Let's make sure POE isn't leaking things.

  if (ASSERT_GARBAGE) { # include

    {% kernel_leak_vec VEC_RD %}
    {% kernel_leak_vec VEC_WR %}
    {% kernel_leak_vec VEC_EX %}

    {% kernel_leak_hash KR_PROCESSES   %}
    {% kernel_leak_hash KR_SESSION_IDS %}
    {% kernel_leak_hash KR_HANDLES     %}
    {% kernel_leak_hash KR_SESSIONS    %}
    {% kernel_leak_hash KR_ALIASES     %}

    {% kernel_leak_array KR_ALARMS %}
    {% kernel_leak_array KR_STATES %}

  } # include

  if (TRACE_PROFILE) { # include

    print STDERR ',----- State Profile ' , ('-' x 53), ",\n";
    foreach (sort keys %profile) {
      printf STDERR "| %60.60ss %10d |\n", $_, $profile{$_};
    }
    print STDERR '`', ('-' x 73), "'\n";

  } # include
}

#------------------------------------------------------------------------------
# Gtk support.

# Gtk idle callback to dispatch FIFO states.  This steals a big chunk
# of code from POE::Kernel::run().  Make this function's guts a macro
# later, and use it wherever possible.

sub _gtk_fifo_callback {
  my $self = $poe_kernel;

  {% dispatch_one_from_fifo %}
  {% test_for_idle_poe_kernel %}

  # Perpetuate the Gtk idle callback if there's more to do.
  return 1 if @{$self->[KR_STATES]};

  # Otherwise stop it.
  $self->[KR_WATCHER_IDLE] = undef;
  return 0;
}

# Gtk timeout callback to dispatch pending alarm states.  Same caveats
# about macro-izing this code.

sub _gtk_timeout_callback {
  my $self = $poe_kernel;

  {% dispatch_due_alarms %}
  {% test_for_idle_poe_kernel %}

  Gtk->timeout_remove( $self->[KR_WATCHER_TIMER] );
  $self->[KR_WATCHER_TIMER] = undef;

  # Register the next timeout if there are alarms left.
  if (@{$self->[KR_ALARMS]}) {
    my $next_time = ($self->[KR_ALARMS]->[0]->[ST_TIME] - time()) * 1000;
    $next_time = 0 if $next_time < 0;
    $self->[KR_WATCHER_TIMER] =
      Gtk->timeout_add( $next_time, \&_gtk_timeout_callback );
  }

  # Return false to stop.
  return 0;
}

# Gtk filehandle callback to dispatch selects.

sub _gtk_select_read_callback {
  my $self = $poe_kernel;
  my ($handle, $fileno, $hash) = @_;
  my $vector = VEC_RD;

  # Dispatch a FIFO event.  We do this here because input_add
  # callbacks and idle callbacks seem to take pretty large turns.
  # This way we're at least distpatching FIFO events all the time.
  #{% dispatch_one_from_fifo %}

  {% dispatch_ready_selects %}
  {% test_for_idle_poe_kernel %}

  # Return false to stop... probably not with this one.
  return 0;
}

sub _gtk_select_write_callback {
  my $self = $poe_kernel;
  my ($handle, $fileno, $hash) = @_;
  my $vector = VEC_WR;

  # Dispatch a FIFO event.  We do this here because input_add
  # callbacks and idle callbacks seem to take pretty large turns.
  # This way we're at least distpatching FIFO events all the time.
  #{% dispatch_one_from_fifo %}

  {% dispatch_ready_selects %}
  {% test_for_idle_poe_kernel %}

  # Return false to stop... probably not with this one.
  return 0;
}

sub _gtk_select_expedite_callback {
  my $self = $poe_kernel;
  my ($handle, $fileno, $hash) = @_;
  my $vector = VEC_EX;

  # Dispatch a FIFO event.  We do this here because input_add
  # callbacks and idle callbacks seem to take pretty large turns.
  # This way we're at least distpatching FIFO events all the time.
  #{% dispatch_one_from_fifo %}

  {% dispatch_ready_selects %}
  {% test_for_idle_poe_kernel %}

  # Return false to stop... probably not with this one.
  return 0;
}

#------------------------------------------------------------------------------
# Tk support.  Tk's alarm callbacks seem to have the highest priority.
# That is, if $widget->after is constantly scheduled for a period
# smaller than the overhead of dispatching it, then no other events
# are processed.  That includes afterIdle and even internal Tk events.

# Tk idle callback to dispatch FIFO states.  This steals a big chunk
# of code from POE::Kernel::run().  Make this function's guts a macro
# later, and use it in both places.

sub _tk_fifo_callback {
  my $self = $poe_kernel;

  {% dispatch_one_from_fifo %}

  # Perpetuate the dispatch loop as long as there are states enqueued.

  if (defined $self->[KR_WATCHER_IDLE]) {
    $self->[KR_WATCHER_IDLE]->cancel();
    $self->[KR_WATCHER_IDLE] = undef;
  }

  # This nasty little hack is required because setting an afterIdle
  # from a running afterIdle effectively blocks OS/2 Presentation
  # Manager events.  This locks up its notion of a window manager.  I
  # couldn't get anyone to test it on other platforms... (Hey, this could
  # trash yoru desktop! Wanna try it?) :)

  if (@{$self->[KR_STATES]}) {
    $poe_main_window->after
      ( 0,
        sub {
          $self->[KR_WATCHER_IDLE] =
            $poe_main_window->afterIdle( \&_tk_fifo_callback )
          unless defined $self->[KR_WATCHER_IDLE];
        }
      );
  }

  # Make sure the kernel can still run.
  else {
    {% test_for_idle_poe_kernel %}
  }
}

# Tk timer callback to dispatch alarm states.  Same caveats about
# macro-izing this code.

sub _tk_alarm_callback {
  my $self = $poe_kernel;

  {% dispatch_due_alarms %}

  # As was mentioned before, $widget->after() events can dominate a
  # program's event loop, starving it of other events, including Tk's
  # internal widget events.  To avoid this, we'll reset the alarm
  # callback from an idle event.

  # Register the next timed callback if there are alarms left.

  if (@{$self->[KR_ALARMS]}) {

    # Cancel the Tk alarm that handles alarms.

    if (defined $self->[KR_WATCHER_TIMER]) {
      $self->[KR_WATCHER_TIMER]->cancel();
      $self->[KR_WATCHER_TIMER] = undef;
    }

    # Replace it with an idle event that will reset the alarm.

    $self->[KR_WATCHER_TIMER] =
      $poe_main_window->afterIdle
        ( sub {
            $self->[KR_WATCHER_TIMER]->cancel();
            $self->[KR_WATCHER_TIMER] = undef;

            if (@{$self->[KR_ALARMS]}) {
              my $next_time = $self->[KR_ALARMS]->[0]->[ST_TIME] - time();
              $next_time = 0 if $next_time < 0;

              $self->[KR_WATCHER_TIMER] =
                $poe_main_window->after( $next_time * 1000,
                                            \&_tk_alarm_callback
                                          );
            }
          }
        );
  }

  # Make sure the kernel can still run.
  else {
    {% test_for_idle_poe_kernel %}
  }
}

# Tk filehandle callback to dispatch selects.

sub _tk_select_callback {
  my $self = $poe_kernel;
  my ($handle, $vector) = @_;

  {% dispatch_ready_selects %}
  {% test_for_idle_poe_kernel %}
}

#------------------------------------------------------------------------------
# Event support.

# Event idle callback to dispatch FIFO states.  This steals a big
# chunk of code from POE::Kernel::run().  Make this functions guts a
# macro later, and use it here, in POE::Kernel::run() and other FIFO
# callbacks.

sub _event_fifo_callback {
  my $self = $poe_kernel;

  {% dispatch_one_from_fifo %}

  # Stop the idle watcher if there are no more state transitions in
  # the Kernel's FIFO.

  unless (@{$self->[KR_STATES]}) {
    $self->[KR_WATCHER_IDLE]->stop();

    # Make sure the kernel can still run.
    {% test_for_idle_poe_kernel %}
  }
}

# Event timer callback to dispatch alarm states.  Same caveats about
# macro-izing this code.

sub _event_alarm_callback {
  my $self = $poe_kernel;

  {% dispatch_due_alarms %}

  # Register the next timed callback if there are alarms left.

  if (@{$self->[KR_ALARMS]}) {
    $self->[KR_WATCHER_TIMER]->at( $self->[KR_ALARMS]->[0]->[ST_TIME] );
    $self->[KR_WATCHER_TIMER]->start();
  }

  # Make sure the kernel can still run.
  else {
    {% test_for_idle_poe_kernel %}
  }
}

# Event filehandle callback to dispatch selects.

sub _event_select_callback {
  my $self = $poe_kernel;

  my $event = shift;
  my $watcher = $event->w;
  my $handle = $watcher->fd;
  my $vector = ( ( $event->got eq 'r' )
                 ? VEC_RD
                 : ( ( $event->got eq 'w' )
                     ? VEC_WR
                     : ( ( $event->got eq 'e' )
                         ? VEC_EX
                         : return
                       )
                   )
               );

  {% dispatch_ready_selects %}
  {% test_for_idle_poe_kernel %}
}

#------------------------------------------------------------------------------

sub DESTROY {
  # Destroy all sessions.  This will cascade destruction to all
  # resources.  It's taken care of by Perl's own garbage collection.
  # For completeness, I suppose a copy of POE::Kernel->run's leak
  # detection could be included here.
}

#------------------------------------------------------------------------------
# _invoke_state is what _dispatch_state calls to dispatch a transition
# event.  This is the kernel's _invoke_state so it can receive events.
# These are mostly signals, which are propagated down in
# _dispatch_state.

sub _invoke_state {
  my ($self, $source_session, $state, $etc) = @_;

  # A SIGCHLD was caught.  This is an event loop to poll for children
  # without catching extra child signals.  This reduces the number of
  # CHLD signals caught, which increases the process' chance for
  # survival.

  if ($state eq EN_SCPOLL) {

    # Non-blocking wait for a child process.  If one was reaped,
    # dispatch a SIGCHLD to the session who called fork.

    my $pid = waitpid(-1, WNOHANG);

    # A child stopped, or something.

    if ($pid > 0) {

      # Determine if the child process is really exiting and not just
      # stopping for some other reason.  This is perl Perl Cookbook
      # recipe 16.19 and the waitpid(2) manpage.

      if (WIFEXITED($?) or WIFSIGNALED($?)) {

        # Map the process ID to a session reference.  First look for a
        # session registered via $kernel->fork().  Next validate the
        # session or signal everyone.

        my $parent_session = delete $self->[KR_PROCESSES]->{$pid};
        $parent_session = $self
          unless ( (defined $parent_session) and
                   exists $self->[KR_SESSIONS]->{$parent_session}
                 );

        # Enqueue the signal event. -><- No way to determine whether
        # the child left via exit or a signal. Add another parameter?

        $self->_enqueue_state( $parent_session, $self,
                               EN_SIGNAL, ET_SIGNAL,
                               [ 'CHLD', $pid, $? ],
                               time(), __FILE__, __LINE__
                             );
      }

      # Enqueue an immediate subsequent wait in case another child
      # process is waiting.

      $self->_enqueue_state( $poe_kernel, $poe_kernel,
                             EN_SCPOLL, ET_SCPOLL,
                             [ ],
                             time(), __FILE__, __LINE__
                           );

    }

    # An error occurred.

    elsif ($pid == -1) {

      # waitpid(2) was interrupted.  Retry immediately.

      if ($! == EINTR) {
        $self->_enqueue_state( $poe_kernel, $poe_kernel,
                               EN_SCPOLL, ET_SCPOLL,
                               [ ],
                               time(), __FILE__, __LINE__
                             );
      }

      # Some other error occurred.  Assume we're stopping the wait
      # loop.  Warn if it's something unexpected.

      else {
        unless (POE_USES_EVENT) { # include
          $SIG{CHLD} = \&_poe_signal_handler_child if exists $SIG{CHLD};
          $SIG{CLD}  = \&_poe_signal_handler_child if exists $SIG{CLD};
        } # include

        warn $! if $! and $! != ECHILD;
      }
    }

    # Nothing is left to wait for.  Stop the wait loop.

    else {
      unless (POE_USES_EVENT) { # include
        $SIG{CHLD} = \&_poe_signal_handler_child if exists $SIG{CHLD};
        $SIG{CLD}  = \&_poe_signal_handler_child if exists $SIG{CLD};
      } # include
    }
  }

  # A signal was posted.  Because signals propagate depth-first, this
  # _invoke_state is called last in the dispatch.  If the signal was
  # SIGIDLE, then post a SIGZOMBIE if the main queue is still idle.

  elsif ($state eq EN_SIGNAL) {
    if ($etc->[0] eq 'IDLE') {
      unless (@{$self->[KR_STATES]} || keys(%{$self->[KR_HANDLES]})) {
        $self->_enqueue_state( $self, $self,
                               EN_SIGNAL, ET_SIGNAL,
                               [ 'ZOMBIE' ],
                               time(), __FILE__, __LINE__
                             );
      }
    }
  }

  return 1;
}

#==============================================================================
# SESSIONS
#==============================================================================

# Dispatch _start to a session, allocating it in the kernel's data
# structures as a side effect.

sub session_alloc {
  my ($self, $session, @args) = @_;
  my $kr_active_session = $self->[KR_ACTIVE_SESSION];

  if (ASSERT_RELATIONS) { # include
    die {% ssid %}, " already exists\a"
      if (exists $self->[KR_SESSIONS]->{$session});
  } # include

  $self->_dispatch_state( $session, $kr_active_session,
                          EN_START, ET_START,
                          \@args,
                          time(), __FILE__, __LINE__, undef
                        );
  $self->_enqueue_state( $session, $kr_active_session,
                         EN_GC, ET_GC,
                         [],
                         time(), __FILE__, __LINE__
                       );
}

# Dispatch _stop to a session, removing it from the kernel's data
# structures as a side effect.

sub session_free {
  my ($self, $session) = @_;

  if (ASSERT_RELATIONS) { # include
    die {% ssid %}, " doesn't exist\a"
      unless (exists $self->[KR_SESSIONS]->{$session});
  } # include

  $self->_dispatch_state( $session, $self->[KR_ACTIVE_SESSION],
                          EN_STOP, ET_STOP,
                          [],
                          time(), __FILE__, __LINE__, undef
                        );
}

# Debugging subs for reference count checks.

sub trace_gc_refcount {
  my ($self, $session) = @_;

  my ($package, $file, $line) = caller;
  warn "tracing gc refcount from $file at $line\n";

  my $ss = $self->[KR_SESSIONS]->{$session};
  warn "+----- GC test for ", {% ssid %}, " ($session) -----\n";
  warn "| total refcnt  : $ss->[SS_REFCOUNT]\n";
  warn "| event count   : $ss->[SS_EVCOUNT]\n";
  warn "| alarm count   : $ss->[SS_ALCOUNT]\n";
  warn "| child sessions: ", scalar(keys(%{$ss->[SS_CHILDREN]})), "\n";
  warn "| handles in use: ", scalar(keys(%{$ss->[SS_HANDLES]})), "\n";
  warn "| aliases in use: ", scalar(keys(%{$ss->[SS_ALIASES]})), "\n";
  warn "| extra refs    : ", scalar(keys(%{$ss->[SS_EXTRA_REFS]})), "\n";
  warn "+---------------------------------------------------\n";
  warn " ...";
  unless ($ss->[SS_REFCOUNT]) {
    warn "| ", {% ssid %}, " is garbage; recycling it...\n";
    warn "+---------------------------------------------------\n";
    warn " ...";
  }
}

sub assert_gc_refcount {
  my ($self, $session) = @_;
  my $ss = $self->[KR_SESSIONS]->{$session};

  # Calculate the total reference count based on the number of
  # discrete references kept.

  my $calc_ref =
    ( $ss->[SS_EVCOUNT] +
      $ss->[SS_ALCOUNT] +
      scalar(keys(%{$ss->[SS_CHILDREN]})) +
      scalar(keys(%{$ss->[SS_HANDLES]})) +
      scalar(keys(%{$ss->[SS_EXTRA_REFS]})) +
      scalar(keys(%{$ss->[SS_ALIASES]}))
    );

  # The calculated reference count really ought to match the one POE's
  # been keeping track of all along.

  die {% ssid %}, " has a reference count inconsistency\n"
    if $calc_ref != $ss->[SS_REFCOUNT];

  # Compare held handles against reference counts for them.

  foreach (values %{$ss->[SS_HANDLES]}) {
    $calc_ref = $_->[SH_VECCOUNT]->[VEC_RD] +
      $_->[SH_VECCOUNT]->[VEC_WR] + $_->[SH_VECCOUNT]->[VEC_EX];

    die {% ssid %}, " has a handle reference count inconsistency\n"
      if $calc_ref != $_->[SH_REFCOUNT];
  }
}

sub get_active_session {
  my $self = shift;
  return $self->[KR_ACTIVE_SESSION];
}

#==============================================================================
# EVENTS
#==============================================================================

my $queue_seqnum = 0;

# Internal function to enqueue a state transition event.

sub _enqueue_state {
  my ( $self, $session, $source_session, $state, $type, $etc, $time,
       $file, $line
     ) = @_;

  if (TRACE_EVENTS) { # include
    warn "}}} enqueuing state '$state' for ", {% ssid %}, "\n";
  } # include

  # These things are FIFO; just enqueue it.

  if (exists $self->[KR_SESSIONS]->{$session}) {

    push @{$self->[KR_STATES]}, {% state_to_enqueue %};
    {% ses_refcount_inc2 $session, SS_EVCOUNT %}

    if (POE_USES_GTK) { # include

      # If using Gtk and the FIFO queue now has only one event, then
      # register a Gtk idle callback to resume the dispatch loop.
      unless (defined $self->[KR_WATCHER_IDLE]) {
        $self->[KR_WATCHER_IDLE] =
          Gtk->idle_add(\&_gtk_fifo_callback);
      }

    } elsif (POE_USES_TK) { # include

      # If using Tk and the FIFO queue now has only one event, then
      # register a Tk idle callback to resume the dispatch loop.
      $self->[KR_WATCHER_IDLE] =
        $poe_main_window->afterIdle( \&_tk_fifo_callback );

    } elsif (POE_USES_EVENT) { # include

      # If using Event and the FIFO queue now has only one event, then
      # start the Event idle watcher to resume the dispatch loop.
      $self->[KR_WATCHER_IDLE]->again();

    } # include

  }
  else {
    warn ">>>>> ", join('; ', keys(%{$self->[KR_SESSIONS]})), " <<<<<\n";
    croak "can't enqueue state($state) for nonexistent session($session)\a\n";
  }
}

sub _enqueue_alarm {
  my ( $self, $session, $source_session, $state, $type, $etc, $time,
       $file, $line
     ) = @_;

  if (TRACE_EVENTS) { # include
    warn "}}} enqueuing alarm '$state' for ", {% ssid %}, "\n";
  } # include

  if (exists $self->[KR_SESSIONS]->{$session}) {
    my $kr_alarms = $self->[KR_ALARMS];

    # Special case: No alarms in the queue.  Put the new alarm in the
    # queue, and be done with it.
    unless (@$kr_alarms) {
      $kr_alarms->[0] = {% state_to_enqueue %};
    }

    # Special case: New state belongs at the end of the queue.  Push
    # it, and be done with it.
    elsif ($time >= $kr_alarms->[-1]->[ST_TIME]) {
      push @$kr_alarms, {% state_to_enqueue %};
    }

    # Special case: New state comes before earliest state.  Unshift
    # it, and be done with it.
    elsif ($time < $kr_alarms->[0]->[ST_TIME]) {
      unshift @$kr_alarms, {% state_to_enqueue %};
    }

    # Special case: Two alarms in the queue.  The new state enters
    # between them, because it's not before the first one or after the
    # last one.
    elsif (@$kr_alarms == 2) {
      splice @$kr_alarms, 1, 0, {% state_to_enqueue %};
    }

    # Small queue.  Perform a reverse linear search on the assumption
    # that (a) a linear search is fast enough on small queues; and (b)
    # most events will be posted for "now" or some future time, which
    # tends to be towards the end of the queue.
    elsif (@$kr_alarms < 32) {
      my $index = @$kr_alarms;
      while ($index--) {
        if ($time >= $kr_alarms->[$index]->[ST_TIME]) {
          splice @$kr_alarms, $index+1, 0, {% state_to_enqueue %};
          last;
        }
        elsif ($index == 0) {
          unshift @$kr_alarms, {% state_to_enqueue %};
        }
      }
    }

    # And finally, we have this large queue, and the program has
    # already wasted enough time.  -><- It would be neat for POE to
    # determine the break-even point between "large" and "small" alarm
    # queues at start-up and tune itself accordingly.
    else {
      my $upper = @$kr_alarms - 1;
      my $lower = 0;
      while ('true') {
        my $midpoint = ($upper + $lower) >> 1;

        # Upper and lower bounds crossed.  No match; insert at the
        # lower bound point.
        if ($upper < $lower) {
          splice @$kr_alarms, $lower, 0, {% state_to_enqueue %};
          last;
        }

        # The key at the midpoint is too high.  The element just below
        # the midpoint becomes the new upper bound.
        if ($time < $kr_alarms->[$midpoint]->[ST_TIME]) {
          $upper = $midpoint - 1;
          next;
        }

        # The key at the midpoint is too low.  The element just above
        # the midpoint becomes the new lower bound.
        if ($time > $kr_alarms->[$midpoint]->[ST_TIME]) {
          $lower = $midpoint + 1;
          next;
        }

        # The key matches the one at the midpoint.  Scan towards
        # higher keys until the midpoint points to an element with a
        # higher key.  Insert the new state before it.
        $midpoint++
          while ( ($midpoint < @$kr_alarms) 
                  and ($time == $kr_alarms->[$midpoint]->[ST_TIME])
                );
        splice @$kr_alarms, $midpoint, 0, {% state_to_enqueue %};
        last;
      }
    }

    if (POE_USES_GTK) { # include

      # If using Gtk and the alarm queue now has only one event, then
      # register a timeout callback to dispatch it when it becomes
      # due.
      if ( @{$self->[KR_ALARMS]} == 1 ) {
        my $next_time = ($self->[KR_ALARMS]->[0]->[ST_TIME] - time()) * 1000;
        $next_time = 0 if $next_time < 0;
        $self->[KR_WATCHER_TIMER] =
          Gtk->timeout_add( $next_time, \&_gtk_timeout_callback );
      }

    } elsif (POE_USES_TK) { # include

      # If using Tk and the alarm queue now has only one event, then
      # register a Tk timed callback to dispatch it when it becomes
      # due.
      if ( @{$self->[KR_ALARMS]} == 1 ) {
        if (defined $self->[KR_WATCHER_TIMER]) {
          $self->[KR_WATCHER_TIMER]->cancel();
          $self->[KR_WATCHER_TIMER] = undef;
        }

        my $next_time = $self->[KR_ALARMS]->[0]->[ST_TIME] - time();
        $next_time = 0 if $next_time < 0;
        $self->[KR_WATCHER_TIMER] =
          $poe_main_window->after( $next_time * 1000,
                                   \&_tk_alarm_callback
                                 );
      }

    } elsif (POE_USES_EVENT) { # include

      # If using Event and the alarm queue now has only one event,
      # then start the Event timer to dispatch it when it becomes due.
      if ( @{$self->[KR_ALARMS]} == 1 ) {
        $self->[KR_WATCHER_TIMER]->at( $self->[KR_ALARMS]->[0]->[ST_TIME] );
        $self->[KR_WATCHER_TIMER]->start();
      }

    } # include

    # Manage reference counts.
    {% ses_refcount_inc2 $session, SS_ALCOUNT %}
  }
  else {
    warn ">>>>> ", join('; ', keys(%{$self->[KR_SESSIONS]})), " <<<<<\n";
    croak "can't enqueue alarm($state) for nonexistent session($session)\a\n";
  }
}

#------------------------------------------------------------------------------
# Post a state to the queue.

sub post {
  my ($self, $destination, $state_name, @etc) = @_;

  # Attempt to resolve the destination session reference against
  # various things.

  my $session = {% alias_resolve $destination %};
  {% test_resolve $destination, $session %}

  # Enqueue the state for "now", which simulates FIFO in our
  # time-ordered queue.

  $self->_enqueue_state( $session, $self->[KR_ACTIVE_SESSION],
                         $state_name, ET_USER,
                         \@etc,
                         time(), (caller)[1,2]
                       );
  return 1;
}

#------------------------------------------------------------------------------
# Post a state to the queue for the current session.

sub yield {
  my ($self, $state_name, @etc) = @_;

  my $kr_active_session = $self->[KR_ACTIVE_SESSION];
  $self->_enqueue_state( $kr_active_session, $kr_active_session,
                         $state_name, ET_USER,
                         \@etc,
                         time(), (caller)[1,2]
                       );

  undef;
}

#------------------------------------------------------------------------------
# Call a state directly.

sub call {
  my ($self, $destination, $state_name, @etc) = @_;

  # Attempt to resolve the destination session reference against
  # various things.

  my $session = {% alias_resolve $destination %};
  {% test_resolve $destination, $session %}

  # Dispatch the state right now, bypassing the queue altogether.
  # This tends to be a Bad Thing to Do, but it's useful for
  # synchronous events like selects'.

  # -><- The difference between synchronous and asynchronous events
  # should be made more clear in the documentation, so that people
  # have a tendency not to abuse them.  I discovered in xws that that
  # mixing the two types makes it harder than necessary to write
  # deterministic programs, but the difficulty can be ameliorated if
  # programmers set some base rules and stick to them.

  my $return_value =
    $self->_dispatch_state( $session, $self->[KR_ACTIVE_SESSION],
                            $state_name, ET_CALL,
                            \@etc,
                            time(), (caller)[1,2], undef
                          );
  $! = 0;
  return $return_value;
}

#------------------------------------------------------------------------------
# Peek at pending alarms.  Returns a list of pending alarms.

sub queue_peek_alarms {
  my ($self) = @_;
  my @pending_alarms;

  my $kr_active_session = $self->[KR_ACTIVE_SESSION];
  my $alarm_count = $self->[KR_SESSIONS]->{$kr_active_session}->[SS_ALCOUNT];

  foreach my $alarm (@{$self->[KR_ALARMS]}) {
    last unless $alarm_count;
    next unless $alarm->[ST_SESSION] == $kr_active_session;
    next unless $alarm->[ST_TYPE] & ET_ALARM;
    push @pending_alarms, $alarm->[ST_NAME];
    $alarm_count--;
  }

  @pending_alarms;
}

#==============================================================================
# DELAYED EVENTS
#==============================================================================

sub alarm {
  my ($self, $state, $time, @etc) = @_;
  my $kr_active_session = $self->[KR_ACTIVE_SESSION];

  return EINVAL unless defined $state;

  # Remove all previous instances of the alarm.
  my $index = scalar(@{$self->[KR_ALARMS]});
  while ($index--) {
    if ( ($self->[KR_ALARMS]->[$index]->[ST_TYPE] & ET_ALARM) &&
         ($self->[KR_ALARMS]->[$index]->[ST_SESSION] == $kr_active_session) &&
         ($self->[KR_ALARMS]->[$index]->[ST_NAME] eq $state)
    ) {
      {% ses_refcount_dec2 $kr_active_session, SS_ALCOUNT %}
      splice(@{$self->[KR_ALARMS]}, $index, 1);
    }
  }

  if (POE_USES_GTK) { # include

    # If using Gtk and the alarm queue is empty, then discard the Gtk
    # alarm callback.
    if ( @{$self->[KR_ALARMS]} == 0 ) {
      # -><- Remove the alarm handler.  Is this necessary?
    }

  } elsif (POE_USES_TK) { # include

    # If using Tk and the alarm queue is empty, then discard the Tk
    # alarm callback.
    if ( @{$self->[KR_ALARMS]} == 0 ) {
      # -><- Remove the alarm handler.  Is this necessary?
    }

  } elsif (POE_USES_EVENT) { # include

    # If using Event and the alarm queue is empty, then ensure that
    # the timer has stopped.

    if ( @{$self->[KR_ALARMS]} == 0 ) {
      $self->[KR_WATCHER_TIMER]->stop();
    }

  } # include

  # Add the new alarm if it includes a time.
  if (defined $time) {
    $self->_enqueue_alarm( $kr_active_session, $kr_active_session,
                           $state, ET_ALARM,
                           [ @etc ],
                           $time, (caller)[1,2]
                         );
  }

  return 0;
}

# Add an alarm without clobbering previous alarms of the same name.
sub alarm_add {
  my ($self, $state, $time, @etc) = @_;

  return EINVAL unless defined $state and defined $time;

  my $kr_active_session = $self->[KR_ACTIVE_SESSION];
  $self->_enqueue_alarm( $kr_active_session, $kr_active_session,
                         $state, ET_ALARM,
                         [ @etc ],
                         $time, (caller)[1,2]
                       );

  return 0;
}

# Add a delay, which is just an alarm relative to the current time.
sub delay {
  my ($self, $state, $delay, @etc) = @_;

  return EINVAL unless defined $state;

  if (defined $delay) {
    $self->alarm($state, time() + $delay, @etc);
  }
  else {
    $self->alarm($state);
  }

  return 0;
}

# Add a delay without clobbering previous delays of the same name.
sub delay_add {
  my ($self, $state, $delay, @etc) = @_;

  return EINVAL unless defined $state and defined $delay;

  $self->alarm_add($state, time() + $delay, @etc);

  return 0;
}

#==============================================================================
# SELECTS
#==============================================================================

sub _internal_select {
  my ($self, $session, $handle, $state, $select_index) = @_;
  my $kr_handles = $self->[KR_HANDLES];
  my $fileno = fileno($handle);

  # Register a select state.
  if ($state) {
    unless (exists $kr_handles->{$handle}) {
      $kr_handles->{$handle} =
        [ $handle,                      # HND_HANDLE
          0,                            # HND_REFCOUNT
          [ 0, 0, 0 ],                  # HND_VECCOUNT (VEC_RD, VEC_WR, VEC_EX)
          [ { }, { }, { } ],            # HND_SESSIONS (VEC_RD, VEC_WR, VEC_EX)
        ];

      # For DOSISH systems like OS/2
      binmode($handle);

      # Make the handle stop blocking, the Windows way.
      if ($^O eq 'MSWin32') {
        my $set_it = "1";

        # 126 is FIONBIO (some docs say 0x7F << 16)
        ioctl( $handle,
               0x80000000 | (4 << 16) | (ord('f') << 8) | 126,
               $set_it
             ) or die "Can't set the handle non-blocking: $!";
      }

      # Make the handle stop blocking, the POSIX way.
      else {
        my $flags = fcntl($handle, F_GETFL, 0)
          or croak "fcntl fails with F_GETFL: $!\n";
        $flags = fcntl($handle, F_SETFL, $flags | O_NONBLOCK)
          or croak "fcntl fails with F_SETFL: $!\n";
      }

      # This depends heavily on socket.ph, or somesuch.  It's
      # extremely unportable.  I can't begin to figure out a way to
      # make this work everywhere, so I'm not even going to try.
      #
      # setsockopt($handle, SOL_SOCKET, &TCP_NODELAY, 1)
      #   or die "Couldn't disable Nagle's algorithm: $!\a\n";

      # Turn off buffering.
      select((select($handle), $| = 1)[0]);
    }

    # KR_HANDLES
    my $kr_handle = $kr_handles->{$handle};

    # If this session hasn't already been watching the filehandle,
    # then modify the handle's reference counts and perhaps turn on
    # the appropriate select bit.

    unless (exists $kr_handle->[HND_SESSIONS]->[$select_index]->{$session}) {

      # Increment the handle's vector (Read, Write or Expedite)
      # reference count.  This helps the kernel know when to manage
      # the handle's corresponding vector bit.

      $kr_handle->[HND_VECCOUNT]->[$select_index]++;

      # If this is the first session to watch the handle, then turn
      # its select bit on.

      if ($kr_handle->[HND_VECCOUNT]->[$select_index] == 1) {
        vec($self->[KR_VECTORS]->[$select_index], fileno($handle), 1) = 1;

        if (POE_USES_GTK) { # include

          # If we're using Gtk, then we tell it to watch this
          # filehandle for us.  This is in lieu of our own select
          # code.

          # Overwriting a pre-existing watcher?
          if (defined $kr_handle->[HND_WATCHERS]->[$select_index]) {
            Gtk::Gdk->input_remove
              ( $kr_handle->[HND_WATCHERS]->[$select_index] );
            $kr_handle->[HND_WATCHERS]->[$select_index] = undef;
          }

          # Register the new watcher.
          if ($select_index == VEC_RD) {
            $kr_handle->[HND_WATCHERS]->[VEC_RD] =
              Gtk::Gdk->input_add( fileno($handle), 'read',
                                   \&_gtk_select_read_callback, $handle
                                 );
          }
          elsif ($select_index == VEC_WR) {
            $kr_handle->[HND_WATCHERS]->[VEC_WR] =
              Gtk::Gdk->input_add( fileno($handle), 'write',
                                   \&_gtk_select_write_callback, $handle
                                 );
          }
          else {
            $kr_handle->[HND_WATCHERS]->[VEC_EX] =
              Gtk::Gdk->input_add( fileno($handle), 'exception',
                                   \&_gtk_select_expedite_callback, $handle
                                 );
          }

        } elsif (POE_USES_TK) { # include

          # If we're using Tk, then we tell it to watch this
          # filehandle for us.  This is in lieu of our own select
          # code.

          # The Tk documentation implies by omission that expedited
          # filehandles aren't, uh, handled.  This is part 1 of 2.

          confess "Tk does not support expedited filehandles"
            if $select_index == VEC_EX;

          $poe_main_window->fileevent
            ( $handle,

              # It can only be VEC_RD or VEC_WR here (VEC_EX is
              # checked a few lines up).
              ( ( $select_index == VEC_RD ) ? 'readable' : 'writable' ),

              [ \&_tk_select_callback, $handle, $select_index ],
            );

        } elsif (POE_USES_EVENT) { # include

          # If we're using Event, then we tell it to watch this
          # filehandle for us.  This is in lieu of our own select
          # code.

          $kr_handle->[HND_WATCHERS]->[$select_index] =
            Event->io
              ( fd => $handle,
                poll => ( ( $select_index == VEC_RD )
                          ? 'r'
                          : ( ( $select_index == VEC_WR )
                              ? 'w'
                              : 'e'
                            )
                        ),
                cb => \&_event_select_callback,
              );

        } # include
      }

      # Increment the handle's overall reference count (which is the
      # sum of its read, write and expedite counts but kept separate
      # for faster runtime checking).

      $kr_handle->[HND_REFCOUNT]++;
    }

    # Record the session parameters in the kernel's handle structure,
    # so we know what to do when the watcher unblocks.  This
    # overwrites a previous value, if any, or adds a new one.

    $kr_handle->[HND_SESSIONS]->[$select_index]->{$session} =
      [ $handle, $session, $state ];

    # SS_HANDLES
    my $kr_session = $self->[KR_SESSIONS]->{$session};

    # If the session hasn't already been watching the filehandle, then
    # register the filehandle in the session's structure.

    unless (exists $kr_session->[SS_HANDLES]->{$handle}) {
      $kr_session->[SS_HANDLES]->{$handle} = [ $handle, 0, [ 0, 0, 0 ] ];
      {% ses_refcount_inc $session %}
    }

    # Modify the session's handle structure's reference counts, so the
    # session knows it has a reason to live.

    my $ss_handle = $kr_session->[SS_HANDLES]->{$handle};
    unless ($ss_handle->[SH_VECCOUNT]->[$select_index]) {
      $ss_handle->[SH_VECCOUNT]->[$select_index]++;
      $ss_handle->[SH_REFCOUNT]++;
    }
  }

  # Remove a select from the kernel, and possibly trigger the
  # session's destruction.

  else {
    # KR_HANDLES

    # Make sure the handle is deregistered with the kernel.

    if (exists $kr_handles->{$handle}) {
      my $kr_handle = $kr_handles->{$handle};

      # Make sure the handle was registered to the requested session.

      if (exists $kr_handle->[HND_SESSIONS]->[$select_index]->{$session}) {

        # Remove the handle from the kernel's session record.

        delete $kr_handle->[HND_SESSIONS]->[$select_index]->{$session};

        # Decrement the handle's reference count.

        $kr_handle->[HND_VECCOUNT]->[$select_index]--;

        if (ASSERT_REFCOUNT) { # include
          die if ($kr_handle->[HND_VECCOUNT]->[$select_index] < 0);
        } # include

        # If the "vector" count drops to zero, then stop selecting the
        # handle.

        unless ($kr_handle->[HND_VECCOUNT]->[$select_index]) {
          vec($self->[KR_VECTORS]->[$select_index], fileno($handle), 1) = 0;

          if (POE_USES_GTK) { # include

            # If we're using Gtk, then we tell it to stop watching
            # this filehandle for us.  This is in lieu of our own
            # select code.

            # Don't bother removing a select if none was registered.
            if (defined $kr_handle->[HND_WATCHERS]->[$select_index]) {
              Gtk::Gdk->input_remove
                ( $kr_handle->[HND_WATCHERS]->[$select_index] );
              $kr_handle->[HND_WATCHERS]->[$select_index] = undef;
            }

          } elsif (POE_USES_TK) { # include

            # If we're using Tk, then we tell it to stop watching this
            # filehandle for us.  This is is lieu of our own select
            # code.

            # The Tk documentation implies by omission that expedited
            # filehandles aren't, uh, handled.  This is part 2 of 2.

            confess "Tk does not support expedited filehandles"
              if $select_index == VEC_EX;

            $poe_main_window->fileevent
              ( $handle,

                # It can only be VEC_RD or VEC_WR here (VEC_EX is
                # checked a few lines up).
                ( ( $select_index == VEC_RD ) ? 'readable' : 'writable' ),

                # Nothing here!  Callback all gone!
                ''

              );

          } elsif (POE_USES_EVENT) { # include

            # If we're using Event, then we tell it to stop watching
            # this filehandle for us.  This is in lieu of our own
            # select code.

            $kr_handle->[HND_WATCHERS]->[$select_index]->cancel();
            $kr_handle->[HND_WATCHERS]->[$select_index] = undef;

          } # include

          # Shrink the bit vector by chopping zero octets from the
          # end.  Octets because that's the minimum size of a bit
          # vector chunk that Perl manages.  Always keep at least one
          # octet around, even if it's 0.

          $self->[KR_VECTORS]->[$select_index] =~ s/(.)\000+$/$1/;
        }

        # Decrement the kernel record's handle reference count.  If
        # the handle is done being used, then delete it from the
        # kernel's record structure.  This initiates Perl's garbage
        # collection on it, as soon as whatever else in "user space"
        # frees it.

        $kr_handle->[HND_REFCOUNT]--;

        if (ASSERT_REFCOUNT) { # include
          die if ($kr_handle->[HND_REFCOUNT] < 0);
        } # include

        unless ($kr_handle->[HND_REFCOUNT]) {
          delete $kr_handles->{$handle};
        }
      }
    }

    # SS_HANDLES - Remove the select from the session, assuming there
    # is a session to remove it from.

    my $kr_session = $self->[KR_SESSIONS]->{$session};
    if (exists $kr_session->[SS_HANDLES]->{$handle}) {

      # Remove it from the session's read, write or expedite vector.

      my $ss_handle = $kr_session->[SS_HANDLES]->{$handle};
      if ($ss_handle->[SH_VECCOUNT]->[$select_index]) {

        # Hmm... what is this?  Was POE going to support multiple selects?

        $ss_handle->[SH_VECCOUNT]->[$select_index] = 0;

        # Decrement the reference count, and delete the handle if it's done.

        $ss_handle->[SH_REFCOUNT]--;

        if (ASSERT_REFCOUNT) { # include
          die if ($ss_handle->[SH_REFCOUNT] < 0);
        } # include

        unless ($ss_handle->[SH_REFCOUNT]) {
          delete $kr_session->[SS_HANDLES]->{$handle};
          {% ses_refcount_dec $session %}
        }
      }
    }
  }
}

# "Macro" select that manipulates read, write and expedite selects
# together.
sub select {
  my ($self, $handle, $state_r, $state_w, $state_e) = @_;
  my $session = $self->[KR_ACTIVE_SESSION];
  $self->_internal_select($session, $handle, $state_r, VEC_RD);
  $self->_internal_select($session, $handle, $state_w, VEC_WR);
  $self->_internal_select($session, $handle, $state_e, VEC_EX);
  return 0;
}

# Only manipulate the read select.
sub select_read {
  my ($self, $handle, $state) = @_;
  $self->_internal_select($self->[KR_ACTIVE_SESSION], $handle, $state, VEC_RD);
  return 0;
};

# Only manipulate the write select.
sub select_write {
  my ($self, $handle, $state) = @_;
  $self->_internal_select($self->[KR_ACTIVE_SESSION], $handle, $state, VEC_WR);
  return 0;
};

# Only manipulate the expedite select.
sub select_expedite {
  my ($self, $handle, $state) = @_;
  $self->_internal_select($self->[KR_ACTIVE_SESSION], $handle, $state, VEC_EX);
  return 0;
};

# Turn off a handle's write vector bit without doing
# garbage-collection things.
sub select_pause_write {
  my ($self, $handle) = @_;

  {% validate_handle $handle, VEC_WR %}

  # Turn off the select vector's write bit for us.  We don't do any
  # housekeeping since we're only pausing the handle.  It's assumed
  # that we'll resume it again at some point.

  vec($self->[KR_VECTORS]->[VEC_WR], fileno($handle), 1) = 0;

  if (POE_USES_GTK) { # include

    my $kr_handle = $self->[KR_HANDLES]->{$handle};

    Gtk::Gdk->input_remove( $kr_handle->[HND_WATCHERS]->[VEC_WR] );
    $kr_handle->[HND_WATCHERS]->[VEC_WR] = undef;

  } elsif (POE_USES_TK) { # include

    $poe_main_window->fileevent
      ( $handle,
        'writable',
        ''
      );

  } elsif (POE_USES_EVENT) { # include

    $self->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_WR]->stop();

  } # include

  return 0;
}

# Turn on a handle's write vector bit without doing garbage-collection
# things.
sub select_resume_write {
  my ($self, $handle) = @_;

  {% validate_handle $handle, VEC_WR %}

  # Turn the select vector's write bit back on.  Resume whatever
  # watcher whichever event loop needs.

  vec($self->[KR_VECTORS]->[VEC_WR], fileno($handle), 1) = 1;

  if (POE_USES_GTK) { # include

    my $kr_handle = $self->[KR_HANDLES]->{$handle};

    confess "resuming unpaused handle"
      if defined $self->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_WR];

    $self->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_WR] =
      Gtk::Gdk->input_add( fileno($handle), 'write',
                           \&_gtk_select_write_callback, $handle
                         );

  } elsif (POE_USES_TK) { # include

    $poe_main_window->fileevent
      ( $handle,
        'writable',
        [ \&_tk_select_callback, $handle, VEC_WR ],
      );

  } elsif (POE_USES_EVENT) { # include

    $self->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_WR]->start();

  } # include

  return 1;
}

# Turn off a handle's read vector bit without doing garbage-collection
# things.
sub select_pause_read {
  my ($self, $handle) = @_;

  {% validate_handle $handle, VEC_RD %}

  # Turn off the select vector's read bit for us.  We don't do any
  # housekeeping since we're only pausing the handle.  It's assumed
  # that we'll resume it again at some point.

  vec($self->[KR_VECTORS]->[VEC_RD], fileno($handle), 1) = 0;

  if (POE_USES_GTK) { # include

    my $kr_handle = $self->[KR_HANDLES]->{$handle};

    Gtk::Gdk->input_remove( $kr_handle->[HND_WATCHERS]->[VEC_RD] );
    $kr_handle->[HND_WATCHERS]->[VEC_RD] = undef;

  } elsif (POE_USES_TK) { # include

    $poe_main_window->fileevent
      ( $handle,
        'readable',
        ''
      );

  } elsif (POE_USES_EVENT) { # include

    $self->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_RD]->stop();

  } # include

  return 0;
}

# Turn on a handle's read vector bit without doing garbage-collection
# things.
sub select_resume_read {
  my ($self, $handle) = @_;

  {% validate_handle $handle, VEC_RD %}

  # Turn the select vector's read bit back on.  Resume whatever
  # watcher whichever event loop needs.

  vec($self->[KR_VECTORS]->[VEC_RD], fileno($handle), 1) = 1;

  if (POE_USES_GTK) { # include

    my $kr_handle = $self->[KR_HANDLES]->{$handle};

    confess "resuming unpaused handle"
      if defined $self->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_RD];

    $self->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_RD] =
      Gtk::Gdk->input_add( fileno($handle), 'read',
                           \&_gtk_select_read_callback, $handle
                         );

  } elsif (POE_USES_TK) { # include

    $poe_main_window->fileevent
      ( $handle,
        'readable',
        [ \&_tk_select_callback, $handle, VEC_RD ],
      );

  } elsif (POE_USES_EVENT) { # include

    $self->[KR_HANDLES]->{$handle}->[HND_WATCHERS]->[VEC_RD]->start();

  } # include

  return 1;
}

#==============================================================================
# ALIASES
#==============================================================================

sub alias_set {
  my ($self, $name) = @_;
  my $kr_active_session = $self->[KR_ACTIVE_SESSION];

  # Don't overwrite another session's alias.
  if (exists $self->[KR_ALIASES]->{$name}) {
    return EEXIST if $self->[KR_ALIASES]->{$name} != $kr_active_session;
    return 0;
  }

  $self->[KR_ALIASES]->{$name} = $kr_active_session;
  $self->[KR_SESSIONS]->{$kr_active_session}->[SS_ALIASES]->{$name} = 1;

  {% ses_refcount_inc $kr_active_session %}

  return 0;
}

# Public interface for removing aliases.
sub alias_remove {
  my ($self, $name) = @_;
  my $kr_active_session = $self->[KR_ACTIVE_SESSION];

  return ESRCH unless exists $self->[KR_ALIASES]->{$name};
  return EPERM if $self->[KR_ALIASES]->{$name} != $kr_active_session;

  {% remove_alias $kr_active_session, $name %}

  return 0;
}

sub alias_resolve {
  my ($self, $name) = @_;
  my $session = {% alias_resolve $name %};
  $! = ESRCH unless defined $session;
  $session;
}

#==============================================================================
# Kernel and Session IDs
#==============================================================================

# Return the Kernel's "unique" ID.  There's only so much uniqueness
# available; machines on separate private 10/8 networks may have
# identical kernel IDs.  The chances of a collision are vanishingly
# small.

sub ID {
  my $self = shift;
  $self->[KR_ID];
}

# Resolve an ID to a session reference.  This function is virtually
# moot now that alias_resolve does it too.  This explicit call will be
# faster, though, so it's kept for things that can benefit from it.

sub ID_id_to_session {
  my ($self, $id) = @_;
  if (exists $self->[KR_SESSION_IDS]->{$id}) {
    $! = 0;
    return $self->[KR_SESSION_IDS]->{$id};
  }
  $! = ESRCH;
  return undef;
}

# Resolve a session reference to its corresponding ID.

sub ID_session_to_id {
  my ($self, $session) = @_;
  if (exists $self->[KR_SESSIONS]->{$session}) {
    $! = 0;
    return $self->[KR_SESSIONS]->{$session}->[SS_ID];
  }
  $! = ESRCH;
  return undef;
}

#==============================================================================
# Extra reference counts, to keep sessions alive when things occur.
# They take session IDs because they may be called from resources at
# times where the session reference is otherwise unknown.
#==============================================================================

sub refcount_increment {
  my ($self, $session_id, $tag) = @_;
  my $session = $self->ID_id_to_session( $session_id );
  if (defined $session) {

    # Increment the tag's count for the session.  If this is the first
    # time the tag's been used for the session, then increment the
    # session's reference count as well.

    my $refcount = ++$self->[KR_SESSIONS]->{$session}->[SS_EXTRA_REFS]->{$tag};

    if (TRACE_REFCOUNT) { # include
      carp( "+++ ", {% ssid %}, " refcount for tag '$tag' incremented to ",
            $refcount
          );
    } # include

    if ($refcount == 1) {
      {% ses_refcount_inc $session %}

      if (TRACE_REFCOUNT) { # include
          carp( "+++ ", {% ssid %}, " refcount for session is at ",
                $self->[KR_SESSIONS]->{$session}->[SS_REFCOUNT]
             );
      } # include

      $self->[KR_EXTRA_REFS]++;

      if (TRACE_REFCOUNT) { # include
        carp( "+++ session refcounts in kernel: ", $self->[KR_EXTRA_REFS] );
      } # include

    }

    return $refcount;
  }

  $! = ESRCH;
  undef;
}

sub refcount_decrement {
  my ($self, $session_id, $tag) = @_;
  my $session = $self->ID_id_to_session( $session_id );
  if (defined $session) {

    # Decrement the tag's count for the session.  If this was the last
    # time the tag's been used for the session, then decrement the
    # session's reference count as well.

    my $refcount = --$self->[KR_SESSIONS]->{$session}->[SS_EXTRA_REFS]->{$tag};

    if (ASSERT_REFCOUNT) { # include
      croak( "--- ", {% ssid %}, " refcount for tag '$tag' dropped below 0" )
        if $refcount < 0;
    } # include

    if (TRACE_REFCOUNT) { # include
      carp( "--- ", {% ssid %}, " refcount for tag '$tag' decremented to ",
            $refcount
          );
    } # include

    unless ($refcount) {
      {% remove_extra_reference $session, $tag %}

      if (TRACE_REFCOUNT) { # include
        carp( "--- ", {% ssid %}, " refcount for session is at ",
              $self->[KR_SESSIONS]->{$session}->[SS_REFCOUNT]
            );
      } # include

    }

    return $refcount;
  }

  $! = ESRCH;
  undef;
}

#==============================================================================
# HANDLERS
#==============================================================================

# Add or remove states from sessions.
sub state {
  my ($self, $state_name, $state_code, $state_alias) = @_;
  $state_alias = $state_name unless defined $state_alias;

  if ( (ref($self->[KR_ACTIVE_SESSION]) ne '') &&
                                        # -><- breaks subclasses... sky has fix
       (ref($self->[KR_ACTIVE_SESSION]) ne 'POE::Kernel')
  ) {
    $self->[KR_ACTIVE_SESSION]->register_state( $state_name,
                                                $state_code,
                                                $state_alias
                                              );
    return 0;
  }
                                        # no such session
  return ESRCH;
}

###############################################################################
# Bootstrap the kernel.  This is inherited from a time when multiple
# kernels could be present in the same Perl process. -><- I think
# multiple kernels will never again be supported; revising things to
# be more static may improve performance.

new POE::Kernel();

###############################################################################
1;

__END__

=head1 NAME

POE::Kernel - an event dispatcher and resource watcher

=head1 SYNOPSIS

The POE manpage includes and describes a sample program.

POE comes with its own event loop, which is based on select() and
written exclusively in Perl.  To use it, simply:

  use POE;

POE's functions will also map to Gtk's event loop if Gtk is used
first.  No other actions are required to begin using POE with Gtk.
See POE::Session's postback() method for mapping Gtk callbacks to POE
events.  See the test program 21_gtk.t for a sample POE program that
uses Gtk.

  use Gtk;
  use POE;

POE's functions will also map to Tk's event loop if Tk is used first.
No other actions are required to begin using POE with Tk.  See
POE::Session's postback() method for mapping Tk callbacks to POE
events.  See the test program 06_tk.t for a sample POE program that
uses Tk.

  use Tk;
  use POE;

POE can also encapsulate Event's event loop.  If Event is used before
POE, then POE will use it for you.  POE::Session's postback() method
can also be used here to have Event's watchers post POE events.

  use Event;
  use POE;

Methods to manage the process' global Kernel instance:

  # Retrieve the kernel's unique identifier.
  $kernel_id = $kernel->ID;

  # Run the event loop, only returning when it has no more sessions to
  # dispatche events to.
  $kernel->run( );

FIFO event methods:

  # Post an event to an arbitrary session.
  $kernel->post( $session, $state_name, @state_args );

  # Post an event back to the current session.
  $kernel->yield( $state_name, @state_args );

  # Synchronous state call, bypassing the event queue and returning
  # the state's return value directly.
  $state_return_value = $kernel->call( $session, $state_name, @state_args );

Alarm and delay methods:

  # Post an event which will be delivered at an absolute Unix epoch
  # time.  This clears previous timed events for the same state.
  $kernel->alarm( $state_name, $epoch_time, @state_args );

  # Post an additional alarm, leaving existing ones in the queue.
  $kernel->alarm_add( $state_name, $epoch_time, @state_args );

  # Post an event which will be delivered after some number of
  # seconds.  This clears previous timed events for the same state.
  $kernel->delay( $state_name, $seconds, @state_args );

  # Post an additional delay, leaving existing ones in the queue.
  $kernel->delay_add( $state_name, $seconds, @state_args );

  # Return the names of pending timed events.
  @state_names = $kernel->queue_peek_alarms( );

Symbolic name, or session alias methods:

  # Set an alias for the current session.
  $status = $kernel->alias_set( $alias );

  # Clear an alias for the current session:
  $status = $kernel->alias_remove( $alias );

  # Resolve an alias into a session reference.  Most POE::Kernel
  # methods do this for you.
  $session_reference = $kernel->alias_resolve( $alias );

  # Resolve a session ID to a session reference.  The alias_resolve
  # method does this as well, but this is faster.
  $session_reference = $kernel->ID_id_to_session( $session_id );

  # Return a session ID for a session reference.  It is functionally
  # equivalent to $session->ID.
  $session_id = $kernel->ID_session_to_id( $session_reference );

Filehandle watcher methods:

  # Watch for read readiness on a filehandle.  Clear a read select
  # from a filehandle.
  $kernel->select_read( $file_handle, $state_name );
  $kernel->select_read( $file_handle );

  # Watch for write readiness on a filehandle.  Clear a write select
  # from a filehandle.
  $kernel->select_write( $file_handle, $state_name );
  $kernel->select_write( $file_handle );

  # Pause and resume write readiness watching.  These have lower
  # overhead than full select_write() calls.
  $kernel->select_pause_write( $file_handle );
  $kernel->select_resume_write( $file_handle );

  # Watch for out-of-bound (expedited) read readiness on a filehandle.
  # Clear an expedite select from a filehandle.
  $kernel->select_expedite( $file_handle, $state_name );
  $kernel->select_expedite( $file_handle );

  # Set and/or clear a combination of selects in one call.
  $kernel->select( $file_handle,
                   $read_state_name,     # or undef to clear it
                   $write_state_name,    # or undef to clear it
                   $expedite_state_same, # or undef to clear it
                 );

Signal watcher and generator methods:

  # Map a signal name to its handler state.  Clear a signal-to-handler
  # mapping.
  $kernel->sig( $signal_name, $state_name );
  $kernel->sig( $signal_name );

  # Simulate a system signal by posting it through POE rather than
  # through the underlying OS.
  $kernel->signal( $session, $signal_name );

State management methods:

  # Remove an existing state from the current machine.
  $kernel->state( $state_name );

  # Add a new inline state, or replace an existing one.
  $kernel->state( $state_name, $code_reference );

  # Add a new object or package state, or replace an existing one.
  # The object method will be the same as the state name.
  $kernel->state( $state_name, $object_ref_or_package_name );

  # Add a new object or package state, or replace an existing one.
  # The object method may be different from the state name.
  $kernel->state( $state_name, $object_ref_or_package_name, $method_name );

External reference count methods:

  # Increment a session's external reference count.
  $kernel->refcount_increment( $session_id, $refcount_name );

  # Decrement a session's external reference count.
  $kernel->refcount_decrement( $session_id, $refcount_name );

Kernel data accessors:

  # Return a reference to the currently active session, or to the
  # kernel if called outside any session.
  $session = $kernel->get_active_session();

Exported symbols:

  # A reference to the global POE::Kernel instance.
  $poe_kernel

  # This is the Gtk or Tk top-level (or main) window widget.  POE uses
  # it for a couple things: It's how Tk's event loop is accessed, and
  # its closure fires the UIDESTROY signal.
  $poe_main_window

=head1 DESCRIPTION

POE::Kernel is an event dispatcher and resource watcher.  It provides
a consistent interface to the most common event loop features whether
the underlying architecture is its own, Gtk-Perl's, Tk-Perl's, or
Event's.  Other loop features can be integrated with POE through
POE::Session's postback() method.

=head1 USING POE::Kernel

The POE manpage describes a shortcut for using several POE modules at
once.

POE::Kernel supports four event loops: Its own select loop, included
with POE and coded in Perl for maximum portability; Gtk's and Tk's
loops, which let programs interact with users through a graphical
interface; and Event's loop, which is written in C for maximum
performance.

POE::Kernel uses its own loop by default, but it will adapt to
whichever external event loop is loaded before it.  POE's functions
work the same regardless of the underlying event loop.

  # Use POE's select loop.
  use POE::Kernel;

  # Use Gtk's event loop.
  use Gtk;
  use POE::Kernel;

  # Use Tk's event loop.
  use Tk;
  use POE::Kernel;

  # Use Event's loop.
  use Event;
  use POE::Kernel;

All of the other event loops assume their native watchers will invoke
callbacks.  POE::Session's postback() method is used to create
callbacks that post POE events.  Programs can use it to take advantage
of otherwise "unsupported" native callbacks.

It also is possible to enable assertions and debugging traces by
defining the constants that enable them before POE::Kernel does.
Every definition follows the form:

  sub POE::Kernel::ASSERT_SOMETHING () { 1 }

Assertions are quiet until something wrong has been detected, and then
they die right away with an error.  Their main use is for sanity
checks in POE's test suite.  Traces, on the other hand, are never
fatal, but they're terribly noisy.

Both assertions and traces incur performance penalties, so they should
be used sparingly, if at all.  They all are off by default.

Assertions will be discussed first.

=over 2

=item ASSERT_DEFAULT

The value of ASSERT_DEFAULT is used as the default value for the other
assertion constants.  Setting this true is a quick and reliable way to
ensure that all assertions are enabled.

=item ASSERT_GARBAGE

Enabling ASSERT_GARBAGE has POE::Kernel verify its internal record
keeping against sane conditions.  In particular, it ensures that
sessions have released all their resources before destroying them.

=item ASSERT_REFCOUNT

Setting ASSERT_REFCOUNT true enables checks for negative reference
counts and nonzero reference counts in destroyed sessions.  It
complements ASSERT_GARBAGE.

=item ASSERT_RELATIONS

Enabling ASSERT_RELATIONS turns on parent/child referential integrity
checks.

=item ASSERT_SELECT

Setting ASSERT_SELECT true enables extra error checking in
POE::Kernel's select logic.  It has no effect if POE is using an
external event loop.

=item ASSERT_SESSIONS

POE::Kernel normally discards events that are posted to nonexistent
sessions.  This is a deliberate feature, but it means that certain
typographical errors can go unnoticed.

A true ASSERT_SESSIONS constant will cause POE to check session
resolution and die if an unknown session is referenced.  This may
catch problems that are otherwise difficult to spot.

=back

Then there are the trace options.

=over 2

=item TRACE_DEFAULT

TRACE_DEFAULT works like ASSERT_DEFAULT except for traces.  That is,
its value is used as the default for the other trace constants.
Setting it true is a quick and reliable way to turn on every type of
trace.

=item TRACE_EVENTS

The music goes around and around, and it comes out here.  Enabling
TRACE_EVENTS causes POE::Kernel to tell you what happens to FIFO and
alarm events: when they're enqueued, dispatched or discarded, and what
their states return.

=item TRACE_GARBAGE

TRACE_GARBAGE shows what's keeping sessions alive.  It's useful for
determining why a session simply refuses to die, or why it won't stay
alive.

=item TRACE_PROFILE

This trace constant switches on state profiling, causing POE::Kernel
to keep a count of every state it dispatches.  It displays a frequency
report when the event loop finishes.

=item TRACE_QUEUE

TRACE_QUEUE complements TRACE_EVENTS.  When enabled, it traces the
contents of POE's event queues, giving some insight into how events
are ordered.  This has become less relevant since the alarm and FIFO
queues have separated.

=item TRACE_REFCOUNT

Setting TRACE_REFCOUNT to true enables debugging output whenever an
external reference count changes.

=item TRACE_SELECT

TRACE_SELECT enables or disables statistics about POE::Kernel's
default select loop's select parameters and return values.

=back

=head1 POE::Kernel Exports

POE::Kernel exports two symbols for your coding enjoyment: $poe_kernel
and $poe_main_window.  POE::Kernel is implicitly used by POE
itself, so using POE gets you POE::Kernel (and its exports) for free.

=over 2

=item $poe_kernel

This contains a reference to the process' POE::Kernel instance.  It's
mainly useful for getting at the kernel from places other than states.
For example, most programs call C<$poe_kernel->run()> to run its event
loop.

States rarely need to use $poe_kernel directly since they receive a
copy of it in $_[KERNEL].

=item $poe_main_window

POE creates a "main" or "top-level" window when Tk or Gtk are used.
Tk requires a main window before its events can be used, and both
toolkits signal destruction through a top-level window callback.  That
callback is used to fire a UIDESTROY signal when a program is closed.

Rather than waste the window, POE exports it as $poe_main_window.

=back

=head1 PRIVATE KERNEL METHODS

The private kernel methods are private.  All the usual "here there be
private methods" caveats apply.  As such, they won't be documented
here.  The terminally curious, however, will note that POE::Kernel
contains a lot of comments.

=head1 PUBLIC KERNEL METHODS

This section discusses in more detail the POE::Kernel methods that
appear in the SYNOPSIS.  It uses the same syntax conventions as the
perlfunc manpage.

=head2 Methods to manage the process' global Kernel instance

=over 2

=item ID

Return the POE::Kernel instance's unique identifier.

Every POE::Kernel instance is assigned an ID at birth.  This ID tries
to differentiate any given instance from all the others, even if they
exist on the same machine.  The ID is a hash of the machine's name and
the kernel's instantiation time and process ID.

  ~/perl/poe$ perl -wl -MPOE -e 'print $poe_kernel->ID'
  rocco.homenet-39240c97000001d8

=item run

Runs the chosen event loop, returning only after every session has
stopped.  It returns immediately if no sessions have yet been started.

  $poe_kernel->run();
  exit;

The run() method does not return a meaningful value.

=back

=head2 FIFO event methods

Events posted with these methods are dispatched back to sessions in
first-in/first-out order (in case you didn't know what FIFO meant).

Sessions will not spontaneously stop if they have pending FIFO events.
In other words, FIFO events keep sessions alive.

=over 2

=item post SESSION, STATE_NAME, PARAMETER_LIST

=item post SESSION, STATE_NAME

Posts an event for STATE_NAME in SESSION.  If a PARAMETER_LIST is
included, its values will be used as arguments to STATE_NAME.

  $_[KERNEL]->post( $session, 'do_this' );
  $_[KERNEL]->post( $session, 'do_that', $with_this, $and_this );
  $_[KERNEL]->post( $session, 'do_that', @with_these );

The post() method a boolean value indicating whether the event was
enqueued successfully.  The $! variable will explain why post()
failed.

=over 2

=item * ESRCH

POE cannot find SESSION.

=back

=item yield STATE_NAME, PARAMETER_LIST

=item yield STATE_NAME

Posts an event for STATE_NAME in the current session.  If a
PARAMETER_LIST is included, its values will be used as arguments to
STATE_NAME.  Observant readers will note that this is just post() to
the current session.

Events posted with yield() must propagate through POE's FIFO before
they're dispatched.  This effectively yields FIFO time to other
sessions which already have events enqueued.

  $kernel->yield( 'do_this' );
  $kernel->yield( 'do_that', @with_these );

The yield() method does not return a meaningful value.

=item call SESSION, STATE_NAME, PARAMETER_LIST

=item call SESSION, STATE_NAME

Calls STATE_NAME in a SESSION, bypassing the FIFO.  Values from the
optional PARAMETER_LIST will be passed as arguments to STATE_NAME at
dispatch time.  The call() method returns its status in $!, which is 0
for success or a nonzero reason for failure.

  $return_value = $kernel->call( 'do_this_now' );

POE uses call() to dispatch some resource events without FIFO latency.
Filehandle watchers, for example, would continue noticing a handle's
readiness until the it was serviced by a state.  This could result in
several redundant readiness events being enqueued before the first one
was dispatched.

Reasons why call() might fail:

=over 2

=item * ESRCH

POE disbelieves in SESSION.

=back

=head2 Alarm and delay methods

POE also manages timed events.  These are events that should be
dispatched after at a certain time or after some time has elapsed.
Alarms and delays always are enqueued for the current session, so a
SESSION parameter is not needed.

POE's timed events fall into two major categories: ones which are to
be dispatched at an absolute time, and ones that will be dispatched
after a certain amount of time has elapsed.

Each category is further divided into methods that clear previous
timed events before posting new ones, and methods that post timed
events in addition to the ones already in the queue.

POE will use Time::HiRes to increase timed events' accuracy.  It will
use the less accurate time(2) if Time::HiRes isn't available.

Sessions will not spontaneously stop if they have pending timed
events.  In other words, these events keep sessions alive.

=over 2

=item alarm STATE_NAME, EPOCH_TIME, PARAMETER_LIST

=item alarm STATE_NAME, EPOCH_TIME

=item alarm STATE_NAME

Clears all the timed events destined for STATE_NAME in the current
session then optionally sets a new one.  The new timed event will be
dispatched to STATE_NAME no earlier than EPOCH_TIME and can include
values from an optional PARAMETER_LIST.

The timed event queue is kept in time order.  Posting an alarm with an
EPOCH_TIME in the past will do the obvious thing.

The first two forms reset a one-shot timed event by clearing any
pending ones for STATE_NAME before setting a new one.

  $kernel->alarm( 'do_this', $at_this_time, @with_these_parameters );
  $kernel->alarm( 'do_this', $at_this_time );

The last form clears all pending timed events for the state without
setting a new one.

  $kernel->alarm( 'do_this' );

This method will clear timed events regardless of how they were set.

C<alarm()> returns 0 on success or a reason for its failure:

=over 2

=item * EINVAL

STATE_NAME is undefined.

=back

=item alarm_add STATE_NAME, EPOCH_TIME, PARAMETER_LIST

=item alarm_add STATE_NAME, EPOCH_TIME

Sets an additional timed event for STATE_NAME in the current session
without clearing previous ones.  The timed event will be dispatched no
earlier than EPOCH_TIME.

  $kernel->alarm_add( 'do_this', $at_this_time, @with_these_parameters );
  $kernel->alarm_add( 'do_this', $at_this_time );

Use the alarm() or delay() method to clear timed events set by
alarm_add().

C<alarm_add()> returns 0 on success or a reason for failure:

=over 2

=item * EINVAL

Either STATE_NAME or EPOCH_TIME is undefined.

=back

=item delay STATE_NAME, SECONDS, PARAMETER_LIST

=item delay STATE_NAME, SECONDS

=item delay STATE_NAME

Clears all the timed events destined for STATE_NAME in the curernt
session then optionally sets a new one.  The new timed event will be
dispatched to STATE_NAME after no fewer than SECONDS have elapsed. If
the optional PARAMETER_LIST is included, then its values will be
passed along to the state when it's invoked.

C<delay()> uses whichever time(2) is available to POE::Kernel.  It
uses the more accurate Time::HiRes::time() if it's available, or plain
time(2) if it's not.  This obviates the need to check for Time::HiRes
in your own code.

The timed event queue is kept in time order, and delays posted with
negative SECONDS will do the obvious thing.  SECONDS may be fractional
regardless of which time() function is available.

The first two forms enqueue a new delay after the pending timed events
for STATE_NAME are cleared.

  $kernel->delay( 'do_this', $after_this_much_time, @with_these );
  $kernel->delay( 'do_this', $after_this_much_time );

The last form clears pending timed events without setting a new one.

  $kernel->delay( 'do_this' );

C<delay()> returns 0 on success or a reason for its failure:

=over 2

=item * EINVAL

STATE_NAME is undefined.

=back

=item delay_add STATE_NAME, SECONDS, PARAMETER_LIST

=item delay_add STATE_NAME, SECONDS

Sets an additional timed event for STATE_NAME in the current session
without clearing previous ones.  The event will be dispatched no
sooner than SECONDS seconds hence.

  $kernel->delay_add( 'do_this', $after_this_much_time, @with_these );
  $kernel->delay_add( 'do_this', $after_this_much_time );

Use the alarm() or delay() method to clear timed events set by
alarm_add().

C<delay_add()> returns 0 on success or a reason for failure:

=over 2

=item * EINVAL

Either STATE_NAME or SECONDS is undefined.

=back

=item queue_peek_alarms

Returns a time-ordered list of state names in the current session that
have pending timed events.

  my @pending_alarms = $kernel->queue_peek_alarms();

=back

=head2 Symbolic name, or session alias methods

Methods in this section allow sessions to refer to each-other by
symbolic name or numeric ID.

Session IDs are quite a lot like process IDs, but they are unique to
the sessions within the current POE::Kernel.  In theory, a combination
of POE::Kernel and Session IDs should be enough to uniquely identify a
particular session anywhere in the world.

Most POE::Kernel methods resolve SESSION internally, so it's possible
to refer to sessions by a number of things.  See the alias_resolve()
description for more information.

Sessions will not spontaneously stop if they have aliases.  In other
words, aliases keep sessions alive.

=over 2

=item alias_set ALIAS

Sets an ALIAS for the current session.  ALIAS then may be used nearly
everywhere instead of SESSION.  Sessions may have more than one ALIAS;
each must be defined in a separate alias_set() call.

  $kernel->alias_set( 'ishmael' );

Having an alias "daemonizes" a session, allowing it to stay alive even
when there's nothing for it to do.  Sessions can use this to become
autonomous services that other sessions refer to by name.

  $kernel->alias_set( 'httpd' );
  $kernel->post( 'httpd', 'set_handler', 'URI_regexp', 'my_state' );

alias_set() returns 0 on success, or a nonzero failure indicator:

=over 2

=item * EEXIST

The alias already is assigned to a different session.

=back

=item alias_remove ALIAS

Clears an existing ALIAS from the current session.  ALIAS will no
longer refer to this session.

  $kernel->alias_remove( 'shirley' );

The session will begin its destruction if the alias was all that kept
it alive.

alias_remove() returns 0 on success or a reason for its failure:

=over 2

=item * ESRCH

POE::Kernel disavows all knowledge of the alias.

=item * EPERM

The alias belongs to another session, and the current one has no
permission to clear it.

=back

=item alias_resolve ALIAS

Resolves an alias name into a session reference.  alias_resolve() has
been overloaded over time to look up additional things, and now ALIAS
may be:

A session alias:

  $session_reference = $kernel->alias_resolve( 'irc_component' );

A stringified session reference:

  $blessed_session_reference = $kernel->alias_resolve( "$stringified_one" );

Or a session ID:

  $session_reference = $kernel->alias_resolve( $session_id );

alias_resolve() returns undef upon failure, setting $! to explain the
error:

=over 2

=item * ESRCH

POE::Kernel can't find ALIAS anywhere.

=back

The following functions work with IDs directly.  They were at one
point depreciated, but it was decided to keep them since they're
faster than alias_resolve() for working solely with session IDs.

For example, Philip Gwyn's inter-kernel calls module,
POE::Component::IKC, uses these to resolve sessions across processes.

=item ID_id_to_session SESSION_ID

Resolves a session reference from a SESSION_ID.

  $session_reference = ID_id_to_session( $session_id );

It returns a session reference on success or undef on failure.  If it
fails, $! contains the reason why:

=over 2

=item * ESRCH

POE::Kernel doesn't have session SESSION_ID.

=back

=item ID_session_to_id SESSION_REFERENCE

Resolves a session ID from a session reference.  This is virtually
identical to SESSION_REFERENCE->ID, except that SESSION_REFERENCE may
be stringified:

  $session_id = ID_session_to_id( $stringified_session_reference );

It returns a session ID on success or undef in the case of a failure.
If it fails, $! says why:

=over 2

=item * ESRCH

POE::Kernel has no session matching SESSION_REFERENCE.

=back

=back

=head2 Filehandle watcher methods

Sessions use these methods to tell POE::Kernel what type of filehandle
activity they're interested in.  POE::Kernel synchronously calls
states registered to deal with filehandle activity when one of these
interesting events occurs.

States are called synchronously so that the filehandle activity may be
dealt with immediately.  This avoids the watcher seeing the same
activity twice.  When a state is called, it receives a copy of the
filehandle in $_[ARG0].  ARG0 is one of POE::Session's parameter
offset constants; you can read more about it in the POE::Session
manpage.

Sessions will not spontaneously stop as long as they are watching at
least one filehandle.  In other words, watching a filehandle keep a
session alive.

States that are invoked by select watchers receive some parameters to
help them remember why they were called.

=over 2

=item select_read FILE_HANDLE, STATE_NAME

=item select_read FILE_HANDLE

Starts and stops calling the current session's STATE_NAME state when
FILE_HANDLE becomes ready for reading.

  $kernel->select_read( $filehandle, 'do_a_read' );
  $kernel->select_read( $filehandle );

select_read() does not return a meaningful value.

=item select_write FILE_HANDLE, STATE_NAME

=item select_write FILE_HANDLE

Starts and stops calling the current session's STATE_NAME state when
FILE_HANDLE becomes ready for writing.

  $kernel->select_write( $filehandle, 'flush_some_data' );
  $kernel->select_write( $filehandle );

select_write() does not return a meaningful value.

=item select_expedite FILE_HANDLE, STATE_NAME

=item select_expedite FILE_HANDLE

Starts and stops calling the current session's STATE_NAME state when
FILE_HANDLE becomes ready for out-of-band reading.

  $kernel->select_expedite( $filehandle, 'do_an_oob_read' );
  $kernel->select_expedite( $filehandle );

select_expedite() does not return a meaningful value.

=item select_pause_write FILE_HANDLE

=item select_resume_write FILE_HANDLE

Temporarily pauses and resumes write watching on a filehandle.  These
functions only manipulate the select(2) write bits for FILE_HANDLE.
They don't perform full resource management on FILE_HANDLE.  This
makes select_pause_write() and select_resume_write() ideal for data
flushers.

  $kernel->select_pause_write( $filehandle );
  $kernel->select_resume_write( $filehandle );

These methods don't return meaningful values.

=item select FILE_HANDLE, READ_STATE_NAME, WRITE_STATE_NAME, EXPEDITE_STATE_NAME

Sets or clears read, write, and expedite watchers on a filehandle all
together.  Watchers for defined state names will be set, and undefined
state names will clear the corresponding watchers.

For example, set all three:

  $kernel->select( $filehandle, 'do_a_read', 'flush', 'read_oob' );

And to clear all three:

  $kernel->select( $filehandle );

To configure watchers for a read-only handle:

  $kernel->select( $filehandle, 'do_a_read', undef, 'read_oob' );

And a write-only handle:

  $kernel->select( $filehandle, undef, 'flush' );

This method does not return a meaningful value.

=back

=head2 Signal watcher and generator methods

Sessions always receive signal events, even if they aren't explicitly
watching for them.  These signal watcher methods merely manage
mappings between signal names and state names.  The POE::Session
manpage describes the default signal handler state, _signal, in a
little more detail.

Unlike with the previous resource watchers, sessions B<may>
spontaneously stop even if they are hold signal name maps.  In other
words, signal name maps B<do not> keep sessions alive.

POE does not make Perl's signal handling safe by itself.  The Event
module, however, does implement safe signals, and POE will take
advantage of them when they're available.

Most signals propagate depth first through the sessions' parent/child
relationships.  That is, they are delivered to grandchildren, then
children, then parents, then grandparents, all the way back to the
global POE::Kernel instance, which is the oldest ancestor in the tree.

There are three signal levels: nonmaskable, terminal, and benign.

A benign signal never stops a session, even if the session doesn't
handle it.  Most signals are benign.  Note, however, that at the time
of this writing even benign signals can crash Perl.

A terminal signal will stop any session that doesn't handle it.  There
are relatively few terminal signals: HUP, IDLE (fictitious; explained
below), INT, KILL, QUIT, TERM.

A nonmaskable signal always stops a session, even if the session says
it's been handled.  There are only two nonmaskable signals, and they
both are fictitious and explained shortly: ZOMBIE and UIDESTROY.

A signal handling state's return value tells POE whether it handled
the signal.  A true return value means that the state handled the
signal; a false value indicates that the state did not.  Handling a
signal does not prevent it from propagating up the sessions'
relationship tree.

As was previously mentioned, POE generates three fictitious signals.
These notify sessions when extraordinary circumstances occur.  They
are IDLE, UIDESTROY and ZOMBIE.

The terminal IDLE signal is posted when the only sessions remaning are
alive by virtue of having aliases.  This situation occurs when daemon
sessions exist without any clients to interact with.  POE posts IDLE
to them, giving them an opportunity to prove they're not yet dead.

The UIDESTROY signal is, regrettably nonmaskable.  It indicates that
the program's UI has signaled its destruction.  In Gtk and Tk, it
means that the main or top-level window is being closed, and
everything must go.

ZOMBIE is a nonmaskable signal as well.  It's posted if IDLE hasn't
been effective in waking any lingering daemon sessions.  It tells the
remaining sessions that they've wasted their opportunity to do
something, and now it's time to die.

Three system signals have special handling.  They are SIGCH?LD,
SIGPIPE, and SIGWINCH.

POE::Kernel's SIGCHLD and SIGCLD handlers both appear to sessions as
CHLD.  The Kernel's handlers automatically call waitpid(2) on behalf
of sessions, collecting stopped child process' IDs and return values.
CHLD signal handlers receive stopped child PIDs in $_[ARG1], and the
return value form $? in $_[ARG2].  As usual, $_[ARG0] contains 'CHLD'.

POE::Kernel's SIGPIPE handler only posts PIPE to the currently running
session.  This may be a problem since signals are delivered
asynchronously to processes; the author has been saved so far because
nobody seems to use SIGPIPE for anything anyway.

Finally, SIGWINCH is just ignored outright.  Window managers generate
several of these all at once, which, at the time of this writing,
kills Perl in short order.

=over 2

=item sig SIGNAL_NAME, STATE_NAME

=item sig SIGNAL_NAME

Registers or unregisters a handler for SIGNAL_NAME.  Signal names are
the same as %SIG use, with one exception: CLD will be delivered as
CHLD, so sessions handling CHLD will get both.

  $kernel->sig( INT => 'sigint_handler' );

The handler for SIGNAL_NAME will be unregistered if STATE_NAME is
omitted.

  $kernel->sig( INT );

It is possible to register handlers for signals that the operating
system will never deliver.  This allows sessions to watch for
fictitious signals that are generated through POE instead of kill(2).

The sig() method does not return a meaningful value.

=item signal SESSION, SIGNAL_NAME

Posts a signal to a session through POE::Kernel rather than via
kill(2).  SIGNAL_NAME needn't be supported by the underlying operating
system.

  $kernel->signal( $session, 'DIEDIEDIE' );

POE::Kernel's signal() method doesn't return a meaningful value.

=back

=head2 State management methods

These methods allow sessions to modify their states at runtime.  It
would be rude to alter other sessions' states, so these methods only
affects the current session.

=over 2

=item state STATE_NAME

=item state STATE_NAME, CODE_REFERENCE

=item state STATE_NAME, OBJECT_REFERENCE

=item state STATE_NAME, OBJECT_REFERENCE, OBJECT_METHOD_NAME

=item state STATE_NAME, PACKAGE_NAME

=item state STATE_NAME, PACKAGE_NAME, PACKAGE_METHOD_NAME

Adds a new state to the current session, removes an existing state
from it, or replaces an existing state in it.

The first form deletes a state, regardless whether it's handled by a
code reference, an object method or a package method.

  $kernel->state( 'do_this' );

The second form registers a new handler or overwrites an existing one
with a new coderef.  They were originally called inline states because
early POE prototypes defined them with inline anonymous subs.

  $kernel->state( 'do_this', \&this_does_it );

The third and fourth forms register a new handler or overwrite an
existing one with an object method.  These are known as object states.
In the third form, the object's method matches the state's name:

  $kernel->state( 'do_this', $with_this_object );

The fourth form allows state names to be mapped to differently named
object methods.  This example defines a mapped object state:

  $kernel->state( 'do_this', $with_this_object, $and_this_method );

The fifth and sixth forms allow state names register a new handler or
owerwrite an existing one with a package method.  These are known as
package states.  In the fifth form, the package's method matches the
state's name:

  $kernel->state( 'do_this', $with_this_package );

The sixth form allows state names to be mapped to differently named
package methods.  This example defines a mapped package state:

  $kernel->state( 'do_this', $with_this_package, $and_this_method );

POE::Kernel's state() method returns 0 on success or a nonzero code
explaining why it failed:

=over 2

=item * ESRCH

POE::Kernel has no knowledge of the currently active session.  This
occurs when state() is called when no session is active.

=back

=head2 External reference count methods

External reference counts were created so POE could cooperate with
other event loops.  They external resource watchers to prevent
sessions from spontaneously self-destructing.  Held external events
essentially say "Ok, don't die 'til I'm done."

External reference counts are kept by name.  This feature is still
relatively new, so there is no convention in place to prevent
namespace collisions.  If anyone has ideas about this, please contact
the author.

=over 2

=item refcount_increment SESSION_ID, REFCOUNT_NAME

=item refcount_decrement SESSION_ID, REFCOUNT_NAME

Increments or decrements a reference count called REFCOUNT_NAME in the
session identified by SESSION_ID.  Returns undef on failure, or the
new reference count on success.

  $new_count = $kernel->refcount_increment( $session_id, 'postback' );
  $new_count = $kernel->refcount_decrement( $session_id, 'postback' );

These methods set $! upon failure:

=over 2

=item * ESRCH

The session formerly known as SESSION_ID no longer (or perhaps never
did) exist.

=back

=back

=head2 Kernel Data Accessors

These functions provide a consistent interface to the Kernel's
internal data.

=over 2

=item get_active_session

This function returns a reference to the session which is currently
being invoked by the Kernel.  When no session is currently being
invoked, it returns a reference to the Kernel itself.  This is one of
the times where the Kernel pretends its a session.

Note, though, that the Kernel does not have a heap.  Attempting
something like this will fail if get_active_session() returns a
reference to the Kernel.

  $kernel->get_active_session()->get_heap()->{key} = $value;

=back

=head1 SEE ALSO

The POE manpages contains holistic POE information.

=head1 BUGS

There are no currently known bugs.  If you find one, tell the author!

=head1 AUTHORS & COPYRIGHTS

Please see the POE manpage for authors and licenses.

=cut
