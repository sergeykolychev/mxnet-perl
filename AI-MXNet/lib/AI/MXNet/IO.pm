package AI::MXNet::IO;
use strict;
use warnings;
use AI::MXNet::Base;
use AI::MXNet::Function::Parameters;
use Scalar::Util qw/blessed/;

=head1 DESCRIPTION

    NDArray interface of mxnet.
=cut

# Convert data into canonical form.
method init_data(
    AcceptableInput|HashRef[AcceptableInput]|ArrayRef[AcceptableInput]|Undef $data,
    Undef|Int :$allow_empty=,
    Str :$default_name
)
{
    Carp::confess("data must be defined or allow_empty set to true value")
        if(not defined $data and not $allow_empty);
    $data //= [];

    if(ref($data) and ref($data) ne 'ARRAY' and ref($data) ne 'HASH')
    {
        $data = [$data];
    }

    Carp::confess("data must not be empty or allow_empty set to true value")
        if(ref($data) eq 'ARRAY' and not @{ $data } and not $allow_empty);

    my @ret;
    if(ref($data) eq 'ARRAY')
    {
        if(@{ $data } == 1)
        {
            @ret = ([$default_name, $data->[0]]);
        }
        else
        {
            my $i = -1;
            @ret = map { $i++; ["_${i}_$default_name", $_] } @{ $data };
        }
    }
    if(ref($data) eq 'HASH')
    {
        while(my ($k, $v) = each %{ $data })
        {
            push @ret, [$k, $v];
        }
    }
    for my $d (@ret)
    {
        if(not (blessed $d->[1] and $d->[1]->isa('AI::MXNet::NDArray')))
        {
            $d->[1] = AI::MXNet::NDArray->array($d->[1]);
        }
    }
    return \@ret;
}

package AI::MXNet::DataDesc;
use Mouse;
use overload '""' => \&stringify;

has 'name'   => (is => 'ro', isa => "Str",   required => 1);
has 'shape'  => (is => 'ro', isa => "Shape", required => 1);
has 'dtype'  => (is => 'ro', isa => "Dtype", default => 'float32');
has 'layout' => (is => 'ro', isa => "Str",   default => 'NCHW');

method stringify($other=, $reverse=)
{
    sprintf(
        "DataDesc[%s,%s,%s,%s]", 
        $self->name,
        join('x', @{ $self->shape }),
        $self->dtype,
        $self->layout
    );
}

=head2 get_batch_axis

        Get the dimension that corresponds to the batch size.

        Parameters
        ----------
        layout : str
            layout string. For example, "NCHW".

        Returns
        -------
        An axis indicating the batch_size dimension. When data-parallelism is
        used, the data will be automatically split and concatenate along the batch_size
        dimension. Axis can be -1, which means the whole array will be copied for each
        data-parallelism device.
=cut

method get_batch_axis(Str|Undef $layout)
{
    return 0 unless defined $layout;
    return index($layout, 'N');
}

=head2 get_list

        Get DataDesc list from attribute lists.

        Parameters
        ----------
        shapes : hashref with (name, shape)
        types :  hashref with (name, type)
=cut

method get_list(HashRef[Shape] $shapes, HashRef[Dtype]|Undef $types)
{
    $types //= {};
    return [
        map {
            AI::MXNet::DataDesc->new(
                name  => $_,
                shape => $shapes->{$_},
                (exists $types->{$_} ? (type => $types->{$_}) : ())
            )
        } keys %{ $shapes }
    ];
}

package AI::MXNet::DataBatch;
use Mouse;

=head1 DESCRIPTION

    Default object for holding a mini-batch of data and related information.
=cut

has 'data'          => (is => 'rw', required => 1);
has 'label'         => (is => 'rw', required => 1);
has 'pad'           => (is => 'rw');
has 'index'         => (is => 'rw');
has 'bucket_key'    => (is => 'rw');
has 'provide_data'  => (is => 'rw');
has 'provide_label' => (is => 'rw');

