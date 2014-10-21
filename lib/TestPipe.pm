# Make pipes in a portable way.
# $Id: TestPipe.pm,v 1.4 2000/08/17 05:16:23 rcaputo Exp $

package TestPipe;
use strict;
use Symbol qw(gensym);
use IO::Socket;

sub DEBUG () { 0 }
sub RUNNING_IN_HELL () { $^O eq 'MSWin32' }

sub new {
  my $type = shift;

  # Every one of these pipes has two ends, and the ends have read and
  # write handles.  These are bidirectional.
  my $a_read  = gensym();
  my $a_write = gensym();
  my $b_read  = gensym();
  my $b_write = gensym();

  # Try a pair of pipes.  Avoid doing this on systems that don't
  # support non-blocking pipes.
  unless (RUNNING_IN_HELL) {
    eval {
      pipe($a_read, $b_write) or die "pipe failed";
      pipe($b_read, $a_write) or die "pipe failed";
    };

    unless (length $@) {
      DEBUG and do {
        warn "using a pair of pipes\n";
        warn "ar($a_read) aw($a_write) br($b_read) bw($b_write)\n";
      };
      return($a_read, $a_write, $b_read, $b_write);
    }
  }

  # Try traditional INET domain sockets.
  my $old_sig_alarm = $SIG{ALRM};
  eval {
    local $SIG{ALRM} = sub { die "deadlock" };
    eval 'alarm(5)' unless RUNNING_IN_HELL;

    my $acceptor = IO::Socket::INET->new
      ( LocalAddr => '127.0.0.1',
        LocalPort => 31415,
        Listen    => 5,
        Reuse     => 'yes',
      );

    $a_read = IO::Socket::INET->new
      ( PeerAddr  => '127.0.0.1',
        PeerPort  => 31415,
        Reuse     => 'yes',
      );

    $b_read = $acceptor->accept() or die "accept";

    $a_write = $a_read;
    $b_write = $b_read;
  };
  eval 'alarm(0)' unless RUNNING_IN_HELL;
  $SIG{ALRM} = $old_sig_alarm;

  unless (length $@) {
    DEBUG and do {
      warn "using a plain INET socket\n";
      warn "ar($a_read) aw($a_write) br($b_read) bw($b_write)\n";
    };
    return($a_read, $a_write, $b_read, $b_write);
  }

  # There's nothing left to try.
  DEBUG and warn "nothing worked\n";
  return(undef, undef, undef, undef);
}

1;

