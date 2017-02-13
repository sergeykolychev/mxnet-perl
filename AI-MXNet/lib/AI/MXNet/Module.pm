## TODO
## this class is here because of https://github.com/gfx/p5-Mouse/pull/67
## once 2.4.7 version of Mouse in Ubuntu for affected Perl version
## these accessors should be merged into main class

package AI::MXNet::Module::Private;
use Mouse;
has [qw/_param_names _fixed_param_names
        _aux_names _data_names _label_names
        _output_names _arg_params _aux_params
        _params_dirty _optimizer _kvstore
         _update_on_kvstore _updater _work_load_list
        _preload_opt_states _exec_group
        _data_shapes _label_shapes _context/
] => (is => 'rw', init_arg => undef);

package AI::MXNet::Module;
use AI::MXNet::Base;
use AI::MXNet::Function::Parameters;
use List::Util qw(max product);
use Mouse;

=head2 _create_kvstore

    Create kvstore
    This function select and create a proper kvstore if given the kvstore type

    Parameters
    ----------
    kvstore : KVStore or str
        The kvstore
    num_device : int
        The number of devices
    arg_params : dict of str to NDArray
        Model parameter, dict of name to NDArray of net's weights.
=cut

func _create_kvstore(
    Maybe[Str|AI::MXNet::KVStore] $kvstore,
    Int                           $num_device,
    HashRef[AI::MXNet::NDArray]   $arg_params
)
{
    my $update_on_kvstore = 1;
    my $kv;
    if(defined $kvstore)
    {
        if(blessed $kvstore)
        {
            $kv = $kvstore;
        }
        else
        {
            # create kvstore using the string type
            if($num_device == 1 and $kvstore !~ /dist/)
            {
                # no need to use kv for single device and single machine
            }
            else
            {
                $kv = AI::MXNet::KVStore->create($kvstore);
                if($kvstore eq 'local')
                {
                    # automatically select a proper local
                    my $max_size = max(map { product(@{ $_->shape }) } values %{ $arg_params });
                    if($max_size > 1024 * 1024 * 16)
                    {
                        $update_on_kvstore = 0;
                    }
                }
            }
        }
    }

    $update_on_kvstore = 0 if not $kv;
    return ($kv, $update_on_kvstore);
}

=head2 _initialize_kvstore

    Initialize kvstore
=cut

func _initialize_kvstore(
    AI::MXNet::KVStore           :$kvstore,
    ArrayRef[AI::MXNet::NDArray] :$param_arrays,
    HashRef[AI::MXNet::NDArray]  :$arg_params,
    ArrayRef[Str]                :$param_names,
    Bool                         :$update_on_kvstore
)
{
    enumerate(sub{
        my ($idx, $param_on_devs) = @_;
        $kvstore->init($idx, $arg_params->{ $param_names->[$idx] });
        if($update_on_kvstore)
        {
            $kvstore->pull($idx, $param_on_devs, priority => -$idx);
        }
    }, $param_arrays);
}

=head2 _update_params_on_kvstore

    Perform update of param_arrays from grad_arrays on kvstore.
=cut

method _update_params_on_kvstore(
    ArrayRef[AI::MXNet::NDArray] $param_arrays,
    ArrayRef[AI::MXNet::NDArray] $grad_arrays,
    AI::MXNet::KVStore           $kvstore
)
{
    enumerate(sub{
        my ($index, $arg_list, $grad_list) = @_;
        if(ref $grad_list eq 'ARRAY' and not defined $grad_list->[0])
        {
            return;
        }
        # push gradient, priority is negative index
        $kvstore->push($index, $grad_list, priority => -$index);
        # pull back the weights
        $kvstore->pull($index, $arg_list, priority  => -$index);
    }, $param_arrays, $grad_arrays);
}

=head _update_params

    Perform update of param_arrays from grad_arrays not on kvstore.