package AI::MXNet::DataIter;
use Mouse;
use overload '<>' =>  sub { shift->next },
             '@{}' => sub { shift->list };

=head2 DESCRIPTION

    DataIter object in mxnet.
=cut

has 'batch_size' => (is => 'rw', isa => 'Int', default => 0);

=head2 reset

        Reset the iterator.
=cut

method reset(){}

=head2 list

        Returns remaining iterator items as array ref.
=cut

method list()
{
    my @ret;
    while(<$self>)
    {
        push @ret, $_;
    }
    return \@ret;
}

=head2 next

        Get next data batch from iterator. Equivalent to
        self.iter_next()
        DataBatch(self.getdata(), self.getlabel(), self.getpad(), None)

        Returns
        -------
        data : DataBatch
            The data of next batch.
=cut

method next()
{
    if($self->iter_next())
    {
        return AI::MXNet::DataBatch->new(
            data  => $self->getdata,
            label => $self->getlabel,
            pad   => $self->getpad,
            index => $self->getindex
        );
    }
    else
    {
        return undef;
    }
}

=head2 iter_next

        Iterate to next batch.

        Returns
        -------
        has_next : boolean
            Whether the move is successful.
=cut

method iter_next(){}

=head2 get_data

        Get data of current batch.

        Returns
        -------
        data : NDArray
            The data of current batch.
=cut

method get_data(){}

=head2 getlabel

        Get data of current batch.

        Returns
        -------
        label : NDArray
            The label of current batch.
=cut

method getlabel(){}

=head2 getindex

        Get index of the current batch.

        Returns
        -------
        index : numpy.array
            The index of current batch
=cut

method getindex(){}

=head2 getpad

        Get the number of padding examples in current batch.

        Returns
        -------
        pad : int
            Number of padding examples in current batch
=cut

method getpad(){}

package AI::MXNet::ResizeIter;
use Mouse;

extends 'AI::MXNet::DataIter';

=head2 new

    "Resize a DataIter to given number of batches per epoch.
    May produce incomplete batch in the middle of an epoch due
    to padding from internal iterator.

    Parameters
    ----------
    data_iter : DataIter
        Internal data iterator.
    size : number of batches per epoch to resize to.
    reset_internal : whether to reset internal iterator on ResizeIter.reset
=cut

has 'data_iter'      => (is => 'ro', isa => 'AI::MXnet::DataIter', required => 1);
has 'size'           => (is => 'ro', isa => 'Int', required => 1);
has 'reset_internal' => (is => 'rw', isa => 'Int', default => 1);
has 'cur'            => (is => 'rw', isa => 'Int', default => 0);
has 'current_batch'  => (is => 'rw', isa => 'Maybe[AI::MXNet::DataBatch]');
has 'provide_data'   => (is => 'rw', default => sub { shift->data_iter->provide_data  }, lazy => 1);
has 'provide_label'  => (is => 'rw', default => sub { shift->data_iter->provide_label }, lazy => 1);
has 'batch_size'     => (is => 'rw', default => sub { shift->data_iter->batch_size    }, lazy => 1);

method reset()
{
    $self->cur(0);
    if($self->reset_internal)
    {
        $self->data_iter->reset;
    }
}

method iter_next
{
    return 0 if($self->cur == $self->size);
    $self->current_batch($self->data_iter->next);
    if(not defined $self->current_batch)
    {
        $self->data_iter->reset;
        $self->current_batch($self->data_iter->next);
    }
    $self->cur($self->cur + 1);
    return 1;
}

method get_data()
{
    return $self->current_batch->data;
}

method getlabel()
{
    return $self->current_batch->label;
}

method getindex()
{
    return $self->current_batch->index;
}

method getpad()
{
    return $self->current_batch->pad;
}

package AI::MXNet::NDArrayIter;
use Mouse;
use List::Util qw/shuffle/;
use AI::MXNet::Base;

extends 'AI::MXNet::DataIter';

