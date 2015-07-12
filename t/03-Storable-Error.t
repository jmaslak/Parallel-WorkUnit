#!/usr/bin/perl -T
# Yes, we want to make sure things work in taint mode

#
# Copyright (C) 2015 Joel Maslak
# All Rights Reserved - See License
#

# This tests a bug reported by SREZIC - when the child returned with
# something Storable couldn't handle, this very ungracefully failed.

use strict;
use warnings;
use autodie;

use Carp;
use Test::More tests => 4;
use Test::Exception;

# Set Timeout
local $SIG{ALRM} = sub { die "timeout\n"; };
alarm 120; # It would be nice if we did this a better way, since
           # strictly speaking, 120 seconds isn't necessarily
           # indicative of failure if running this on a VERY
           # slow machine.
           # But hopefully nobody has that slow of a machine!

# Instantiate the object
require_ok('Parallel::WorkUnit');
my $wu = Parallel::WorkUnit->new();
ok(defined($wu), "Constructer returned object");

SKIP: {
    skip("Old version of storable is okay with regex", 1)
        unless ($^V and $^V ge v5.10.0);

    my $result;
    $wu->async(
        sub { qr{xxx} },
        sub { $result = shift; }
    );

    dies_ok { $wu->waitall(); } 'Child throws a storable error for regex';
}

my $result;
$wu->async(
    sub { sub { 1; } },
    sub { $result = shift; }
);

dies_ok { $wu->waitall(); } 'Child throws a storable error for code';


