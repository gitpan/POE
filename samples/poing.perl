#!/usr/bin/perl -w -I..
# $Id: poing.perl,v 1.9 1999/11/26 16:39:48 rcaputo Exp $

# Whole huge chunks of poing.perl have been "adapted" from Net::Ping.

use strict;
use POE;

#------------------------------------------------------------------------------

package POE::Component::Pinger;

use strict;
use Symbol qw(gensym);
use POE::Session;
use Socket;
use Time::HiRes qw(time);

sub _start {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  $heap->{pid}       = $$ & 0xffff;
  $heap->{seq}       = 0;
  $heap->{data}      = '';
  $heap->{data_size} = length($heap->{data});

  die "icmp ping requires root privilege" if ($> and $^O ne 'VMS');

  my $protocol = (getprotobyname('icmp'))[2]
    or die "Can't get icmp protocol by name: $!";

  my $socket = gensym();
  socket($socket, PF_INET, SOCK_RAW, $protocol)
    or die "Can't create icmp socket: $!";

  $heap->{socket} = $socket;
  $kernel->alias_set('pinger');
  $kernel->select_read($socket, 'got_pong');
}
                                        # ICMP echo types
sub ICMP_ECHOREPLY () { 0 }
sub ICMP_ECHO      () { 8 }
sub ICMP_STRUCT    () { 'C2 S3 A' }
sub ICMP_SUBCODE   () { 0 }
sub ICMP_FLAGS     () { 0 }
sub ICMP_PORT      () { 0 }

sub ping_clear {
  my ($heap, $address) = @_[HEAP, ARG0];
  delete $heap->{waiting}->{$address};
}

sub ping {
  my ($heap, $sender, $address, $event) = @_[HEAP, SENDER, ARG0, ARG1];

  $heap->{seq} = ($heap->{seq} + 1) % 65536;
  my $checksum = 0;
  my $msg = pack( ICMP_STRUCT . $heap->{data_size},
                  ICMP_ECHO, ICMP_SUBCODE,
                  $checksum, $heap->{pid}, $heap->{seq}, $heap->{data}
                );

  $checksum = &net_checksum($msg);

  $msg = pack( ICMP_STRUCT . $heap->{data_size},
               ICMP_ECHO, ICMP_SUBCODE,
               $checksum, $heap->{pid}, $heap->{seq}, $heap->{data}
             );

  $heap->{message_length} = length($msg);
  my $saddr = sockaddr_in(ICMP_PORT, $address);

  $heap->{waiting}->{$address} = [ $heap->{seq}, $sender, $event, time() ];

  send($heap->{socket}, $msg, ICMP_FLAGS, $saddr);
}

sub got_pong {
  my ($kernel, $heap, $socket) = @_[KERNEL, HEAP, ARG0];

  my $recv_message = '';
  my $from_saddr = recv($socket, $recv_message, 1500, ICMP_FLAGS);

  return unless (defined $heap->{message_length});

  my ($from_port, $from_ip) = sockaddr_in($from_saddr);
  my ( $from_type, $from_subcode,
       $from_checksum, $from_pid, $from_seq, $from_message
     )  = unpack( ICMP_STRUCT . $heap->{data_size},
                  substr( $recv_message,
                          length($recv_message) - $heap->{message_length},
                          $heap->{message_length}
                        )
                );

  if ($from_type == ICMP_ECHOREPLY) {
    if (exists $heap->{waiting}->{$from_ip}) {
      my ($send_seq, $send_session, $send_event, $send_time) =
        @{$heap->{waiting}->{$from_ip}};
      if ($from_seq == $send_seq) {
        delete $heap->{waiting}->{$from_ip};
        $kernel->call( $send_session, $send_event,
                       $from_ip, time() - $send_time
                     );
      }
    }
  }
}

sub net_checksum {
  my $msg = shift;
  my ($len_msg,       # Length of the message
      $num_short,     # The number of short words in the message
      $short,         # One short word
      $chk            # The checksum
     );

  $len_msg = length($msg);
  $num_short = int($len_msg / 2);
  $chk = 0;
  foreach $short (unpack("S$num_short", $msg)) {
    $chk += $short;
  }                                           # Add the odd byte in
  $chk += unpack("C", substr($msg, $len_msg - 1, 1)) if $len_msg % 2;
  $chk = ($chk >> 16) + ($chk & 0xffff);      # Fold high into low
  return(~(($chk >> 16) + $chk) & 0xffff);    # Again and complement
}

###############################################################################