=head1 DESCRIPTION

    NDArrayIter object in mxnet. Taking NDArray or numpy array to get dataiter.

    Parameters
    ----------
    data: NDArray or numpy.ndarray, a list of them, or a dict of string to them.
        NDArrayIter supports single or multiple data and label.
    label: NDArray or numpy.ndarray, a list of them, or a dict of them.
        Same as data, but is not fed to the model during testing.
    batch_size: int
        Batch Size
    shuffle: bool
        Whether to shuffle the data
    last_batch_handle: 'pad', 'discard' or 'roll_over'
        How to handle the last batch

    Note
    ----
    This iterator will pad, discard or roll over the last batch if
    the size of data does not match batch_size. Roll over is intended
    for training and can cause problems if used for prediction.
=cut

has 'data'                => (is => 'rw', isa => 'AcceptableInput|HashRef[AcceptableInput]|ArrayRef[AcceptableInput]|Undef');
has 'data_list'           => (is => 'rw', isa => 'ArrayRef[AI::MXNet::NDArray]');
has 'label'               => (is => 'rw', isa => 'AcceptableInput|HashRef[AcceptableInput]|ArrayRef[AcceptableInput]|Undef');
has 'batch_size'          => (is => 'rw', isa => 'Int', default => 1);
has '_shuffle'            => (is => 'rw', init_arg => 'shuffle', isa => 'Bool', default => 0);
has 'last_batch_handle'   => (is => 'rw', isa => 'Str', default => 'pad');
has 'label_name'          => (is => 'rw', isa => 'Str', default => 'softmax_label');
has 'num_source'          => (is => 'rw', isa => 'Int');
has 'cursor'              => (is => 'rw', isa => 'Int');
has 'num_data'            => (is => 'rw', isa => 'Int');

sub BUILD
{
    my $self  = shift;
    my $data  = AI::MXNet::IO->init_data($self->data,  allow_empty => 0, default_name => 'data');
    my $label = AI::MXNet::IO->init_data($self->label, allow_empty => 1, default_name => $self->label_name);
    my $num_data  = $data->[0][1]->shape->[0];
    confess("size of data dimension 0 $num_data < batch_size ${\ $self->batch_size }")
        unless($num_data >= $self->batch_size);
    if($self->_shuffle)
    {
        my @idx = shuffle(0..$num_data-1);
        $_->[1] = AI::MXNet::NDArray->array(cat((dog($_->[1]->aspdl))[@idx])) for @$data;
        $_->[1] = AI::MXNet::NDArray->array(cat((dog($_->[1]->aspdl))[@idx])) for @$label;
    }
    if($self->last_batch_handle eq 'discard')
    {
        my $new_n = $num_data - $num_data % $self->batch_size - 1;
        $_->[1] = $_->[1]->slice([0, $new_n]) for @$data;
        $_->[1] = $_->[1]->slice([0, $new_n]) for @$label;
    }
    my $data_list  = [map { $_->[1] } (@{ $data }, @{ $label })];
    my $num_source = @{ $data_list };
    my $cursor = -$self->batch_size;
    $self->data($data);
    $self->data_list($data_list);
    $self->label($label);
    $self->num_source($num_source);
    $self->cursor($cursor);
    $self->num_data($num_data);
}

# The name and shape of data provided by this iterator
method provide_data()
{
    return [map {
        my ($k, $v) = @{ $_ };
        my $shape = $v->shape;
        $shape->[0] = $self->batch_size;
        AI::MXNet::DataDesc->new(name => $k, shape => $shape, dtype => $v->dtype)
    } @{ $self->data }];
}

# The name and shape of label provided by this iterator
method provide_label()
{
    return [map {
        my ($k, $v) = @{ $_ };
        my $shape = $v->shape;
        $shape->[0] = $self->batch_size;
        AI::MXNet::DataDesc->new(name => $k, shape => $shape, dtype => $v->dtype)
    } @{ $self->label }];
}

# Ignore roll over data and set to start
method hard_reset()
{
    $self->cursor(-$self->batch_size);
}