=cut
func _update_params(
    ArrayRef[ArrayRef[AI::MXNet::NDArray]] $param_arrays,
    ArrayRef[ArrayRef[AI::MXNet::NDArray]] $grad_arrays,
    AI::MXNet::Updater                     $updater,
    Int                                    $num_device,
    Maybe[AI::MXNet::KVStore]              $kvstore=
)
{
    enumerate(sub{
        my ($index, $arg_list, $grad_list) = @_;
        if(not defined $grad_list->[0])
        {
            return;
        }
        if($kvstore)
        {
            # push gradient, priority is negative index
            $kvstore->push($index, $grad_list, priority => -$index);
            # pull back the sum gradients, to the same locations.
            $kvstore->pull($index, $grad_list, priority => -$index);
        }
        enumerate(sub {
            my ($k, $w, $g) = @_;
            # faked an index here, to make optimizer create diff
            # state for the same index but on diff devs, TODO(mli)
            # use a better solution latter
            &{$updater}($index*$num_device+$k, $g, $w);
        }, $arg_list, $grad_list);
    }, $param_arrays, $grad_arrays);
}

=head2 load_checkpoint

    Load model checkpoint from file.

    Parameters
    ----------
    prefix : str
        Prefix of model name.
    epoch : int
        Epoch number of model we would like to load.

    Returns
    -------
    symbol : Symbol
        The symbol configuration of computation network.
    arg_params : dict of str to NDArray
        Model parameter, dict of name to NDArray of net's weights.
    aux_params : dict of str to NDArray
        Model parameter, dict of name to NDArray of net's auxiliary states.

    Notes
    -----
    - symbol will be loaded from ``prefix-symbol.json``.
    - parameters will be loaded from ``prefix-epoch.params``.
=cut

func load_checkpoint(Str $prefix, Int $epoch)
{
    my $symbol = AI::MXNet::Symbol->load("$prefix-symbol.json");
    my %save_dict = %{ AI::MXNet::NDArray->load(sprintf('%s-%04d.params', $prefix, $epoch)) };
    my %arg_params;
    my %aux_params;
    while(my ($k, $v) = each %save_dict)
    {
        my ($tp, $name) = split(/:/, $k, 2);
        if($tp eq 'arg')
        {
            $arg_params{$name} = $v;
        }
        if($tp eq 'aux')
        {
            $aux_params{$name} = $v;
        }
    }
    return ($symbol, \%arg_params, \%aux_params);
}

=head2 new

    Module is a basic module that wrap a `Symbol`. It is functionally the same
    as the `FeedForward` model, except under the module API.

    Parameters
    ----------
    symbol : Symbol
    data_names : list of str
        Default is `('data')` for a typical model used in image classification.
    label_names : list of str
        Default is `('softmax_label')` for a typical model used in image
        classification.
    logger : Logger
        Default is `logging`.
    context : Context or list of Context
        Default is `cpu()`.
    work_load_list : list of number
        Default `None`, indicating uniform workload.
    fixed_param_names: list of str
        Default `None`, indicating no network parameters are fixed.
=cut

extends 'AI::MXNet::Module::Base';

has '_symbol'           => (is => 'ro', init_arg => 'symbol', isa => 'AI::MXNet::Symbol', required => 1);
has 'data_names'        => (is => 'rw', isa => 'ArrayRef[Str]', default => sub { ['data'] });
has 'label_names'       => (is => 'ro', isa => 'Maybe[ArrayRef[Str]]', default => sub { ['softmax_label'] });
has 'work_load_list'    => (is => 'rw', isa => 'ArrayRef[Int]');
has 'fixed_param_names' => (is => 'rw', isa => 'ArrayRef[Str]');
has 'logger'            => (is => 'ro', default => sub { AI::MXNet::Logging->get_logger });
has '_p'                => (is => 'rw', init_arg => undef);
has 'context'           => (
    is => 'ro', 
    isa => 'AI::MXNet::Context|ArrayRef[AI::MXNet::Context]',
    default => sub { AI::MXNet::Context->cpu }
);

