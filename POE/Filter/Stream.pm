# $Id: Stream.pm,v 1.9 2000/12/26 06:14:12 rcaputo Exp $

package POE::Filter::Stream;

use strict;

#------------------------------------------------------------------------------

sub new {
  my $type = shift;
  my $t='';
  my $self = bless \$t, $type;
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
  [ @$chunks ];
}

#------------------------------------------------------------------------------

sub get_pending {} #we don't keep any state

###############################################################################
1;

__END__

=head1 NAME

POE::Filter::Stream - pass through data unchanged (a do-nothing filter)

=head1 SYNOPSIS

  $filter = POE::Filter::Stream->new();
  $arrayref_of_logical_chunks =
    $filter->get($arrayref_of_raw_chunks_from_driver);
  $arrayref_of_streamable_chunks_for_driver =
     $filter->put($arrayref_of_logical_chunks);

=head1 DESCRIPTION

This filter passes data through unchanged.

=head1 SEE ALSO

POE::Filter.

The SEE ALSO section in L<POE> contains a table of contents covering
the entire POE distribution.

=head1 BUGS

Oh, probably some.

=head1 AUTHORS & COPYRIGHTS

Please see L<POE> for more information about authors and contributors.

=cut