method reset()
{
    if($self->last_batch_handle eq 'roll_over' and $self->cursor > $self->num_data)
    {
        $self->cursor(-$self->batch_size + ($self->cursor%$self->num_data)%$self->batch_size);
    }
    else
    {
        $self->cursor = -$self->batch_size;
    }
}

method iter_next()
{
    $self->cursor($self->batch_size + $self->cursor);
    return $self->cursor < $self->num_data;
}

method next()
{
    if($self->iter_next)
    {
        return AI::MXNet::DataBatch->new(
            data  => $self->getdata,
            label => $self->getlabel,
            pad   => $self->getpad,
            index => undef
        );
    }
    else
    {
        return undef;
    }
}

# Load data from underlying arrays, internal use only
method _getdata($data_source)
{
    confess("DataIter needs reset.") unless $self->cursor < $self->num_data;
    if(($self->cursor + $self->batch_size) <= $self->num_data)
    {
        return [
            map {
                $_->[1]->slice([$self->cursor,$self->cursor+$self->batch_size-1])
            } @{ $data_source }
        ];
    }
    else
    {
        my $pad = $self->batch_size - $self->num_data + $self->cursor - 1;
        return [
            map {
                AI::MXNet::NDArray->concatenate(
                    [
                        $_->[1]->slice([$self->cursor, -1]),
                        $_->[1]->slice([0, $pad])
                    ]
                )
            } @{ $data_source }
        ];
    }
}

method getdata()
{
    return $self->_getdata($self->data);
}

method getlabel()
{
    return $self->_getdata($self->label);
}

method getpad()
{
    if( $self->last_batch_handle eq 'pad'
            and
        ($self->cursor + $self->batch_size) > $self->num_data
    )
    {
        return $self->cursor + $self->batch_size - $self->num_data;
    }
    else
    {
        return 0;
    }
}

package AI::MXNet::MXDataIter;
use Mouse;
use AI::MXNet::Base;

extends 'AI::MXNet::DataIter';

=head1 DESCRIPTION

    DataIter built in MXNet. List all the needed functions here.

    Parameters
    ----------
    handle : DataIterHandle
        the handle to the underlying C++ Data Iterator
=cut

has 'handle'           => (is => 'ro', isa => 'DataIterHandle', required => 1);
has '_debug_skip_load' => (is => 'rw', isa => 'Int', default => 0);
has '_debug_at_begin'  => (is => 'rw', isa => 'Int', default => 0);
has 'data_name'        => (is => 'ro', isa => 'Str', default => 'data');
has 'label_name'       => (is => 'ro', isa => 'Str', default => 'softmax_label');
has [qw/first_batch
        provide_data
        provide_label
        batch_size/]   => (is => 'rw', init_arg => undef);

sub BUILD
{
    my $self = shift;
    $self->first_batch($self->next);
    my $data = $self->first_batch->data->[0];
    $self->provide_data([
        AI::MXNet::DataDesc->new(
            name  => $self->data_name,
            shape => $data->shape,
            dtype => $data->dtype
        )
    ]);
    my $label = $self->first_batch->label->[0];
    $self->provide_label([
        AI::MXNet::DataDesc->new(
            name  => $self->label_name,
            shape => $label->shape,
            dtype => $label->dtype
        )
    ]);
    $self->batch_size($data->shape->[0]);
}

sub DEMOLISH
{
    check_call(AI::MXNetCAPI::DataIterFree(shift->handle));
}

=head2 debug_skip_load

        Set the iterator to simply return always first batch.
        Notes
        -----
        This can be used to test the speed of network without taking
        the loading delay into account.
=cut

method debug_skip_load()
{
    $self->_debug_skip_load(1);
    ## TODO logging.info('Set debug_skip_load to be true, will simply return first batch')
}

method reset()
{
    $self->_debug_at_begin(1);
    $self->first_batch(undef);
    check_call(AI::MXNetCAPI::DataIterBeforeFirst($self->handle));
}

