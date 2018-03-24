
# Copyright (C) 2015-2018 Joelle Maslak
# All Rights Reserved - See License
#

package Parallel::WorkUnit;

use v5.8;

# ABSTRACT: Provide multi-paradigm forking with ability to pass back data

use strict;
use warnings;
use autodie;

use Scalar::Util qw(blessed reftype weaken);
use Try::Tiny;

#
# Setting up threads, on Win32, if appropriate
#

my $use_anyevent_pipe;
## no critic (BuiltinFunctions::ProhibitStringyEval)
$use_anyevent_pipe = eval 'use AnyEvent::Util qw//; 1' if $^O eq 'MSWin32';
## critic

my $use_threads;
## no critic (BuiltinFunctions::ProhibitStringyEval)
$use_threads = eval 'use threads qw//; 1' if ( ( $^O eq 'MSWin32' ) && ( !$use_anyevent_pipe ) );
## critic
if ($use_threads) { eval 'use Thread::Queue;'; }

my $use_thread_queue = ( $use_threads && ( !$use_anyevent_pipe ) );

use Carp;

use overload;
use IO::Handle;
use IO::Pipe;
use IO::Select;
use Moose;
use Moose::Util::TypeConstraints;
use POSIX ':sys_wait_h';
use Storable;

use namespace::autoclean;

=head1 SYNOPSIS

  #
  # Standard Interface
  #
  my $wu = Parallel::WorkUnit->new();
  $wu->async( sub { ... }, \&callback );

  $wu->waitall();


  #
  # Limiting Maximum Parallelization
  #
  $wu->max_children(5);
  $wu->queue( sub { ... }, \&callback );
  $wu->waitall();


  #
  # Ordered Responses
  #
  use AnyEvent;
  my $wu = Parallel::WorkUnit->new();
  $wu->async( sub { ... } );

  @results = $wu->waitall();


  #
  # AnyEvent Interface
  #
  use AnyEvent;
  my $wu = Parallel::WorkUnit->new();

  $wu->use_anyevent(1);
  $wu->async( sub { ... }, \&callback );
  $wu->waitall();  # Not strictly necessary

=head1 DESCRIPTION

This is a very simple forking implementation of parallelism, with the
ability to pass data back from the asyncronous child process in a
relatively efficient way (with the limitation of using a pipe to pass
the information, serialized, back).  It was designed to be very simple
for a developer to use, with the ability to pass reasonably large amounts
of data back to the parent process.

This module is also designed to work with AnyEvent when desired.

There are many other Parallel::* applications in CPAN - it would be worth
any developer's time to look through those and choose the best one.

=cut

subtype 'Parallel::WorkUnit::PositiveInt', as 'Int',
  where { $_ > 0 },
  message { "The number you provided, $_, was not a positive number" };

subtype 'Parallel::WorkUnit::NonNegativeInt', as 'Int',
  where { $_ >= 0 },
  message { "The number you provided, $_, was not a non-negative number" };

=attr use_anyevent

  $wu->use_anyevent(1);

If set to a value that is true, creates AnyEvent watchers for each
asyncronous or queued job.  The equivilent of an C<AnyEvent> condition
variable C<recv()>, used when all processes finish executing, is the
C<waitall()> method.  However, the processes are integrated into a
standard C<AnyEvent> loop, so it isn't strictly necessary to call C<waitall()>.
In addition, a call to C<waitall()> will execute other processes in
the C<AnyEvent> event loop.

The default value is false.

=cut

has use_anyevent => (
    is      => 'rw',
    isa     => 'Bool',
    trigger => \&_set_anyevent,
);

has _cv => (
    is  => 'rw',
    isa => 'Maybe[AnyEvent::CondVar]',
);

has _last_error => (
    is  => 'rw',
    isa => 'Maybe[Str]',
);

has _ordered_count => (
    is       => 'rw',
    isa      => 'Parallel::WorkUnit::NonNegativeInt',
    init_arg => undef,
    default  => 0,
);