package main;
use strict;
use POE qw(Wheel::ReadWrite Driver::SysRW Filter::HTTPD Wheel::SocketFactory);
use Socket;

#------------------------------------------------------------------------------

sub HOST_NAME     () { 0 }
sub HOST_RESPONSE () { 1 }
sub HOST_TICKER   () { 2 }

my $cols = $ENV{COLS} - 3;
my $rows = $ENV{ROWS};

sub host_sort {
  if ($a =~ /^\d+\.\d+\.\d+\.\d+$/) {
    if ($b =~ /^\d+\.\d+\.\d+\.\d+$/) {
      # address / address compare
      return ( join('.', map { sprintf "%03d", $_ } split(/\./, $a)) cmp
               join('.', map { sprintf "%03d", $_ } split(/\./, $b))
             );
    }
    else {
      return -1; # addresses come before hosts
    }
  }
  else {
    if ($b =~ /^\d+\.\d+\.\d+\.\d+$/) {
      return 1; # addresses come before hosts
    }
    else {
      # host / host compare
      return ( join('.', reverse(split(/\./, lc($a)))) cmp
               join('.', reverse(split(/\./, lc($b))))
             );
    }
  }
}

sub pong_start {
  my ($kernel, $heap, $timeout, $hosts) = @_[KERNEL, HEAP, ARG0, ARG1];

  print "Resolving hosts...\n";

  $heap->{timeout} = $timeout;

  $heap->{hosts} = [];
  $heap->{host_rec} = {};
  foreach my $host (sort host_sort @$hosts) {
    my $ip = inet_aton($host);
    if (defined $ip) {
      push @{$heap->{hosts}}, $ip;
      $heap->{host_rec}->{$ip} = [ $host,
                                   undef,
                                   ' ' x ($cols - length($host))
                                 ];
    }
  }

  my $display = "\e[2J\e[0;0H" .
    (($heap->{count} & 1) ? "\e[7m[" : '[') . "poing]\e[0m " .
    scalar(localtime(time())) .
    " (resolution is ~" . ($heap->{timeout} / 10) . "s)\n\n";

  foreach my $host (@{$heap->{hosts}}) {
    my $show_rec = $heap->{host_rec}->{$host};
    $display .= ( "\e[0;1m" . $show_rec->[HOST_NAME] .
                  "\e[0m"   . ':' . "\n"
                );
  }

  print $display;

  $kernel->yield('ping_sweep');
}

