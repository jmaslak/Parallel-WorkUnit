
# Copyright (C) 2015-2019 Joelle Maslak
# All Rights Reserved - See License
#

package Parallel::WorkUnit::Procedural;

use v5.8;

# ABSTRACT: Provide procedural paradigm forking with ability to pass back data

use strict;
use warnings;
use autodie;

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(
  async asyncs proc_count proc_wait queue start waitall waitone WorkUnit
);
our %EXPORT_TAGS = ( all => [@EXPORT_OK] );

use Carp;
use Parallel::WorkUnit;

use namespace::autoclean;

=head1 SYNOPSIS

  #
  # Procedural Interface
  #
  use Parallel::WorkUnit::Procedural qw(:all); # Export all symbols

  async sub { ... }, \&callback;
  waitall;


  #
  # Limiting Maximum Parallelization
  #
  WorkUnit->max_children(5);
  queue sub { ... }, \&callback;
  waitall;


  #
  # Ordered Responses
  #
  async sub { ... };

  @results = waitall;

  #
  # Spawning off X number of workers
  # (Ordered Response paradigm shown with 10 children)
  #
  asyncs( 10, sub { ... } );

  @results = waitall;


  #
  # AnyEvent Interface
  #
  use AnyEvent;

  WorkUnit->use_anyevent(1);
  async sub { ... }, \&callback;
  waitall;  # Not strictly necessary

  #
  # Just spawn something into another process, don't capture return
  # values, don't allow waiting on process, etc.
  #
  start { ... };

=head1 DESCRIPTION

This provides a simple procedural instance to L<Parallel::WorkUnit> where
it is not important to modify attributes of the global Parallel::WorkUnit
singleton used by this module.

While the underlying singleton is exposed (via the C<WorkUnit> subroutine),
it is highly recommended that users not use this directly, as unexpected
interactions may occur (it is a global singleton, after all!).

Please read the documentation on L<Parallel::WorkUnit> for detailed information
about this module.

This module was added to the Parallel-WorkUnit distribution in 1.191810.

=cut

=func WorkUnit

Returns the singleton Parallel::WorkUnit used by this module.  This can be
used to access attributes such as C<max_children> and C<use_anyevent>.

=cut

my $wu = Parallel::WorkUnit->new();

sub WorkUnit() {
    $wu = Parallel::WorkUnit->new() if !defined($wu);
    return $wu;
}

=func async { ... }, \&callback

  async sub { return 1 } \&callback;

  # To get back results in "ordered" return mode
  async sub { return 1 };
  @results = waitall;

This executes C<Parallel::WorkUnit->async()>

=cut

sub async(&;&) { return WorkUnit->async(@_) }

=func asyncs( $children, sub { ... }, \&callback )

Executes C<Parallel::WorkUnit->asyncs() }

=cut

sub asyncs { return WorkUnit->asyncs(@_) }

=func waitall

Executes C<Parallel::WorkUnit->waitall()>

=cut

sub waitall() { return WorkUnit->waitall() }

=func waitone

Executes C<Parallel::WorkUnit->waitone()>

=cut

sub waitone { return WorkUnit->waitone(@_) }

=func proc_wait($pid)

Executes C<Parallel::WorkUnit->wait()>

=cut

sub proc_wait { return WorkUnit->wait(@_) }

=func proc_count()

Executes C<Parallel::WorkUnit->count()>

=cut

sub proc_count() { return WorkUnit->count() }

=func queue sub { ... }, \&callback

Executes C<Parallel::WorkUnit->queue()>

=cut

sub queue { return WorkUnit->queue(@_) }

=func start { ... };

This executes C<Parallel::WorkUnit->start()>

=cut

sub start(&) { return WorkUnit->start(@_) }

1;

