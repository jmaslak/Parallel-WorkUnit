#!/usr/bin/perl -T
# Yes, we want to make sure things work in taint mode

#
# Copyright (C) 2015,2018 Joelle Maslak
# All Rights Reserved - See License
#

# This tests that Storable can handle storing coderefs

use strict;
use warnings;
use autodie;

use Carp;
use Storable;
use Test::More tests => 4;
use Test::Exception;

# Set Timeout
local $SIG{ALRM} = sub { die "timeout\n"; };
alarm 120;    # It would be nice if we did this a better way, since
              # strictly speaking, 120 seconds isn't necessarily
              # indicative of failure if running this on a VERY
              # slow machine.
              # But hopefully nobody has that slow of a machine!

# Instantiate the object
require_ok('Parallel::WorkUnit');
my $wu = Parallel::WorkUnit->new();
ok( defined($wu), "Constructer returned object" );

my $result;
SKIP: {
    skip( "Storable >= 2.05 is required for coderefs", 1 )
      unless ( $Storable::VERSION gt 2.05 );

    $wu->allow_coderefs(1);

    $wu->async(
        sub {
            return sub { return 12; }
        },
        sub {
            $result = shift;
        }
    );

    lives_ok { $wu->waitall(); } 'Child does not throw exception';

    is($result->(), 12, 'Sub returned from child executed properly');
}

