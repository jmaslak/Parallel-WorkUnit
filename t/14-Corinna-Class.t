#!/usr/bin/perl -T
# Yes, we want to make sure things work in taint mode

#
# Copyright (C) 2023 Joelle Maslak
# All Rights Reserved - See License
#

# This tests that if a OBJECT type is returned, it is handled
# gracefully.

use strict;
use warnings;
use autodie;

use Carp;
use Test2::V0;
use Feature::Compat::Class;

# Set Timeout
local $SIG{ALRM} = sub { die "timeout\n"; };
alarm 120;    # It would be nice if we did this a better way, since
              # strictly speaking, 120 seconds isn't necessarily
              # indicative of failure if running this on a VERY
              # slow machine.
              # But hopefully nobody has that slow of a machine!

# Instantiate the object
use Parallel::WorkUnit;
my $wu = Parallel::WorkUnit->new();
ok( defined($wu), "Constructer returned object" );

class foobar {
    field $x : param;
    method baz { return 1 }
}

my $x = foobar->new( x => 1 );

my $result;
SKIP: {
    skip( "Old version of Perl doesn't have Corrina", 1 )
      unless ( $^V and $^V ge v5.38.0 );

    $wu->async( sub { $x }, sub { $result = shift; } );

    like(
        dies { $wu->waitall(); },
        qr/Can't store OBJECT items/,
        'Child throws a storable error for Corinna class objects',
    );
}

done_testing();

