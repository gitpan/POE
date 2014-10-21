#!/usr/bin/perl /w
# $Id: 14_wheels_ft.t,v 1.3 2000/09/01 19:53:55 rcaputo Exp $

# Exercises Wheel::FollowTail, Wheel::ReadWrite, and Filter::Block.

use strict;
use lib qw(./lib ../lib);
use Socket;

use TestSetup;
&test_setup(8);

# Turn on all asserts.
# sub POE::Kernel::TRACE_DEFAULT () { 1 }
sub POE::Kernel::ASSERT_DEFAULT () { 1 }
use POE qw( Component::Server::TCP
            Wheel::FollowTail
            Wheel::ReadWrite
            Wheel::SocketFactory
            Filter::Line
            Filter::Block
            Driver::SysRW
          );

my $tcp_server_port = 31909;
my $max_send_count  = 10;    # expected to be even

# Congratulations! We made it this far!
&ok(1);

###############################################################################
# A generic server session.

sub sss_new {
  my ($socket, $peer_addr, $peer_port) = @_;
  POE::Session->create
    ( inline_states =>
      { _start     => \&sss_start,
        _stop      => \&sss_stop,
        got_error  => \&sss_error,
        got_block  => \&sss_block,
        ev_timeout => sub { delete $_[HEAP]->{wheel} },
      },
      args => [ $socket, $peer_addr, $peer_port ],
    );
}

sub sss_start {
  my ($heap, $socket, $peer_addr, $peer_port) = @_[HEAP, ARG0..ARG2];

  delete $heap->{wheel};
  $heap->{wheel} = POE::Wheel::FollowTail->new
    ( Handle       => $socket,
      Driver       => POE::Driver::SysRW->new( BlockSize => 24 ),
      Filter       => POE::Filter::Block->new( BlockSize => 16 ),
      InputState   => 'got_block',
      ErrorState   => 'got_error',
    );

  $heap->{test_two} = 1;
  $heap->{wheel_id} = $heap->{wheel}->ID;
  $heap->{read_count} = 0;
}

sub sss_block {
  my ($kernel, $heap, $block) = @_[KERNEL, HEAP, ARG0];
  $heap->{read_count}++;
  $kernel->delay( ev_timeout => 2 );
}

sub sss_error {
  $_[HEAP]->{test_two} = 0;
}

sub sss_stop {
  &ok_if(2, $_[HEAP]->{test_two});
}

###############################################################################
# A TCP socket client.

sub client_tcp_start {
  my $heap = $_[HEAP];

  $heap->{wheel} = POE::Wheel::SocketFactory->new
    ( RemoteAddress  => '127.0.0.1',
      RemotePort    => $tcp_server_port,
      SuccessState  => 'got_server',
      FailureState  => 'got_error',
    );

  $heap->{socketfactory_wheel_id} = $heap->{wheel}->ID;
  $heap->{test_three} = 1;
}

sub client_tcp_stop {
  &ok_if(3, $_[HEAP]->{test_three});
  &ok_if(4, $_[HEAP]->{put_count} == $max_send_count);
  &ok_if(5, $_[HEAP]->{flush_count} == $_[HEAP]->{put_count} / 2);
  &ok_if(6, $_[HEAP]->{test_six});
}

sub client_tcp_connected {
  my ($kernel, $heap, $server_socket) = @_[KERNEL, HEAP, ARG0];

  delete $heap->{wheel};
  $heap->{wheel} = POE::Wheel::ReadWrite->new
    ( Handle       => $server_socket,
      Driver       => POE::Driver::SysRW->new( BlockSize => 32 ),
      Filter       => POE::Filter::Block->new( BlockSize => 16 ),
      ErrorState   => 'got_error',
      FlushedState => 'got_flush',
    );

  $heap->{test_six} = 1;
  $heap->{readwrite_wheel_id} = $heap->{wheel}->ID;

  $heap->{flush_count} = 0;
  $heap->{put_count}   = 0;

  $kernel->yield( 'got_alarm' );
}

sub client_tcp_got_alarm {
  my ($kernel, $heap, $line) = @_[KERNEL, HEAP, ARG0];

  $heap->{wheel}->put( '0123456789ABCDEF0123456789ABCDEF' );

  $heap->{put_count} += 2;
  if ($heap->{put_count} < $max_send_count) {
    $kernel->delay( got_alarm => 1 );
  }
}

sub client_tcp_got_error {
  my ($heap, $operation, $errnum, $errstr, $wheel_id) = @_[HEAP, ARG0..ARG3];

  if ($wheel_id == $heap->{socketfactory_wheel_id}) {
    $heap->{test_three} = 0;
  }

  if ($wheel_id == $heap->{readwrite_wheel_id}) {
    $heap->{test_six} = 0;
  }

  delete $heap->{wheel};
  warn "$operation error $errnum: $errstr";
}

sub client_tcp_got_flush {
  $_[HEAP]->{flush_count}++;
  # Delays destruction until all data is out.
  delete $_[HEAP]->{wheel} if $_[HEAP]->{put_count} >= $max_send_count;
}

###############################################################################
# Start the TCP server and client.

POE::Component::Server::TCP->new
  ( Port     => $tcp_server_port,
    Acceptor => sub { &sss_new(@_[ARG0..ARG2]);
                      # This next badness is just for testing.
                      my $sockname = $_[HEAP]->{listener}->getsockname();
                      delete $_[HEAP]->{listener};

                      my ($port, $addr) = sockaddr_in($sockname);
                      $addr = inet_ntoa($addr);
                      &ok_if( 7,
                              ($addr eq '0.0.0.0') &&
                              ($port == $tcp_server_port)
                            )
                    },
  );

POE::Session->create
  ( inline_states =>
    { _start     => \&client_tcp_start,
      _stop      => \&client_tcp_stop,
      got_server => \&client_tcp_connected,
      got_error  => \&client_tcp_got_error,
      got_flush  => \&client_tcp_got_flush,
      got_alarm  => \&client_tcp_got_alarm,
    }
  );

### main loop

$poe_kernel->run();

&ok(8);
&results;

exit;