sub pong_sweep {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  $heap->{count}++;

  my $display = "\e[0;0H" .
    (($heap->{count} & 1) ? "\e[7m[" : '[') . "poing]\e[0m " .
    scalar(localtime(time())) .
    " (resolution is ~" . ($heap->{timeout} / 10) . "s)\n\n";

  foreach my $host (@{$heap->{hosts}}) {
    $kernel->post('pinger', 'ping', $host, 'ping_reply');

    substr($heap->{host_rec}->{$host}->[HOST_TICKER], 0, 1) = '';

    my $relative_response =
      ( (defined $heap->{host_rec}->{$host}->[HOST_RESPONSE])
        ? int( ( $heap->{host_rec}->{$host}->[HOST_RESPONSE] / $heap->{timeout}
               ) * 10
             )
        : ( 9 )
      );

    # Clip the response to a single digit, please.
    $relative_response = ( ($relative_response > 9)
                           ? 9
                           : ( $relative_response < 0
                               ? 0
                               : $relative_response
                             )
                         );

    $heap->{host_rec}->{$host}->[HOST_TICKER] .= $relative_response;

    my $show = $heap->{host_rec}->{$host};
    my $show_health = $show->[HOST_TICKER];

    $show_health =~ s{(^|[^98])([98])}{$1\001$2}g; # red
    $show_health =~ s{(^|[^76])([76])}{$1\002$2}g; # magenta
    $show_health =~ s{(^|[^54])([54])}{$1\003$2}g; # yellow
    $show_health =~ s{(^|[^32])([32])}{$1\004$2}g; # cyan
    $show_health =~ s{(^|[^10])([10])}{$1\005$2}g; # green

    $show_health =~ s/\001/\e\[31m/g; # red
    $show_health =~ s/\002/\e\[35m/g; # magenta
    $show_health =~ s/\003/\e\[33m/g; # yellow
    $show_health =~ s/\004/\e\[36m/g; # cyan
    $show_health =~ s/\005/\e\[32m/g; # reen

    $display .= ( "\e[" . (length($show->[HOST_NAME]) + 2) . "C" .
                  "\e[1m"   . $show_health .
                  "\e[0m\n"
                );

    $heap->{host_rec}->{$host}->[HOST_RESPONSE] = undef;
  }

  print $display;

  # Hack to specify the maximum run time, in hours.
  if ($ARGV[0] =~ /^\d+$/) {
    if ((time - $^T) < ($ARGV[0] * 3600)) {
      $kernel->delay('ping_sweep', $heap->{timeout});
    }
    else {
      $SIG{ALRM} = sub { die "<<< Alarm caught >>>\n"; };
      alarm(20);
    }
  }
}

sub pong_stop {
  my ($kernel, $heap) = @_[KERNEL, HEAP];
  foreach my $host (@{$heap->{hosts}}) {
    $kernel->post('pinger', 'ping_clear', $host);
  }
}

sub pong_reply {
  my ($heap, $address, $time) = @_[HEAP, ARG0, ARG1];
  $heap->{host_rec}->{$address}->[HOST_RESPONSE] = $time;
}

#------------------------------------------------------------------------------

print "Loading hosts...\n";

my (@hosts_to_ping, %hosts_seen);
while (<DATA>) {
  s/^\s+//;
  s/\s+$//;
  s/\s*\#.*//;
  next unless length;
  $_ = lc($_);
  next if (exists $hosts_seen{$_});
  $hosts_seen{$_}++;
  push @hosts_to_ping, $_;
}

#------------------------------------------------------------------------------

create POE::Session
  ( package_states =>
    { 'POE::Component::Pinger' => [ qw(_start ping got_pong ping_clear) ],
    },
  );

create POE::Session
  ( inline_states =>
    { _start     => \&pong_start,
      _stop      => \&pong_stop,
      ping_reply => \&pong_reply,
      ping_sweep => \&pong_sweep,
    },
    args => [ 2, \@hosts_to_ping ],
  );

$poe_kernel->run();

exit;

__END__

# Internal hosts

10.0.0.100
10.0.0.9
rocco
unix

# ISP hosts

100baset.netrus.net
netrus.net
pm3-miami-fl-3.netrus.net

# ISP gateways

atm-7513-1-s0-0-0-10.cwi.net
sl-gw1-orl-5-0-0-TS12-T1.sprintlink.net

# Frequent sites

altavista.com
google.com
irc.cs.cmu.edu
nerdsholm.boutell.com
prometheus.frii.com
www.slashdot.org
www.sluggy.com

# IRC Hops

irc-w.frontiernet.net
irc.best.net
ircd-w.concentric.net
irc.exodus.net

# Internet routers

107.ATM6-0.TR1.EWR1.ALTER.NET
126.ATM2-0.XR1.SFO4.ALTER.NET
189.ATM9-0-0.GW2.NYC4.ALTER.NET
191.ATM2-0.TR1.SCL1.ALTER.NET
197.ATM7-0.XR1.NYC4.ALTER.NET
IPGlobal-gw.customer.alter.net
NORDUnet-gw.Teleglobe.net
Opentransit-fr-cy.cytanet.net
Serial2-1-1.GW2.SFO4.ALTER.NET
Telecom-Finland-gw.customer.ALTER.NET
bb2.mae-w.home.net
car1-ams-fe6-1.global-one.nl
car2-ams-fe0-0.global-one.nl
ci113.17.cambridge1.uk.psi.net
core7-serial5-1-0.SanFrancisco.cw.net
cty1-core.pos0-0-0.swip.net
cty2-core.merlin2-0.swip.net
cty21.fastethernet0-0.swip.net
cust-gw.Teleglobe.net
deshaw-gw.customer.ALTER.NET
ebt-P1-0-gsr01.rjo.embratel.net.br
fw.zaragoza.G-Matrix.net
gip-amsterdam-1-atm6-0-0-632-atm.gip.net
gip-arch-1-atm2-0-0-232-atm.gip.net
icm-bb3-pen.icp.net
insnet-gw.customer.ALTER.NET
mae-west5-nap.SanFrancisco.cw.net
paix-gw.napa.paradox.net.au
pao-iad-oc3.pao.above.net
sw.ext.sc.psi.net
vogon1-gw.swip.net
mae-east2.iconnet.net
sl-gw1-orl-5-0-0-TS12-T1.sprintlink.net
sl-bb11-orl-0-2.sprintlink.net
sl-bb10-rly-1-0.sprintlink.net
sl-bb10-rly-9-0.sprintlink.net
sl-bb4-dc-0-0-0.sprintlink.net
sl-e2-mae-0-1-0.sprintlink.net