has _ordered_responses => (
    is       => 'rw',
    isa      => 'ArrayRef',
    init_arg => undef,
    default  => sub { [] },
);

=attr max_children

  $wu->max_children(5);
  $wu->max_children(undef);

  say "Max number of children: " . $wu->max_children();

If set to a value other than zero or undef, limits the number of outstanding
queue children (created by the C<queue()> method) that can be executing
at any given time.

This defaults to 5.

This attribute does not impact the C<async()> method's ability to
create children, but these children will count against the limit used
by C<queue()>.

Calling without any parameters will return the number of children.

=cut

has 'max_children' => (
    is      => 'rw',
    isa     => 'Maybe[Parallel::WorkUnit::PositiveInt]',
    default => 5,
    trigger => sub { $_[0]->_start_queued_children() },
);

has '_subprocs' => (
    is       => 'rw',
    isa      => 'HashRef',
    init_arg => undef
);

# This only gets used on Win32.
has '_queue' => (
    is       => 'rw',
    init_arg => undef
);

# This only gets used on Win32
has '_count' => (
    is       => 'rw',
    isa      => 'Int',
    init_arg => undef,
    default  => 1
);

has '_parent_pid' => (
    is       => 'rw',
    isa      => 'Int',
    init_arg => undef,
    default  => $$,
);

# Children queued
has '_queued_children' => (
    is       => 'rw',
    isa      => 'ArrayRef[ArrayRef[Coderef]]',
    init_arg => undef,
    default  => sub { [] },
);

=method new

Create a new workunit class.  Optionally, takes a list that corresponds
to a hashref, in the form of key and value.  This accepts the key
C<max_children>, which, if present (and not undef) will limit the
number of spawned subprocesses that can be active when using the
C<queue()> method.  Defaults to 5.  See the C<max_children> method
for additional information.

=cut

sub BUILD {
    my $self = shift;

    $self->_subprocs( {} );

    if ($use_thread_queue) {
        $self->_queue( Thread::Queue->new() );
    }

    return;
}

=method async( sub { ... }, \&callback )

  $wu->async( sub { return 1 }, \&callback );

  # To get back results in "ordered" return mode
  $wu->async( sub { return 1 } );
  @results = $wu->waitall();

Spawns work on a new forked process.  The forked process inherits
all Perl state from the parent process, as would be expected with
a standard C<fork()> call.  The child shares nothing with the
parent, other than the return value of the work done.

The work is specified either as a subroutine reference or an
anonymous sub (C<sub { ... }>) and should return a scalar.  Any
scalar that L<Storable>'s C<freeze()> method can deal with
is acceptable (for instance, a hash reference or C<undef>).

The result is serialized and streamed back to the parent process
via a pipe.  The parent, in a C<waitall()> call, will call the
callback function (if provided) with the unserialized return value.

If a callback is not provided, the parent, in the C<waitall()> call,
will gather these results and return them as an ordered list.

In all modes, should the child process C<die>, the parent process
will also die (inside the C<waitall()> method).

The PID of the child is returned to the parent process when
this method is executed.

The C<max_children> attribute is not examined in this method - you
can spawn a new child regardless of the number of children already
spawned. However, you children started with this method still count
against the limit used by C<queue()>.

Note: on Windows with threaded Perl, if C<AnyEvent> is not installed,
threads instead of forks are used.  See C<thread> for the caveats
that apply.  The PID returned is instead a meaningless (outside of
this module) counter, not associated with any Windows thread identifier.

=cut

