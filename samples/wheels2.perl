#!/usr/bin/perl -w
# $Id: wheels2.perl,v 1.3 2000/01/23 18:32:02 rcaputo Exp $

# A simple socket client that uses a two-handle wheel to pipe between
# a socket and the console.  It's hardcoded to talk with wheels.perl's
# rot13 server on localhost port 32000.

use strict;
use lib '..';
use POSIX;

use POE qw(Wheel::SocketFactory Wheel::ReadWrite Driver::SysRW Filter::Stream);

my $rot13_port = 32000;

#==============================================================================
# A client socket session that pipes between a connected socket and
# the console.  It has two phases of operation: Connect phase, and
# Interact phase.

#------------------------------------------------------------------------------
# Start the session by trying to connect to a server.  Create a
# SocketFactory, then sit back until something occurs.

sub session_start {
  my ($kernel, $heap, $connected_socket) = @_[KERNEL, HEAP, ARG0];

  print "Connecting...\n";

  $heap->{connector} = new POE::Wheel::SocketFactory
    ( RemoteAddress => '127.0.0.1',
      RemotePort => $rot13_port,
      SuccessState => 'connect_success',
      FailureState => 'connect_failure',
    );
}

#------------------------------------------------------------------------------
# The connection succeeded.  Discard the spent SocketFactory, and
# start two ReadWrite wheels to pipe data back and forth.  NOTE: This
# doesn't do terminal characteristic games, so I/O may be choppy or
# otherwise icky.

sub session_connect_success {
  my ($heap, $kernel, $connected_socket) = @_[HEAP, KERNEL, ARG0];

  delete $heap->{connector};

  $heap->{console_wheel} = new POE::Wheel::ReadWrite
    ( InputHandle => \*STDIN,
      OutputHandle => \*STDOUT,
      Driver => new POE::Driver::SysRW(),
      Filter => new POE::Filter::Stream(),
      InputState => 'console_input',
      ErrorState => 'console_error',
    );

  $heap->{socket_wheel} = new POE::Wheel::ReadWrite
    ( Handle => $connected_socket,
      Driver => new POE::Driver::SysRW(),
      Filter => new POE::Filter::Stream(),
      InputState => 'socket_input',
      ErrorState => 'socket_error',
    );

  $heap->{console_wheel}->put("Begun terminal session.");
}

#------------------------------------------------------------------------------
# The connection failed.  Close down everything so that POE will reap
# the session and exit.

sub session_connect_failure {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];
  if ($errnum) {
    print "!!! Connecting: $operation error $errnum: $errstr\n";
  }
  delete $heap->{connector};
  delete $heap->{console_wheel};
  delete $heap->{socket_wheel};
}

#------------------------------------------------------------------------------
# The session has stopped.  Delete the wheels once again, just for
# redundancy's sake.

sub session_stop {
  my $heap = $_[HEAP];
  delete $heap->{connector};
  delete $heap->{console_wheel};
  delete $heap->{socket_wheel};
}

#------------------------------------------------------------------------------
# Console input has arrived.  Send it to the socket.

sub session_console_input {
  $_[HEAP]->{socket_wheel}->put($_[ARG0]);
}

#------------------------------------------------------------------------------
# There has been an error on one of the console filehandles.  Close
# down everything so that POE will reap the session and exit.

sub session_console_error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];
  if ($errnum) {
    print "!!! Console: $operation error $errnum: $errstr\n";
  }
  delete $heap->{console_wheel};
  delete $heap->{socket_wheel};
}

#------------------------------------------------------------------------------
# Socket input has arrived.  Send it to the console.

sub session_socket_input {
  $_[HEAP]->{console_wheel}->put($_[ARG0]);
}

#------------------------------------------------------------------------------
# A socket error has occurred.  Close down everything so that POE will
# reap the session and exit.

sub session_socket_error {
  my ($heap, $operation, $errnum, $errstr) = @_[HEAP, ARG0, ARG1, ARG2];
  if ($errnum) {
    print "!!! Socket: $operation error $errnum: $errstr\n";
  }
  delete $heap->{console_wheel};
  delete $heap->{socket_wheel};
}

#==============================================================================
# Start the Session, which will fire off the _start event and begin
# the connection.

new POE::Session
  ( _start => \&session_start,
    _stop  => \&session_stop,

    connect_success => \&session_connect_success,
    connect_failure => \&session_connect_failure,

    console_input   => \&session_console_input,
    console_error   => \&session_console_error,

    socket_input    => \&session_socket_input,
    socket_error    => \&session_socket_error,
  );

$poe_kernel->run();

exit;
