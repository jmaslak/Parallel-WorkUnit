#
# Copyright (C) 2015 Joel Maslak
# All Rights Reserved - See License
#

use v5.14;
use utf8;

package Parallel::WorkUnit;

# ABSTRACT: Provide easy-to-use forking with ability to pass back data

use strict;
use warnings;
use autodie;

use Carp;
use IO::Pipe;
use IO::Select;
use Moose;
use POSIX ':sys_wait_h';
use Storable;
use TryCatch;

use namespace::autoclean;

=head1 SYNOPSIS

  my $wu = Parallel::WorkUnit->new();
  $wu->async( sub { ... }, \&callback );

  $wu->waitall();

=head1 DESCRIPTION

This is a very simple forking implementation of parallelism, with the
ability to pass data back from the asyncronous child process in a
relatively efficient way (with the limitation of using a pipe to pass
the information, serialized, back).  It was designed to be very simple
for a developer to use, with the ability to pass reasonably large amounts
of data back to the parent process.

There are many other Parallel::* applications in CPAN - it would be worth
any developer's time to look through those and choose the best one.

=head1 SIDE EFFECTS

This module, when instantiated, sets the SIG{CHLD} handler to 'IGNORE'.
This means that children will be automatically reaped on most systems.
In addition, the C<wait()> and C<waitall()> methods will attempt to
reap any outstanding children.

=cut

=method new

Create a new workunit class.

=cut

has '_subprocs' => (
    is       => 'rw',
    isa      => 'HashRef',
    init_arg => undef
);

sub BUILD {
    my $self = shift;

    $self->_subprocs( {} );
    $SIG{CHLD} = 'IGNORE';
}

=method async( sub { ... }, \&callback )

Spawns work on a new forked process.  The forked process inherits
all Perl state from the parent process, as would be expected with
a standard C<fork()> call.  The child shares nothing with the
parent, other than the return value of the work done.

The work is specified either as a subroutine reference or an
anonymous sub (C<sub { ... }>) and should return a scalar.  Any
scalar that L<Storable>'s C<freeze()> method can deal with
is acceptable (for instance, a hash reference or C<undef>).

When the work is completed, it serializes the result and streams
it back to the parent process via a pipe.  The parent, in a
C<waitall()> call, will call the callback function with the
unserialized return value.

Should the child process C<die>, the parent process will also
die (inside the C<waitall()> method).

The PID of the child is returned to the parent process when
this method is executed.

=cut

sub async {
    if ( $#_ != 2 ) { confess 'invalid call'; }
    my ( $self, $sub, $callback ) = @_;

    my $pipe = IO::Pipe->new();

    my $pid = fork;
    if ( !defined($pid) ) { die "Fork failed: $!"; }

    if ($pid) {

        # We are in the parent process
        $pipe->reader();

        $self->_subprocs()->{$pid} = {
            fh       => $pipe,
            callback => $callback
        };

        return $pid;

    } else {

        # We are in the child process
        $pipe->writer();
        $pipe->autoflush(1);

        try {
            my $result = $sub->();
            $self->_send_result( $pipe, $result );
        } catch($err) {

            $self->_send_error( $pipe, $err );
        };

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

This method has a side-effect of reaping any children that haven't yet
been reaped.  If you aren't messing with C<$SIG{CHLD}>, you do not need
to worry about this.

=cut

sub waitall {
    if ( $#_ != 0 ) { confess 'invalid call'; }
    my ($self) = @_;

    my $sp = $self->_subprocs();
    if ( !keys(%$sp) ) { return; }

    my $s = IO::Select->new();
    foreach ( keys(%$sp) ) { $s->add( $sp->{$_}{fh} ); }

    my @ready = $s->can_read;

    foreach my $fh (@ready) {
        foreach my $child ( keys(%$sp) ) {
            if ( defined($fh->fileno())) {
                if ( $fh->fileno() == $sp->{$child}{fh}->fileno() ) {
                    $self->_read_result($child);
                }
            }
        }
    }
   
    # Just in case SIG{CHLD}="IGNORE" doesn't cause the children to
    # be reaped. 
    while ( ( my $child = waitpid( -1, WNOHANG ) ) > 0 ) { }

    # Tail recursion
    goto &waitall;
}

=method wait($pid)

This functions simiarly to C<waitall()>, but only waits for
a single PID.  See the C<waitall()> documentation above
for details.

If C<wait()> is called on a process that is already done
executing, it simply returns.  Otherwise, it waits until the
child process's work unit is complete and executes the callback
routine, then returns.

This method has a side-effect of reaping any children that haven't yet
been reaped.  If you aren't messing with C<$SIG{CHLD}>, you do not need
to worry about this.

=cut

sub wait {
    if ( $#_ != 1 ) { confess 'invalid call'; }
    my ( $self, $pid ) = @_;

    if ( !exists( $self->_subprocs()->{$pid} ) ) {

        # We don't warn/die because it's possible that there is
        # a race between callback and here, in the main thread.
        return;
    }

    my $result = $self->_read_result($pid);

    # Just in case SIG{CHLD}="IGNORE" doesn't cause the children to
    # be reaped. 
    while ( ( my $child = waitpid( -1, WNOHANG ) ) > 0 ) { }

    return $result;
}

sub _send_result {
    if ( $#_ != 2 ) { confess 'invalid call'; }
    my ( $self, $fh, $msg ) = @_;

    $self->_send( $fh, 'RESULT', $msg );
}

sub _send_error {
    if ( $#_ != 2 ) { confess 'invalid call'; }
    my ( $self, $fh, $err ) = @_;

    $self->_send( $fh, 'ERROR', $err );
}

sub _send {
    if ( $#_ != 3 ) { confess 'invalid call'; }
    my ( $self, $fh, $type, $data ) = @_;

    $fh->write($type);
    $fh->write("\n");

    my $msg = Storable::freeze( \$data );

    $fh->write(length($msg));
    $fh->write("\n");

    binmode($fh, ':raw');

    $fh->write($msg);

    $fh->close();
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

    my $part;
    my $ret = 1;
    while ( defined($ret) && ( length($result) < $size ) ) {
        my $s = $size - length($result);

        my $part = '';
        $ret = $fh->read( $part, $s );
        if ( defined($ret) ) { $result .= $part; }
    }

    my $data = ${ Storable::thaw($result) };

    delete $self->_subprocs()->{$child};
    $fh->close();

    if ( $type eq 'RESULT' ) {
        $cinfo->{callback}->($data);
    } else {
        die("Child died with error: $data");
    }
}

__PACKAGE__->meta->make_immutable;

1;