sub async {
    if ( $#_ < 1 ) { confess 'invalid call'; }
    my $self = shift;
    my $sub  = shift;

    # Test $sub to make sure it is a code ref or a sub ref
    if (! _codelike($sub)) {
        croak("Parameter to async() is not a code (or codelike) reference");
    }

    my $callback;
    if ( scalar(@_) == 0 ) {
        # No callback provided

        my $cbnum = $self->_ordered_count;
        $self->_ordered_count( $cbnum + 1 );

        # We create a callback that populates the ordered responses
        my $selfref = $self;
        weaken $selfref;
        $callback = sub {
            if (defined $selfref) { # Incase this went away
                @{ $selfref->_ordered_responses }[$cbnum] = shift;
            }
        };
    } elsif ( scalar(@_) == 1 ) {
        # Callback provided
        $callback = shift;
    } else {
        confess 'invalid call';
    }

    # If there are pending errors, throw that.
    if ( defined( $self->_last_error ) ) { die( $self->_last_error ); }

    my $pipe;
    if ($use_anyevent_pipe) {
        $pipe = [];
        (@$pipe) = AnyEvent::Util::portable_pipe();
    } else {
        $pipe = IO::Pipe->new();
    }

    my ( $pid, $thr );
    if ($use_threads) {
        $pid = $self->_count();
        $self->_count( $pid + 1 );

        $thr = threads->create( sub { $self->_child( $sub, $pipe, $pid ); } );
        if ( !defined($thr) ) { die "thread creation failed: $!"; }
    } else {
        $pid = fork();
    }

    if ($pid) {
        # We are in the parent process

        if ($use_anyevent_pipe) {
            $pipe = $pipe->[0];
        } else {
            $pipe->reader();
        }

        $self->_subprocs()->{$pid} = {
            fh       => $pipe,
            anyevent => undef,
            callback => $callback,
            caller   => [ caller() ],
            thread   => $thr
        };

        # Set up anyevent listener if appropriate
        if ( $self->use_anyevent() ) {
            $self->_add_anyevent_watcher($pid);
        }

        return $pid;

    } else {
        # We are in the child process

        return $self->_child( $sub, $pipe, undef );
    }
}

sub _child {
    if ( scalar(@_) != 4 ) { confess 'invalid call'; }
    my ( $self, $sub, $pipe, $pid ) = @_;

    # We are in the child process
    if ($use_anyevent_pipe) {
        $pipe = $pipe->[1];
    } else {
        $pipe->writer();
    }
    $pipe->autoflush(1);

    try {
        my $result = $sub->();
        $self->_send_result( $pipe, $result, $pid );
    }
    catch {
        $self->_send_error( $pipe, $_, $pid );
    };

    # Windows doesn't do fork(), it does threads...
    if ($use_threads) {
        return 1;
    } else {
        exit();
    }
}

=method waitall()

Called from the parent method while waiting for the children
to exit.  This method handles children that C<die()> or return
a serializable data structure.  When all children return, this
method will return.

If a child dies unexpectedly, this method will C<die()> and propagate a
modified exception.

In the standard (not ordered) mode, I.E. where a callback was passed
to C<async()>, this will return nothing.

In the ordered mode, I.E. where no callbacks were provided to C<async()>,
this will return the results of the async calls in an ordered list.  The
list will be ordered by the order in which the async calls were executed.

=cut

sub waitall {
    if ( $#_ != 0 ) { confess 'invalid call'; }
    my ($self) = @_;

    # No subprocs?  Just return.
    if ( scalar( keys %{ $self->_subprocs } ) == 0 ) {
        if ( $self->use_anyevent ) {
            $self->_cv( AnyEvent->condvar );
        }

        return $self->_get_and_reset_ordered_responses();
    }

    # Using AnyEvent?
    if ( defined( $self->_cv ) ) {
        $self->_cv->recv();
        if ( defined( $self->_last_error ) ) {
            my $err = $self->_last_error;
            $self->_last_error(undef);

            die($err);
        }

        return $self->_get_and_reset_ordered_responses();
    }

    # Tail recursion
    if ( $self->_waitone() ) { goto &waitall }

    return @{ $self->_get_and_reset_ordered_responses() };
}

# Gets the _ordered_responses and returns the reference.  Also
# resets the _ordered_responses and the _ordered_counts to an
# empty list and zero respectively.
sub _get_and_reset_ordered_responses {
    if ( $#_ != 0 ) { confess 'invalid call'; }
    my $self = shift;

    my (@r) = @{ $self->_ordered_responses() };

    $self->_ordered_responses( [] );
    $self->_ordered_count(0);

    return @r;
}

=method waitone()

This method similarly to C<waitall()>, but only waits for
a single PID.  It will return after any PID exits.

If this method is called when there is no processes executing,
it will simply return undef. Otherwise, it will wait and then
return 1.

=cut

sub waitone {
    if ( $#_ != 0 ) { confess 'invalid call'; }
    my ($self) = @_;

    my $rv = $self->_waitone();

    # Using AnyEvent?
    if ( defined( $self->_last_error ) ) {
        my $err = $self->_last_error;
        $self->_last_error(undef);

        die($err);
    }

    return $rv;
}

# Meat of waitone (but doesn't handle returning an exception when using
# anyevent)
sub _waitone {
    if ( $#_ != 0 ) { confess 'invalid call'; }
    my ($self) = @_;

    my $sp = $self->_subprocs();
    if ( !keys(%$sp) ) { return; }

    if ($use_thread_queue) {
        # On Windows
        #
        my $child = $self->_queue()->dequeue();

        my $thr = $self->_subprocs()->{$child}{thread};
        $self->_read_result($child);
        $thr->join();

        # Start queued children, if needed
        $self->_start_queued_children();

        return 1;
    } else {
        # On everything but Windows
        #
        my $s = IO::Select->new();
        foreach ( keys(%$sp) ) { $s->add( $sp->{$_}{fh} ); }

        my @ready = $s->can_read();

        foreach my $fh (@ready) {
            foreach my $child ( keys(%$sp) ) {
                if ( defined( $fh->fileno() ) ) {
                    if ( $fh->fileno() == $sp->{$child}{fh}->fileno() ) {
                        my $thr = $self->_subprocs()->{$child}{thread};
                        $self->_read_result($child);

                        if ($use_threads) {
                            $thr->join();
                        } else {
                            waitpid( $child, 0 );
                        }

                        # Start queued children, if needed
                        $self->_start_queued_children();

                        return 1;    # We don't want to read more than one!
                    }
                }
            }
        }
    }

    # We should never get here
    return;
}

=method wait($pid)

This functions simiarly to C<waitone()>, but waits only for
a specific PID.  See the C<waitone()> documentation above
for details.

If C<wait()> is called on a process that is already done
executing, it simply returns.  Otherwise, it waits until the
child process's work unit is complete and executes the callback
routine, then returns.

=cut

## no critic ('Subroutines::ProhibitBuiltinHomonyms')
sub wait {
    if ( $#_ != 1 ) { confess 'invalid call'; }
    my ( $self, $pid ) = @_;

    my $rv = $self->_wait($pid);

    if ( defined( $self->_last_error ) ) {
        my $err = $self->_last_error;
        $self->_last_error(undef);

        die($err);
    }

    return $rv;
}

# Internal version that doesn't check for AnyEvent die needs
sub _wait {
    if ( $#_ != 1 ) { confess 'invalid call'; }
    my ( $self, $pid ) = @_;

    if ( !exists( $self->_subprocs()->{$pid} ) ) {

        # We don't warn/die because it's possible that there is
        # a race between callback and here, in the main thread.
        return;
    }

    my $thr    = $self->_subprocs()->{$pid}{thread};
    my $result = $self->_read_result($pid);

    if ($use_threads) {
        $thr->join();
    } else {
        waitpid( $pid, 0 );
    }

    return $result;
}
## use critic

=method count()

This method returns the number of currently outstanding
threads (in either a running state or a waiting to send their
output).

=cut

sub count {
    if ( $#_ != 0 ) { confess 'invalid call'; }
    my ($self) = @_;

    my $sp = $self->_subprocs();
    return scalar( keys %$sp );
}

=method queue( sub { ... }, \&callback )

Spawns work on a new forked process, doing so immediately if less
than C<max_children> are running.  If there are already
C<max_children> are running, this will run the process once a slot
becomes available.

This method should be treated as nearly identical to C<async()>,
with the only difference being the above behavior (limiting to
C<max_children>) and not returning a PID.  Instead, a value of 1
is returned if the process is immediately started, C<undef>
otherwise.

The result is serialized and streamed back to the parent process
via a pipe.  The parent, in a C<waitall()> call, will call the
callback function (if provided) with the unserialized return value.

If a callback is not provided, the parent, in the C<waitall()> call,
will gather these results and return them as an ordered list.

=cut

sub queue {
    if ( $#_ < 1 ) { confess 'invalid call'; }
    my $self = shift;
    my $sub  = shift;
    
    # Test $sub to make sure it is a code ref or a sub ref
    if (! _codelike($sub)) {
        croak("Parameter to queue() is not a code (or codelike) reference");
    }

    my $callback;
    if ( scalar(@_) == 0 ) {
        # We're okay, don't need to do anything - no callback
    } elsif ( scalar(@_) == 1 ) {
        # We have a callback
        $callback = shift;
    } else {
        confess 'invalid call';
    }

    # If there are pending errors, throw that.
    if ( defined( $self->_last_error ) ) { die( $self->_last_error ); }

    push @{ $self->_queued_children }, [ $sub, $callback ];
    return $self->_start_queued_children();
}

sub _send_result {
    if ( $#_ != 3 ) { confess 'invalid call'; }
    my ( $self, $fh, $msg, $pid ) = @_;

    return $self->_send( $fh, 'RESULT', $msg, $pid );
}

sub _send_error {
    if ( $#_ != 3 ) { confess 'invalid call'; }
    my ( $self, $fh, $err, $pid ) = @_;

    return $self->_send( $fh, 'ERROR', $err, $pid );
}

sub _send {
    if ( $#_ != 4 ) { confess 'invalid call'; }
    my ( $self, $fh, $type, $data, $pid ) = @_;

    my $msg = Storable::freeze( \$data );

    if ( !defined($msg) ) {
        die 'freeze() returned undef for child return value';
    }

    if ($use_thread_queue) {
        $self->_queue()->enqueue($pid);
    }

    $fh->write($type);
    $fh->write("\n");

    $fh->write( length($msg) );
    $fh->write("\n");

    binmode( $fh, ':raw' );

    $fh->write($msg);

    $fh->close();
    return;
}

sub _read_result {
    if ( $#_ != 1 ) { confess 'invalid call'; }
    my ( $self, $child ) = @_;

    my $cinfo = $self->_subprocs()->{$child};
    my $fh    = $cinfo->{fh};

    my $type = <$fh>;
    if ( !defined($type) ) { die 'Could not read child data'; }
    chomp($type);

    my $size = <$fh>;
    chomp($size);

    binmode($fh);

    my $result = '';

    my $ret = 1;
    while ( defined($ret) && ( length($result) < $size ) ) {
        my $s = $size - length($result);

        my $part = '';
        $ret = $fh->read( $part, $s );
        if ( defined($ret) ) { $result .= $part; }
    }

    my $data = ${ Storable::thaw($result) };

    my $caller = $self->_subprocs()->{$child}{caller};
    my $thr    = $self->_subprocs()->{$child}{thread};
    delete $self->_subprocs()->{$child};
    $fh->close();

    if ( $type eq 'RESULT' ) {
        $cinfo->{callback}->($data);
    } else {
        if ($use_threads) { $thr->join(); }

        my $err =
            "Child (created at "
          . $caller->[1]
          . " line "
          . $caller->[2]
          . ") died with error: $data";

        if ( $self->use_anyevent ) {
            # Can't throw events with anyevent
            $self->_last_error($err);
        } else {
            # Otherwise we do throw it
            die($err);
        }
    }

    return;
}

# Start queued children, if possible.
# Returns 1 if children were started, undef otherwise
sub _start_queued_children {
    if ( $#_ != 0 ) { confess 'invalid call' }
    my ($self) = @_;

    if ( !( @{ $self->_queued_children } ) ) { return; }
    if ( defined( $self->_last_error ) )     { return; }    # Do not queue if there are errors

    # Can we start a queued process?
    while ( scalar @{ $self->_queued_children } ) {
        if ( ( !defined( $self->max_children ) ) || ( $self->count < $self->max_children ) ) {
            # Start queued child
            my $ele = shift @{ $self->_queued_children };
            if ( !defined( $ele->[1] ) ) {
                $self->async( $ele->[0] );
            } else {
                $self->async( $ele->[0], $ele->[1] );
            }
        } else {
            # Can't unqueue
            return;
        }
    }

    # We started at least one process
    return 1;
}

# Sets up AnyEvent or tears it down as needed
sub _set_anyevent {
    if ( $#_ < 1 ) { confess 'invalid call' }
    if ( $#_ > 2 ) { confess 'invalid call' }
    my ( $self, $new, $old ) = @_;

    if ( ( !$old ) && $new ) {
        # We are setting up AnyEvent
        require AnyEvent;

        if ( defined( $self->_subprocs() ) ) {
            foreach my $pid ( keys %{ $self->_subprocs() } ) {
                my $proc = $self->_subprocs()->{$pid};
                undef $proc;

                $self->_add_anyevent_watcher($pid);
            }
        }

        $self->_cv( AnyEvent->condvar );

    } elsif ( $old && ( !$new ) ) {
        # We are tearing down AnyEvent

        if ( defined( $self->_subprocs() ) ) {
            foreach my $pid ( keys %{ $self->_subprocs() } ) {
                my $proc = $self->_subprocs()->{$pid};

                $proc->{anyevent} = undef;
            }
        }

        $self->_cv(undef);
    }
    return;
}

# Sets up the listener for AnyEvent
sub _add_anyevent_watcher {
    if ( $#_ != 1 ) { confess 'invalid call' }
    my ( $self, $pid ) = @_;

    my $proc = $self->_subprocs()->{$pid};

    $proc->{anyevent} = AnyEvent->io(
        fh   => $proc->{fh},
        poll => 'r',
        cb   => sub {
            $self->_wait($pid);
            if ( scalar( keys %{ $self->_subprocs() } ) == 0 ) {
                my $oldcv = $self->_cv;
                $self->_cv( AnyEvent->condvar );
                $oldcv->send();
            }

            # Start queued children, if needed
            $self->_start_queued_children();
        },
    );

    return;
}

# Tests to see if something is codelike
#
# Borrowed from Params::Util (written by Adam Kennedy)
sub _codelike {
    if ( scalar(@_) != 1 ) { confess 'invalid call' }
    my $thing = shift;

    if (reftype($thing)) { return 1; }
    if (blessed($thing) && overload::Method($thing, '()')) { return 1; }

    return;
}

# Destructor emits warning if sub processes are running
sub DEMOLISH {
    my $self = shift;

    # If we use threads, just don't print this warning because it is
    # going to happen on parent and child threads both. We want
    # different process IDs for this warning.
    if ($use_threads) { return; }

    # When we fork(), we might have other work unit processes hanging
    # around
    # XXX There should be a better way of handling this. We don't want
    # pipes and the like held open by multiple processes.
    if ( $self->_parent_pid != $$ ) { return; }

    if ( scalar( keys %{ $self->_subprocs } ) ) {
        warn "Warning: Subprocesses running when Parallel::WorkUnit object destroyed\n";
    }

    return;
}

__PACKAGE__->meta->make_immutable;

1;