method next()
{
    if($self->_debug_skip_load and not $self->_debug_at_begin)
    {
        return  AI::MXNet::DataBatch->new(
                    data  => [$self->getdata],
                    label => [$self->getlabel],
                    pad   => $self->getpad,
                    index => $self->getindex
        );
    }
    if(defined $self->first_batch)
    {
        my $batch = $self->first_batch;
        $self->first_batch(undef);
        return $batch
    }
    $self->_debug_at_begin(0);
    my $next_res =  check_call(AI::MXNetCAPI::DataIterNext($self->handle));
    if($next_res)
    {
        return  AI::MXNet::DataBatch->new(
                    data  => [$self->getdata],
                    label => [$self->getlabel],
                    pad   => $self->getpad,
                    index => $self->getindex
        );
    }
    else
    {
        return undef;
    }
}

method iter_next()
{
    if(defined $self->first_batch)
    {
        return 1;
    }
    else
    {
        return scalar(check_call(AI::MXNetCAPI::DataIterNext($self->handle)));
    }
}

method getdata()
{
    my $handle = check_call(AI::MXNetCAPI::DataIterGetData($self->handle));
    return AI::MXNet::NDArray->new(handle => $handle);
}

method getlabel()
{
    my $handle = check_call(AI::MXNetCAPI::DataIterGetLabel($self->handle));
    return AI::MXNet::NDArray->new(handle => $handle);
}

method getindex()
{
    return pdl(check_call(AI::MXNetCAPI::DataIterGetIndex($self->handle)));
}

method getpad()
{
    return scalar(check_call(AI::MXNetCAPI::DataIterGetPadNum($self->handle)));
}

package AI::MXNet::IO;

sub NDArrayIter { shift; return AI::MXNet::NDArrayIter->new(@_); }

my %iter_meta;
method get_iter_meta
{
    return \%iter_meta;
}

# Create an io iterator by handle.
func _make_io_iterator($handle)
{
    my ($iter_name, $desc,
        $arg_names, $arg_types, $arg_descs
    ) = @{ check_call(AI::MXNetCAPI::DataIterGetIterInfo($handle)) };
    my $param_str = build_param_doc($arg_names, $arg_types, $arg_descs);
    my $doc_str = "$desc\n\n"
                  ."$param_str\n"
                  ."name : string, required.\n"
                  ."    Name of the resulting data iterator.\n\n"
                  ."Returns\n"
                  ."-------\n"
                  ."iterator: DataIter\n"
                  ."    The result iterator.";

=head2 $iter

        Create an iterator.
        The parameters listed below can be passed in as keyword arguments.

        Parameters
        ----------
        name : string, required.
            Name of the resulting data iterator.

        Returns
        -------
        dataiter: Dataiter
            the resulting data iterator
=cut

    my $iter = sub {
        my $class = shift;
        my (@args, %kwargs);
        if(@_ and ref $_[-1] eq 'HASH')
        {
            %kwargs = %{ pop(@_) };
        }
        @args = @_;
        Carp::confess("$iter_name can only accept keyword arguments")
            if @args;
        for my $key (keys %kwargs)
        {
            $kwargs{ $key } = "(" .join(",", @{ $kwargs{ $key } }) .")"
                if ref $kwargs{ $key } eq 'ARRAY';
        }
        my $handle = check_call(
            AI::MXNetCAPI::DataIterCreateIter(
                $handle,
                scalar(keys %kwargs),
                \%kwargs
            )
        );
        return AI::MXNet::MXDataIter->new(handle => $handle, %kwargs);
    };
    $iter_meta{$iter}{__name__} = $iter_name;
    $iter_meta{$iter}{__doc__}  = $doc_str;
    return $iter;
}

# List and add all the data iterators to current module.
method _init_io_module()
{
    for my $creator (@{ check_call(AI::MXNetCAPI::ListDataIters()) })
    {
        my $data_iter = _make_io_iterator($creator);
        {
            my $name = $iter_meta{ $data_iter }{__name__};
            no strict 'refs';
            {
                *{__PACKAGE__."::$name"} = $data_iter;
            } 
        }
    }
}

# Initialize the io in startups
__PACKAGE__->_init_io_module;

1;