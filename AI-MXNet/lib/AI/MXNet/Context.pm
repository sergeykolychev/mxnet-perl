package AI::MXNet::Context;
use strict;
use warnings;
use Mouse;
use AI::MXNet::Types;
use AI::MXNet::Function::Parameters;
use constant devtype2str => { 1 => 'cpu', 2 => 'gpu', 3 => 'cpu_pinned' };
use constant devstr2type => { cpu => 1, gpu => 2, cpu_pinned => 3 };

has 'device_type' => (
    is => 'rw',
    isa => enum([qw[cpu gpu cpu_pinned]]),
    default => 'cpu'
);

has 'device_type_id' => (  
    is => 'rw',
    isa => enum([1, 2, 3]),
    default => sub { devstr2type->{ shift->device_type } },
    lazy => 1
);

has 'device_id' => (
    is => 'rw',
    isa => 'Int',
    default => 0
);

use overload
    '==' => sub { 
        my ($self, $other) = @_;
        return 0 unless blessed($other) and $other->isa(__PACKAGE__);
        return "$self" eq "$other";
    },
    '""' => sub {
        my ($self) = @_;
        return sprintf("%s(%s)", $self->device_type, $self->device_id); 
    };

=head2

    Constructing a context.

    Parameters
    ----------
    device_type : {'cpu', 'gpu'} or Context.
        String representing the device type

    device_id : int (default=0)
        The device id of the device, needed for GPU

    Note
    ----
    Context can also be used a way to change default context.

=cut

=head2 cpu

    Return a CPU context.

    Parameters
    ----------
    device_id : int, optional
        The device id of the device. device_id is not needed for CPU.
        This is included to make interface compatible with GPU.

    Returns
    -------
    context : Context
        The corresponding CPU context.
=cut

method cpu(Int $device_id=0)
{
    return $self->new(device_type => 'cpu', device_id => $device_id);
}

=head2 gpu

    Return a GPU context.

    Parameters
    ----------
    device_id : int, optional
        The device id of the device. device_id is not needed for CPU.
        This is included to make interface compatible with GPU.

    Returns
    -------
    context : Context
        The corresponding GPU context.
=cut

method gpu(Int $device_id=0)
{
    return $self->new(device_type => 'gpu', device_id => $device_id);
}

=head2 current_context

    Return the current context.

    Returns
    -------
    default_ctx : Context
=cut

method current_ctx()
{
    return $AI::MXNet::current_ctx;
}

method deepcopy()
{
    return __PACKAGE__->new(
                device_type => $self->device_type,
                device_id => $self->device_id
    );
}

$AI::MXNet::current_ctx = __PACKAGE__->new(device_type => 'cpu', device_id => 0);

