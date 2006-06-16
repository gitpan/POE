#!/usr/bin/perl -w
# $Id: 05_map.t 1971 2006-05-30 20:32:30Z bsmith $
# Exercises Filter::Map without POE

use strict;
use lib qw(./mylib ../mylib);

use POE::Filter::Map;
use Test::More tests => 17; # FILL ME IN

# Test erroneous new() args
test_new("No Args");
test_new("Non code CODE ref", Code => [ ]);
test_new("Single Get ref", Get => sub { });
test_new("Single Put ref", Put => sub { });
test_new("Non CODE Get",   Get => [ ], Put => sub { });
test_new("Non CODE Put",   Get => sub { }, Put => [ ]);

sub test_new {
    my $name = shift;
    my @args = @_;
    my $filter;
    eval { $filter = POE::Filter::Map->new(@args); };
    ok(defined $@, $name);
}

my $filter;
# Test actual mapping of Get, Put, and Code
$filter = POE::Filter::Map->new( Get => sub { uc }, Put => sub { lc } );
is_deeply($filter->put([qw/A B C/]), [qw/a b c/], "Test Put");
is_deeply($filter->get([qw/a b c/]), [qw/A B C/], "Test Get");

$filter = POE::Filter::Map->new(Code => sub { uc });
is_deeply($filter->put([qw/a b c/]), [qw/A B C/], "Test Put (as Code)");
is_deeply($filter->get([qw/a b c/]), [qw/A B C/], "Test Get (as Code)");


$filter = POE::Filter::Map->new( Get => sub { 'GET' }, Put => sub { 'PUT' } );

# Test erroneous modification
test_modify("Modify Get not CODE ref",  $filter, Get => [ ]);
test_modify("Modify Put not CODE ref",  $filter, Put => [ ]);
test_modify("Modify Code not CODE ref", $filter, Code => [ ]);

sub test_modify {
   my ($name, $filter, @args) = @_;
   eval { $filter->modify(@args); };
   ok(defined $@, $name);
}

$filter->modify(Get => sub { 'NGet' });
is_deeply($filter->get(['a']), ['NGet'], "Modify Get");

$filter->modify(Put => sub { 'NPut' });
is_deeply($filter->put(['a']), ['NPut'], "Modify Put");

$filter->modify(Code => sub { 'NCode' });
is_deeply($filter->put(['a']), ['NCode'], "Modify Code ");
is_deeply($filter->get(['a']), ['NCode'], "Modify Code ");
