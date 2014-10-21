# $Id: TCP.pm,v 1.7 2001/04/03 17:20:31 rcaputo Exp $

package POE::Component::Server::TCP;

use strict;

use Carp qw(carp croak);
use Socket qw(INADDR_ANY);
use vars qw($VERSION);

$VERSION = 1.01;

# Explicit use to import the parameter constants.
use POE::Session;
use POE::Wheel::SocketFactory;

# Create the server.  This is just a handy way to encapsulate
# POE::Session->create().  Because the states are so small, it uses
# real inline coderefs.

sub new {
  my $type = shift;

  # Helper so we don't have to type it all day.  $mi is a name I call
  # myself.
  my $mi = $type . '->new()';

  # If they give us lemons, tell them to make their own damn
  # lemonade.
  croak "$mi requires an even number of parameters" if (@_ & 1);
  my %param = @_;

  # Validate what we're given.
  croak "$mi needs a Port parameter" unless exists $param{Port};
  croak "$mi needs an Acceptor parameter" unless exists $param{Acceptor};

  # Extract parameters.
  my $alias           = delete $param{Alias};
  my $address         = delete $param{Address};
  my $port            = delete $param{Port};
  my $accept_callback = delete $param{Acceptor};
  my $error_callback  = delete $param{Error};

  # Defaults.
  $address = INADDR_ANY unless defined $address;

  # Complain about strange things we're given.
  foreach (sort keys %param) {
    carp "$mi doesn't recognize \"$_\" as a parameter";
  }

  # Create the session, at long last.

  POE::Session->new

    # The POE::Session has been set up.  Create a listening socket
    # factory which will call back $callback with accepted client
    # sockets.
    ( _start =>
      sub {
        if (defined $alias) {
          $_[HEAP]->{alias} = $alias;
          $_[KERNEL]->alias_set( $alias );
        }

        $_[HEAP]->{listener} = POE::Wheel::SocketFactory->new
          ( BindPort     => $port,
            BindAddress  => $address,
            Reuse        => 'yes',
            SuccessState => 'got_connection',
            FailureState => 'got_error',
          );
      },

      # Catch an error.
      got_error => ( defined($error_callback)
                     ? $error_callback
                     : \&default_error_handler
                   ),

      # We accepted a connection.  Do something with it.
      got_connection => $accept_callback,

      # Shut down.
      shutdown => sub {
        delete $_[HEAP]->{listener};
        $_[KERNEL]->alias_remove( $_[HEAP]->{alias} )
          if defined $_[HEAP]->{alias};
      },
    );

  # Return undef so nobody can use the POE::Session reference.  This
  # isn't very friendly, but it saves grief later.
  undef;
}

# The default error handler logs to STDERR and shuts down the server.
sub default_error_handler {
  warn( 'Server ', $_[SESSION]->ID,
        " got $_[ARG0] error $_[ARG1] ($_[ARG2])\n"
      );
  delete $_[HEAP]->{listener};
}

1;

__END__

=head1 NAME

POE::Component::Server::TCP - a simplified TCP server

=head1 SYNOPSIS

  use POE;

  sub accept_handler {
    my ($socket, $remote_address, $remote_port) = @_[ARG0, ARG1, ARG2];
    # code goes here to handle the accepted socket
  }

  sub error_handler {
    my ($op, $errnum, $errstr) = @_[ARG0, ARG1, ARG2];
    warn "server encountered $op error $errnum: $errstr";
    # possibly shut down the server
  }

  POE::Component::Server::TCP->new
    ( Port     => $bind_port,
      Address  => $bind_address,    # Optional.
      Acceptor => \&accept_handler,
      Error    => \&error_handler,  # Optional.
    );

=head1 DESCRIPTION

The TCP server component hides the steps needed to create a server
using Wheel::SocketFactory.  The steps aren't many, but they're still
repetitive and thus boring.

POE::Component::Server::TCP helps out by supplying a default error
handler.  This handler will write an error message on STDERR and shut
the server down.

The TCP server component takes three named arguments.  It's expected
to accept other parameters as it evolves.

=over 2

=item Address

Address is the optional interface address the listening socket will be
bound to.  When omitted, it defaults to INADDR_ANY.

  Address => '127.0.0.1'

It's passed directly to SocketFactory's BindAddress parameter, and so
it can be in whatever form SocketFactory supports.  At the time of
this writing, that's a dotted quad, a host name, or a packed Internet
address.

=item Alias

Alias is an optional name by which this server may be referenced.
It's used to pass events to a TCP server from other sessions.

  Alias => 'chargen'

Later on, the 'chargen' service can be shut down with:

  $kernel->post( chargen => 'shutdown' );

=item Port

Port is the port the listening socket will be bound to.

  Port => 30023

=item Acceptor

Acceptor is a coderef which will be called to handle accepted sockets.
The coderef is used as POE::Wheel::SocketFactory's SuccessState, so it
accepts the same parameters.

  Acceptor => \&success_state

=item Error

Error is an optional coderef which will be called to handle server
socket errors.  The coderef is used as POE::Wheel::SocketFactory's
FailureState, so it accepts the same parameters.  If it is omitted, a
default error handler will be provided.  The default handler will log
the error to STDERR and shut down the server.

=back

=head1 EVENTS

It's possible to manipulate a TCP server component from some other
session.  This is useful for shutting them down, and little else so
far.

=over 2

=item shutdown

Shuts down the TCP server.  This entails destroying the SocketFactory
that's listening for connections and removing the TCP server's alias,
if one is set.

=back

=head1 SEE ALSO

POE::Wheel::SocketFactory

=head1 BUGS

POE::Component::Server::TCP currently does not accept many of the
options that POE::Wheel::SocketFactory does, but it can be expanded
easily to do so.

=head1 AUTHORS & COPYRIGHTS

POE::Component::Server::TCP is Copyright 2000 by Rocco Caputo.  All
rights are reserved.  POE::Component::Server::TCP is free software,
and it may be redistributed and/or modified under the same terms as
Perl itself.

=cut