sub BUILD
{
    my $self = shift;
    $self->_p(AI::MXNet::Module::Private->new);
    my $context = $self->context;
    if(blessed $context)
    {
        $context = [$context];
    }
    $self->_p->_context($context);
    my $work_load_list = $self->work_load_list;
    if(not defined $work_load_list)
    {
        $work_load_list = [(1)x@{$self->_p->_context}];
    }
    assert(@{ $work_load_list } == @{ $self->_p->_context });
    $self->_p->_work_load_list($work_load_list);
    my @data_names  = @{ $self->data_names };
    my @label_names = @{ $self->label_names//[] };
    my $arg_names   = $self->_symbol->list_arguments;
    my @input_names = (@data_names, @label_names);
    my %input_names = map { $_ => 1 } @input_names;
    $self->_p->_param_names([grep { not exists $input_names{$_} } @{ $arg_names }]);
    $self->_p->_fixed_param_names($self->fixed_param_names);
    $self->_p->_aux_names($self->_symbol->list_auxiliary_states);
    $self->_p->_data_names(\@data_names);
    $self->_p->_label_names(\@label_names);
    $self->_p->_output_names($self->_symbol->list_outputs);
    $self->_p->_params_dirty(0);
    $self->data_names($self->_p->_data_names);
}

=head load

        Create a model from previously saved checkpoint.

        Parameters
        ----------
        prefix : str
            path prefix of saved model files. You should have
            "prefix-symbol.json", "prefix-xxxx.params", and
            optionally "prefix-xxxx.states", where xxxx is the
            epoch number.
        epoch : int
            epoch to load.
        load_optimizer_states : bool
            whether to load optimizer states. Checkpoint needs
            to have been made with save_optimizer_states=True.
        data_names : list of str
            Default is `('data')` for a typical model used in image classification.
        label_names : list of str
            Default is `('softmax_label')` for a typical model used in image
            classification.
        logger : Logger
            Default is `logging`.
        context : Context or list of Context
            Default is `cpu()`.
        work_load_list : list of number
            Default `None`, indicating uniform workload.
        fixed_param_names: list of str
            Default `None`, indicating no network parameters are fixed.
=cut

method load(
    Str $prefix,
    Int $epoch,
    Bool $load_optimizer_states=0,
    %kwargs
)
{
    my ($sym, $args, $auxs) = load_checkpoint($prefix, $epoch);
    my $mod = $self->new(symbol => $sym, %kwargs);
    $mod->_p->_arg_params($args);
    $mod->_p->_aux_params($auxs);
    if($mod->params_initialized)
    {
        if($load_optimizer_states)
        {
            $mod->_p->_preload_opt_states(sprintf('%s-%04d.states', $prefix, $epoch));
        }
    }
    return $mod;
}

=head2 save_checkpoint

        Save current progress to checkpoint.
        Use mx.callback.module_checkpoint as epoch_end_callback to save during training.

        Parameters
        ----------
        prefix : str
            The file prefix to checkpoint to
        epoch : int
            The current epoch number
        save_optimizer_states : bool
            Whether to save optimizer states for continue training
=cut


method save_checkpoint(Str $prefix, Int $epoch, Bool $save_optimizer_states=0)
{
    $self->_symbol->save("$prefix-symbol.json");
    my $param_name = sprintf('%s-%04d.params', $prefix, $epoch);
    $self->save_params($param_name);
    AI::MXNet::Logging->info('Saved checkpoint to "%s"', $param_name);
    if($save_optimizer_states)
    {
        my $state_name = sprintf('%s-%04d.states', $prefix, $epoch);
        $self->save_optimizer_states($state_name);
        AI::MXNet::Logging->info('Saved optimizer state to "%s"', $state_name);
    }
}

# Internal function to reset binded state.
method _reset_bind()
{
    $self->binded(0);
    $self->_p->_exec_group(undef);
    $self->_p->_data_shapes(undef);
    $self->_p->_label_shapes(undef);
}

=head2 data_names

        A list of names for data required by this module.
=cut

=head2 output_names

        A list of names for data required by this module.
=cut

method output_names()
{
    return $self->_p->_output_names;
}

=head2 data_shapes

        Get data shapes.
        Returns
        -------
        A list of AI::MXNet::DataDesc objects.
=cut

method data_shapes()
{
    assert($self->binded);
    return $self->_p->_data_shapes;
}

=head2 data_shapes

        Get label shapes.
        Returns
        -------
        A list of AI::MXNet::DataDesc objects. The return value could be undef if
        the module does not need labels, or if the module is not binded for
        training (in this case, label information is not available).
=cut

method label_shapes()
{
    assert($self->binded);
    return $self->_p->_label_shapes;
}

=head2 output_shapes

        Get output shapes.
        Returns
        -------
        A list of AI::MXNet::DataDesc objects.
=cut

method output_shapes()
{
    assert($self->binded);
    return $self->_p->_exec_group->get_output_shapes;
}

=head2 get_params

        Get current parameters.
        Returns
        -------
        `(arg_params, aux_params)`, each a dictionary of name to parameters (in
        `NDArray`) mapping.
=cut

method get_params()
{
    assert($self->binded and $self->params_initialized);
    if($self->_p->_params_dirty)
    {
        $self->_sync_params_from_devices();
    }
    return ($self->_p->_arg_params, $self->_p->_aux_params);
}

=head2 init_params

        Initialize the parameters and auxiliary states.

        Parameters
        ----------
        initializer : Initializer
            Called to initialize parameters if needed.
        arg_params : dict
            If not None, should be a dictionary of existing arg_params. Initialization
            will be copied from that.
        aux_params : dict
            If not None, should be a dictionary of existing aux_params. Initialization
            will be copied from that.
        allow_missing : bool
            If true, params could contain missing values, and the initializer will be
            called to fill those missing params.
        force_init : bool
            If true, will force re-initialize even if already initialized.
=cut

method init_params(
    Maybe[AI::MXNet::Initializer]      :$initializer=AI::MXNet::Initializer->Uniform(scale => 0.01),
    Maybe[HashRef[AI::MXNet::NDArray]] :$arg_params=,
    Maybe[HashRef[AI::MXNet::NDArray]] :$aux_params=,
    Bool                               :$allow_missing=0,
    Bool                               :$force_init=0
)
{
    if($self->params_initialized and not $force_init)
    {
        return;
    }
    assert($self->binded, 'call bind before initializing the parameters');
    if(not defined $self->_p->_arg_params)
    {
        my @param_arrays = (
            map { AI::MXNet::NDArray->zeros($_->[0]->shape, dtype => $_->[0]->dtype) }
            @{ $self->_p->_exec_group->_p->param_arrays }
        );
        my %arg_params;
        @arg_params{ @{ $self->_p->_param_names } } = @param_arrays;
        $self->_p->_arg_params(\%arg_params);
    }
    if(not defined $self->_p->_aux_params)
    {
        my @aux_arrays = (
            map { AI::MXNet::NDArray->zeros($_->[0]->shape, dtype => $_->[0]->dtype) }
            @{ $self->_p->_exec_group->_p->aux_arrays }
        );
        my %aux_params;
        @aux_params{ @{ $self->_p->_aux_names } } = @aux_arrays;
        $self->_p->_aux_params(\%aux_params);
    }
    my $_impl = sub {
            my ($name, $arr, $cache) = @_;
            # Internal helper for parameter initialization
            if(defined $cache)
            {
                if(exists $cache->{$name})
                {
                    my $cache_arr = $cache->{$name};
                    # just in case the cached array is just the target itself
                    if($cache_arr->handle ne $arr->handle)
                    {
                        $cache_arr->copyto($arr);
                    }
                }
                else
                {
                    if(not $allow_missing)
                    {
                        confess("$name is not presented");
                    }
                    if(defined $initializer)
                    {
                        &{$initializer}($name, $arr);
                    }
                }
            }
            else
            {
                &{$initializer}($name, $arr) if defined $initializer;
            }
    };
    while(my ($name, $arr) = each %{ $self->_p->_arg_params })
    {
        $_impl->($name, $arr, $arg_params);
    }
    while(my ($name, $arr) = each %{ $self->_p->_aux_params })
    {
        $_impl->($name, $arr, $aux_params);
    }
    $self->params_initialized(1);
    $self->_p->_params_dirty(0);

    # copy the initialized parameters to devices
    $self->_p->_exec_group->set_params($self->_p->_arg_params, $self->_p->_aux_params);
}

=head2 bind

        Bind the symbols to construct executors. This is necessary before one
        can perform computation with the module.

        Parameters
        ----------
        data_shapes : list of (str, tuple)
            Typically is `data_iter.provide_data`.
        label_shapes : list of (str, tuple)
            Typically is `data_iter.provide_label`.
        for_training : bool
            Default is `True`. Whether the executors should be bind for training.
        inputs_need_grad : bool
            Default is `False`. Whether the gradients to the input data need to be computed.
            Typically this is not needed. But this might be needed when implementing composition
            of modules.
        force_rebind : bool
            Default is `False`. This function does nothing if the executors are already
            binded. But with this `True`, the executors will be forced to rebind.
        shared_module : Module
            Default is `None`. This is used in bucketing. When not `None`, the shared module
            essentially corresponds to a different bucket -- a module with different symbol
            but with the same sets of parameters (e.g. unrolled RNNs with different lengths).
=cut

method bind(
    ArrayRef[AI::MXNet::DataDesc|NameShape]        :$data_shapes,
    Maybe[ArrayRef[AI::MXNet::DataDesc|NameShape]] :$label_shapes=,
    Bool                                           :$for_training=1,
    Bool                                           :$inputs_need_grad=0,
    Bool                                           :$force_rebind=0,
    Maybe[AI::MXNet::Module]                       :$shared_module=,
    GradReq|HashRef[GradReq]|ArrayRef[GradReq]     :$grad_req='write'
)
{
    # force rebinding is typically used when one want to switch from
    # training to prediction phase.
    if($force_rebind)
    {
        $self->_reset_bind();
    }
    if($self->binded)
    {
        $self->logger->warning('Already binded, ignoring bind()');
        return;
    }
    $self->for_training($for_training);
    $self->inputs_need_grad($inputs_need_grad);
    $self->binded(1);

    if(not $for_training)
    {
        assert(not $inputs_need_grad);
    }
    $self->_p->_data_shapes([
        map {
            blessed $_ ? $_ : AI::MXNet::DataDesc->new(name => $_->[0], shape => $_->[1])
        } @{ $data_shapes }
    ]);

    if($label_shapes)
    {
        $self->_p->_label_shapes([
            map {
                blessed $_ ? $_ : AI::MXNet::DataDesc->new(name => $_->[0], shape => $_->[1]) 
            } @{ $label_shapes }
        ]);
    }
    else
    {
        $self->_p->_label_shapes(undef);
    }

    my $shared_group;
    if($shared_module)
    {
        assert($shared_module->binded and $shared_module->params_initialized);
        $shared_group = $shared_module->_p->_exec_group;
    }

    my %input_types = map { $_->name => $_->dtype } @{ $self->_p->_data_shapes };
    if($self->_p->_label_shapes)
    {
        %input_types = (%input_types, map { $_->name => $_->dtype } @{ $self->_p->_label_shapes });
    }
    $self->_p->_exec_group(
        AI::MXNet::DataParallelExecutorGroup->new(
            symbol            => $self->_symbol,
            contexts          => $self->_p->_context,
            workload          => $self->_p->_work_load_list,
            data_shapes       => $self->_p->_data_shapes,
            label_shapes      => $self->_p->_label_shapes,
            param_names       => $self->_p->_param_names,
            for_training      => $for_training,
            inputs_need_grad  => $inputs_need_grad,
            shared_group      => $shared_group,
            logger            => $self->logger,
            fixed_param_names => $self->_p->_fixed_param_names,
            grad_req          => $grad_req,
            input_types       => \%input_types
        )
    );
    if($shared_module)
    {
        $self->params_initialized(1);
        $self->_p->_arg_params($shared_module->_p->_arg_params);
        $self->_p->_aux_params($shared_module->_p->_aux_params);
    }
    elsif($self->params_initialized)
    {
        # if the parameters are already initialized, we are re-binding
        # so automatically copy the already initialized params
        $self->_p->_exec_group->set_params($self->_p->_arg_params, $self->_p->_aux_params);
    }
    if($shared_module and $shared_module->optimizer_initialized)
    {
        $self->borrow_optimizer($shared_module)
    }
}

=head2 init_optimizer

        Install and initialize optimizers.

        Parameters
        ----------
        kvstore : str or KVStore
            Default `'local'`.
        optimizer : str or Optimizer
            Default `'sgd'`
        optimizer_params : dict
            Default { learning_rate => 0.01 }.
        force_init : bool
            Default `False`, indicating whether we should force re-initializing the
            optimizer in the case an optimizer is already installed.
=cut

method init_optimizer(
    Str|AI::MXNet::KVStore :$kvstore='local',
    Optimizer              :$optimizer='sgd',
    HashRef                :$optimizer_params={ learning_rate => 0.01 },
    Bool                   :$force_init=0
)
{
    assert($self->binded and $self->params_initialized);
    if($self->optimizer_initialized and not $force_init)
    {
        $self->logger->warning('optimizer already initialized, ignoring...');
        return;
    }

    my ($kvstore, $update_on_kvstore) = _create_kvstore(
        $kvstore,
        scalar(@{$self->_p->_context}),
        $self->_p->_arg_params
    );
    if(not blessed $optimizer)
    {
        my $batch_size = $self->_p->_exec_group->_p->batch_size;
        if($kvstore and $kvstore->type eq 'dist_sync')
        {
            $batch_size *= $kvstore->num_workers;
        }
        my %idx2name;
        if($update_on_kvstore)
        {
            @idx2name{ 0..@{$self->_p->_exec_group->param_names}-1 } = @{$self->_p->_exec_group->param_names};
        }
        else
        {
            for my $k (0..@{$self->_p->_context}-1)
            {
                @idx2name{ map { $_ + $k } 0..@{$self->_p->_exec_group->param_names}-1 } = @{$self->_p->_exec_group->param_names};
            }
        }
        if(not exists $optimizer_params->{rescale_grad})
        {
            $optimizer_params->{rescale_grad} = 1/$batch_size;
        }
        $optimizer = AI::MXNet::Optimizer->create(
            $optimizer,
            sym  => $self->symbol,
            param_idx2name => \%idx2name,
            %{ $optimizer_params }
        );
    }

    $self->_p->_optimizer($optimizer);
    $self->_p->_kvstore($kvstore);
    $self->_p->_update_on_kvstore($update_on_kvstore);
    $self->_p->_updater(undef);

    if($kvstore)
    {
        # copy initialized local parameters to kvstore
        _initialize_kvstore(
            kvstore           => $kvstore,
            param_arrays      => $self->_p->_exec_group->param_arrays,
            arg_params        => $self->_p->_arg_params,
            param_names       => $self->_p->_param_names,
            update_on_kvstore => $update_on_kvstore
        );
    }
    if($update_on_kvstore)
    {
        $kvstore->set_optimizer($self->_p->_optimizer);
    }
    else
    {
        $self->_p->_updater(AI::MXNet::Optimizer->get_updater($optimizer));
    }
    $self->optimizer_initialized(1);

    if($self->_p->_preload_opt_states)
    {
        $self->load_optimizer_states($self->_p->_preload_opt_states);
        $self->_p->_preload_opt_states(undef);
    }
}

=head2 borrow_optimizer

        Borrow optimizer from a shared module. Used in bucketing, where exactly the same
        optimizer (esp. kvstore) is used.

        Parameters
        ----------
        shared_module : Module
=cut

method borrow_optimizer(AI::MXNet::Module $shared_module)
{
    assert($shared_module->optimizer_initialized);
    $self->_p->_optimizer($shared_module->_p->_optimizer);
    $self->_p->_kvstore($shared_module->_p->_kvstore);
    $self->_p->_update_on_kvstore($shared_module->_p->_update_on_kvstore);
    $self->_p->_updater($shared_module->_p->_updater);
    $self->optimizer_initialized(1);
}

=head2 forward

        Forward computation.

        Parameters
        ----------
        data_batch : DataBatch
            Could be anything with similar API implemented.
        is_train : bool
            Default is `None`, which means `is_train` takes the value of `self.for_training`.
=cut

method forward(
    AI::MXNet::DataBatch $data_batch,
    Maybe[Bool]         :$is_train=
)
{
    assert($self->binded and $self->params_initialized);
    $self->_p->_exec_group->forward($data_batch, $is_train);
}

=head2 backward

        Backward computation.

        Parameters
        ----------
        out_grads : NDArray or list of NDArray, optional
            Gradient on the outputs to be propagated back.
            This parameter is only needed when bind is called
            on outputs that are not a loss function.
=cut

method backward(Maybe[AI::MXNet::NDArray|ArrayRef[AI::MXNet::NDArray]] $out_grads=)
{
    assert($self->binded and $self->params_initialized);
    $self->_p->_exec_group->backward($out_grads);
}

=head2 update

        Update parameters according to the installed optimizer and the gradients computed
        in the previous forward-backward batch.
=cut

method update()
{
    assert($self->binded and $self->params_initialized and $self->optimizer_initialized);
    $self->_p->_params_dirty(1);
    if($self->_p->_update_on_kvstore)
    {
        _update_params_on_kvstore(
            $self->_p->_exec_group->param_arrays,
            $self->_p->_exec_group->grad_arrays,
            $self->_p->_kvstore
        );
    }
    else
    {
        _update_params(
            $self->_p->_exec_group->_p->param_arrays,
            $self->_p->_exec_group->_p->grad_arrays,
            $self->_p->_updater,
            scalar(@{ $self->_p->_context}),
            $self->_p->_kvstore
        );
    }
}

=head2 get_optputs

        Get outputs of the previous forward computation.

        Parameters
        ----------
        merge_multi_context : bool
            Default is `True`. In the case when data-parallelism is used, the outputs
            will be collected from multiple devices. A `True` value indicate that we
            should merge the collected results so that they look like from a single
            executor.

        Returns
        -------
        If `merge_multi_context` is `True`, it is like `[out1, out2]`. Otherwise, it
        is like `[[out1_dev1, out1_dev2], [out2_dev1, out2_dev2]]`. All the output
        elements are `NDArray`.
=cut

method get_outputs(Bool $merge_multi_context=1)
{
    assert($self->binded and $self->params_initialized);
    return $self->_p->_exec_group->get_outputs($merge_multi_context);
}

=head2 get_input_grads

        Get the gradients with respect to the inputs of the module.

        Parameters
        ----------
        merge_multi_context : bool
            Default is `True`. In the case when data-parallelism is used, the outputs
            will be collected from multiple devices. A `True` value indicate that we
            should merge the collected results so that they look like from a single
            executor.

        Returns
        -------
        If `merge_multi_context` is `True`, it is like `[grad1, grad2]`. Otherwise, it
        is like `[[grad1_dev1, grad1_dev2], [grad2_dev1, grad2_dev2]]`. All the output
        elements are `NDArray`.
=cut

method get_input_grads(Bool $merge_multi_context=1)
{
    assert($self->binded and $self->params_initialized and $self->inputs_need_grad);
    return $self->_p->_exec_group->get_input_grads($merge_multi_context);
}

=head2 update_metric
        Evaluate and accumulate evaluation metric on outputs of the last forward computation.

        Parameters
        ----------
        eval_metric : EvalMetric
        labels : list of NDArray
            Typically `data_batch.label`.
=cut
method update_metric(
    AI::MXNet::EvalMetric $eval_metric,
    ArrayRef[AI::MXNet::NDArray] $labels
)
{
    $self->_p->_exec_group->update_metric($eval_metric, $labels);
}

=head2 _sync_params_from_devices

        Synchronize parameters from devices to CPU. This function should be called after
        calling `update` that updates the parameters on the devices, before one can read the
        latest parameters from `self._arg_params` and `self._aux_params`.
=cut

method _sync_params_from_devices()
{
    $self->_p->_exec_group->get_params($self->_p->_arg_params, $self->_p->_aux_params);
}

=head2 save_optimizer_states

        Save optimizer (updater) state to file

        Parameters
        ----------
        fname : str
            Path to output states file.
=cut

method save_optimizer_states(Str $fname)
{
    assert($self->optimizer_initialized);
    if($self->_p->_update_on_kvstore)
    {
        $self->_p->_kvstore->save_optimizer_states($fname);
    }
    else
    {
        open(F, ">:raw", "$fname") or confess("can't open $fname for writing: $!");
        print F $self->_p->_updater->get_states();
        close(F);
    }
}

=head2 load_optimizer_states

        Load optimizer (updater) state from file

        Parameters
        ----------
        fname : str
            Path to input states file.
=cut

method load_optimizer_states(Str $fname)
{
    assert($self->optimizer_initialized);
    if($self->_p->_update_on_kvstore)
    {
        $self->_p->_kvstore->load_optimizer_states($fname);
    }
    else
    {
        open(F, "<:raw", "$fname") or confess("can't open $fname for reading: $!");
        my $data;
        { local($/) = undef; $data = <F>; }
        close(F);
        $self->_p->_updater->set_states($data);
    }
}

=head2 install_monitor

        Install monitor on all executors.

        Paramters
        ---------
        AI::MXNet::Monitor
=cut

method install_monitor(AI::MXNet::Monitor $mon)
{
    assert($self->binded);
    $self->_p->_exec_group->install_monitor($mon);
}


1;