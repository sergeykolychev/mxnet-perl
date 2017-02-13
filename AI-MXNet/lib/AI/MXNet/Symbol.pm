package AI::MXNet::Symbol;
use strict;
use warnings;
use AI::MXNet::Base;
use AI::MXNet::Symbol::Base;
use AI::MXNet::Types;
use Mouse;
use AI::MXNet::Function::Parameters;
use overload
    '""'  => \&stringify,
    '+'   => \&add,
    '-'   => \&subtract,
    '*'   => \&multiply,
    '/'   => \&divide,
    '/='  => \&idivide,
    '**'  => \&power,
    '=='  => \&equal,
    '!='  => \&not_equal,
    '>'   => \&greater,
    '>='  => \&greater_equal,
    '<'   => \&lesser,
    '<='  => \&lesser_equal,
    '&{}' => sub { my $self = shift; sub { $self->call(@_) } };

extends 'AI::MXNet::Symbol::Base';
has 'handle'   => (is => 'rw', isa => 'SymbolHandle', required => 1);

sub DEMOLISH
{
    check_call(AI::NNVMCAPI::SymbolFree(shift->handle));
}

method STORABLE_freeze($cloning)
{
    return $self->tojson();
}

method STORABLE_thaw($cloning, $json)
{
    my $handle = check_call(
        AI::MXNetCAPI::SymbolCreateFromJSON(
            $json
        )
    );
    $self->handle($handle);
}

method stringify($other=, $reverse=)
{
    my $name = $self->name;
    sprintf("<%s %s>", ref($self), $name ? $name : 'Grouped');
}

method add(AI::MXNet::Symbol|Num $other, $reverse=)
{
    return _ufunc_helper(
        $self,
        $other,
        qw/_Plus _PlusScalar/
    );
}

method subtract(AI::MXNet::Symbol|Num $other, $reverse=)
{
    return _ufunc_helper(
        $self,
        $other,
        qw/_Minus _MinusScalar _RMinusScalar/,
        $reverse
    );
}

method multiply(AI::MXNet::Symbol|Num $other, $reverse=)
{
    return _ufunc_helper(
        $self,
        $other,
        qw/_Mul _MulScalar/
    );
}

method divide(AI::MXNet::Symbol|Num $other, $reverse=)
{
    return _ufunc_helper(
        $self,
        $other,
        qw/_Div _DivScalar _RDivScalar/,
        $reverse
    );
}

method power(AI::MXNet::Symbol|Num $other, $reverse=)
{
    return _ufunc_helper(
        $self,
        $other,
        qw/_Power _PowerScalar _RPowerScalar/,
        $reverse
    );
}

method equal(AI::MXNet::Symbol|Num $other, $reverse=)
{
    return _ufunc_helper(
        $self,
        $other,
        qw/_equal _equal_scalar/
    );
}

method not_equal(AI::MXNet::Symbol|Num $other, $reverse=)
{
    return _ufunc_helper(
        $self,
        $other,
        qw/_not_equal _not_equal_scalar/
    );
}

method greater(AI::MXNet::Symbol|Num $other, $reverse=)
{
    return _ufunc_helper(
        $self,
        $other,
        qw/_greater _greater_scalar _lesser_scalar/,
        $reverse
    );
}

method greater_equal(AI::MXNet::Symbol|Num $other, $reverse=)
{
    return _ufunc_helper(
        $self,
        $other,
        qw/_greater_equal _greater_equal_scalar _lesser_equal_scalar/,
        $reverse
    );
}

method lesser(AI::MXNet::Symbol|Num $other, $reverse=)
{
    return _ufunc_helper(
        $self,
        $other,
        qw/_lesser _lesser_scalar _greater_scalar/,
        $reverse
    );
}

method lesser_equal(AI::MXNet::Symbol|Num $other, $reverse=)
{
    return _ufunc_helper(
        $self,
        $other,
        qw/_lesser_equal _lesser_equal_scalar _greater_equal_scalar/,
        $reverse
    );
}

method true_divide(AI::MXNet::Symbol|Num $other, $reverse=)
{
    return $self->divide($other, $reverse);
}

method maximum(AI::MXNet::Symbol|Num $other)
{
    return _ufunc_helper(
        $self,
        $other,
        qw/_Maximum _MaximumScalar/
    );
}

method minimum(AI::MXNet::Symbol|Num $other)
{
    return _ufunc_helper(
        $self,
        $other,
        qw/_Minimum _MinimumScalar/
    );
}

method hypot(AI::MXNet::Symbol|Num $other)
{
    return _ufunc_helper(
        $self,
        $other,
        qw/_Hypot _HypotScalar/
    );
}

method deepcopy()
{
    my $handle = check_call(AI::MXNetCAPI::SymbolCopy($self->handle));
    return __PACKAGE__->new(handle => $handle);
}

=head2 call
        Invoke symbol as function on inputs.

        Parameters
        ----------
        args:
            provide positional arguments

        kwargs:
            provide keyword arguments
        Returns
        -------
        the resulting symbol
=cut

method call(ArrayRef $args, HashRef $kwargs)
{
    my $s = $self->deepcopy();
    $s->_compose(@$args, $kwargs);
    return $s;
}

method slice(ArrayRef|HashRef|Str|Index @args)
{
    confess("No arguments supplied") unless @args;
    ## __getitem__ tie needs to die
    if(not grep { ref } @args)
    {
        confess("can only get one item from the symbol")
            if @args > 1;
        my $index = $args[0];
        if(not find_type_constraint('Index')->check($index))
        {
            my $i = 0;
            my $idx;
            for my $name (@{ $self->list_outputs() })
            {
                if($name eq $index)
                {
                    if(defined $idx)
                    {
                        confess(qq/There are multiple outputs with name "$index"/);
                    }
                    $idx = $i;
                }
                $i++;
            }
            confess(qq/Cannot find output that matches name "$index"/) unless defined $idx;
            $index = $idx;
        }
        my $handle = check_call(AI::MXNetCAPI::SymbolGetOutput($self->handle, $index));
        return __PACKAGE__->new(handle => $handle);
    }
    else
    {
        confess("call expects no more than two arguments that must be either hash or array refs")
            unless(@args > 2 or grep { not ref } @args);
        my @call_args;
        if(@args == 1)
        {
            if(ref($args[0]) eq 'HASH')
            {
                @call_args = ([], $args[0]);
            }
            else
            {
                @call_args = ($args[0], {});
            }
        }
        else
        {
            my @hash = grep { ref($_) eq 'HASH' } @args;
            my @array = grep { ref($_) eq 'ARRAY' } @args;
            confess("call expects no more than one hash ref and no more than one array ref")
                unless(@hash == 1 and @array == 1);
            @call_args = ($array[0], $hash[0]);
        }
        return &{$self}(@call_args);
    }
}

=head2 name

        Get name string from the symbol, this function only works for non-grouped symbol.

        Returns
        -------
        value : str
            The name of this symbol, returns None for grouped symbol.
=cut

method name()
{
    my ($name, $success) = check_call(AI::MXNetCAPI::SymbolGetName($self->handle));
    return $success ? $name : undef;
}

=head2 attr

        Get attribute string from the symbol, this function only works for non-grouped symbol.

        Parameters
        ----------
        key : str
            The key to get attribute from.

        Returns
        -------
        value : str
            The attribute value of the key, returns None if attribute do not exist.
=cut


method attr(Str $key)
{
    my ($attr, $success) = check_call(
        AI::MXNetCAPI::SymbolGetAttr($self->handle, $key)
    );
    return $success ? $attr : undef;
}

=head2 list_attr

        Get all attributes from the symbol.

        Returns
        -------
        ret : dict of str to str
            a dicitonary mapping attribute keys to values
=cut

method list_attr()
{
    my %ret;
    my @attrs = @{ check_call(AI::MXNetCAPI::SymbolListAttrShallow($self->handle)) };
    while(@attrs)
    {
        $ret{ shift(@attrs) } = shift(@attrs);
    }
    return \%ret;
}

=head2 attr_dict

        Recursively get all attributes from the symbol and its childrens

        Returns
        -------
        ret : dict of str to dict
            Returns a dict whose keys are names of the symbol and its children.
            Values of the returned dict are dictionaries that map attribute keys to values
=cut

method attr_dict()
{
    my %ret;
    my @attrs = @{ check_call(AI::MXNetCAPI::SymbolListAttr($self->handle)) };
    my $size = @attrs/2; 
    for (my $i = 0; $i < $size; $i++)
    {
        my ($name, $key) = split(/\$/, $attrs[$i*2]);
        my $val = $attrs[$i*2+1];
        $ret{ $name }{ $key } = $val;
    }
    return \%ret;
}

method _set_attr(Str @args)
{
    my %kwargs = @args; 
    while(my ($key, $val) = each(%kwargs))
    {
        check_call(
            AI::MXNetCAPI::SymbolSetAttr(
                $self->handle, $key, $val
            )
        );
    }
}

=head2 get_internals
        Get a new grouped symbol whose output contains all the internal outputs of this symbol.

        Returns
        -------
        sgroup : Symbol
            The internal of the symbol.
=cut

method get_internals()
{
    my $handle = check_call(AI::MXNetCAPI::SymbolGetInternals($self->handle));
    return __PACKAGE__->new(handle => $handle);
}

=head2 list_arguments

        List all the arguments in the symbol.

        Returns
        -------
        args : list of string
            List of all the arguments.
=cut

method list_arguments()
{
    return scalar(check_call(AI::MXNetCAPI::SymbolListArguments($self->handle)));
}

=head2 list_outputs()

        List all outputs in the symbol.

        Returns
        -------
        returns : list of string
            List of all the outputs.
=cut

method list_outputs()
{
    return scalar(check_call(AI::MXNetCAPI::SymbolListOutputs($self->handle)));
}


=head2 list_auxiliary_states()

        List all auxiliary states in the symbol.

        Returns
        -------
        aux_states : list of string
            List the names of the auxiliary states.

        Notes
        -----
        Auxiliary states are special states of symbols that do not corresponds to an argument,
        and do not have gradient. But still be useful for the specific operations.
        A common example of auxiliary state is the moving_mean and moving_variance in BatchNorm.
        Most operators do not have Auxiliary states.
=cut

method list_auxiliary_states()
{
    return scalar(check_call(AI::MXNetCAPI::SymbolListAuxiliaryStates($self->handle)));
}


=head2 infer_type

        Infer the type of outputs and arguments of given known types of arguments.

        User can either pass in the known types in positional way or keyword argument way.
        Tuple of Nones is returned if there is not enough information passed in.
        An error will be raised if there is inconsistency found in the known types passed in.

        Parameters
        ----------
        args : Array
            Provide type of arguments in a positional way.
            Unknown type can be marked as None

        kwargs : Hash ref, must ne ssupplied as as sole argument to the method.
            Provide keyword arguments of known types.

        Returns
        -------
        arg_types : list of numpy.dtype or None
            List of types of arguments.
            The order is in the same order as list_arguments()
        out_types : list of numpy.dtype or None
            List of types of outputs.
            The order is in the same order as list_outputs()
        aux_types : list of numpy.dtype or None
            List of types of outputs.
            The order is in the same order as list_auxiliary()
=cut


method infer_type(Str|Undef @args)
{
    my ($positional_arguments, $kwargs, $kwargs_order) = _parse_arguments("Dtype", @args); 
    my $sdata = [];
    my $keys  = [];
    if(@$positional_arguments)
    {
        @{ $sdata } = map { defined($_) ? DTYPE_STR_TO_MX->{ $_ } : -1 } @{ $positional_arguments };
    }
    else
    {
        @{ $keys }  = @{ $kwargs_order };
        @{ $sdata } = map { DTYPE_STR_TO_MX->{ $_ } } @{ $kwargs }{ @{ $kwargs_order } };
    }
    my ($arg_type, $out_type, $aux_type, $complete) = check_call(AI::MXNetCAPI::SymbolInferType(
            $self->handle,
            scalar(@{ $sdata }),
            $keys,
            $sdata
        )
    );
    if($complete)
    {
        return (
            [ map { DTYPE_MX_TO_STR->{ $_ } } @{ $arg_type }],
            [ map { DTYPE_MX_TO_STR->{ $_ } } @{ $out_type }],
            [ map { DTYPE_MX_TO_STR->{ $_ } } @{ $aux_type }]
        );
    }
    else
    {
        return (undef, undef, undef);
    }
}

=head2 infer_shape

        Infer the shape of outputs and arguments of given known shapes of arguments.

        User can either pass in the known shapes in positional way or keyword argument way.
        Tuple of Nones is returned if there is not enough information passed in.
        An error will be raised if there is inconsistency found in the known shapes passed in.

        Parameters
        ----------
        *args :
            Provide shape of arguments in a positional way.
            Unknown shape can be marked as None

        **kwargs :
            Provide keyword arguments of known shapes.

        Returns
        -------
        arg_shapes : list of tuple or None
            List of shapes of arguments.
            The order is in the same order as list_arguments()
        out_shapes : list of tuple or None
            List of shapes of outputs.
            The order is in the same order as list_outputs()
        aux_shapes : list of tuple or None
            List of shapes of outputs.
            The order is in the same order as list_auxiliary()
=cut

method infer_shape(Maybe[Str|Shape] @args)
{
    $self->_infer_shape_impl(0, @args)
}

=head2 infer_shape_partial

        Partially infer the shape. The same as infer_shape, except that the partial
        results can be returned.
=cut

method infer_shape_partial(Maybe[Str|Shape] @args)
{
    $self->_infer_shape_impl(1, @args)
}

# The actual implementation for calling shape inference API.
method _infer_shape_impl(Maybe[Str|Shape] @args)
{
    my $partial = shift(@args);
    my ($positional_arguments, $kwargs, $kwargs_order) = _parse_arguments("Shape", @args);
    my $sdata = [];
    my $indptr = [0];
    my $keys = [];
    if(@{ $positional_arguments })
    {
        for my $shape (grep { defined } @{ $positional_arguments })
        {
            push @{ $sdata }, @{ $shape };
            push @{ $indptr }, scalar(@{ $sdata });
        }
    }
    {
        for my $k (@{ $kwargs_order })
        {
            push @{ $keys }, $k;
            push @{ $sdata }, @{ $kwargs->{ $k } };
            push @{ $indptr }, scalar(@{ $sdata });
        }
    }
    my $infer_func = $partial ? \&AI::MXNetCAPI::SymbolInferShapePartial : \&AI::MXNetCAPI::SymbolInferShape;
    my ($arg_shapes, $out_shapes, $aux_shapes, $complete) = check_call(
        $infer_func->(
            $self->handle,
            scalar(@{ $indptr }) - 1,
            $keys,
            $indptr,
            $sdata,
        )
    );
    if($complete)
    {
        return $arg_shapes, $out_shapes, $aux_shapes;
    }
    else
    {
        return (undef, undef, undef);
    }
}

=head2 debug_str

        Get a debug string.

        Returns
        -------
        debug_str : string
            Debug string of the symbol.
=cut

method debug_str()
{
    return scalar(check_call(AI::MXNetCAPI::SymbolPrint($self->handle)));
}

=head2 save

        Save symbol into file.

        You can also use Storable to do the job if you only work on Perl.
        The advantage of load/save is the file is language agnostic.
        This means the file saved using save can be loaded by other language binding of mxnet.
        You also get the benefit being able to directly load/save from cloud storage(S3, HDFS)

        Parameters
        ----------
        fname : str
            The name of the file
            - s3://my-bucket/path/my-s3-symbol
            - hdfs://my-bucket/path/my-hdfs-symbol
            - /path-to/my-local-symbol

        See Also
        --------
        load : Used to load symbol from file.
=cut

method save(Str $fname)
{
    check_call(AI::MXNetCAPI::SymbolSaveToFile($self->handle, $fname));
}

=head2 tojson

        Save symbol into a JSON string.

        See Also
        --------
        load_json : Used to load symbol from JSON string.
=cut

method tojson()
{
    return scalar(check_call(AI::MXNetCAPI::SymbolSaveToJSON($self->handle)));
}


=head2 _get_ndarray_inputs

        Helper function to get ndarray lists handles from various inputs.

        Parameters
        ----------
        arg_key : str
            The name of argument, used for error message.

        args : list of NDArray or dict of str to NDArray
            Input arguments to the symbols.
            If type is list of NDArray, the position is in the same order of arg_names.
            If type is dict of str to NDArray, then it maps the name of arguments
            to the corresponding NDArray,

        args_names : list of string
            List of argument names.

        allow_missing : boolean
            Whether missing argument is allowed.
            When allowed, the missing handle will be set to None(null)

        Returns
        -------
        handles : list of NDArrayHandle
            The positional list of NDArrayHandles generated from input.
=cut


method _get_ndarray_inputs(
    Str                                                      $arg_key,
    HashRef[AI::MXNet::NDArray]|ArrayRef[AI::MXNet::NDArray] $args,
    ArrayRef[Str]                                            $arg_names,
    Bool                                                     $allow_missing=0
)
{
    my ($arg_handles, $arg_arrays) = ([], []);
    if(ref $args eq 'ARRAY')
    {
        confess("Length of $arg_key do not match number of arguments") 
            unless @$args == @$arg_names;
        @{ $arg_handles } = map { $_->handle } @{ $args };
        $arg_arrays = $args;
    }
    else
    {
        my %tmp = ((map { $_ => undef } @$arg_names), %$args);
        if(not $allow_missing and grep { not defined } values %tmp)
        {
            my ($missing) = grep { not defined $tmp{ $_ } } (keys %tmp);
            confess("key $missing is missing in $arg_key");
        }
        for my $name (@$arg_names)
        {
            push @$arg_handles, defined($tmp{ $name }) ? $tmp{ $name }->handle : undef;
            push @$arg_arrays, defined($tmp{ $name }) ? $tmp{ $name } : undef;
        }
    }
    return ($arg_handles, $arg_arrays);
}

=head2 simple_bind

        Bind current symbol to get an executor, allocate all the ndarrays needed.
        Allows specifying data types.

        This function will ask user to pass in ndarray of position
        they like to bind to, and it will automatically allocate the ndarray
        for arguments and auxiliary states that user did not specify explicitly.

        Parameters
        ----------
        ctx : Context
            The device context the generated executor to run on.

        grad_req: string
            {'write', 'add', 'null'}, or list of str or dict of str to str, optional
            Specifies how we should update the gradient to the args_grad.
            - 'write' means everytime gradient is write to specified args_grad NDArray.
            - 'add' means everytime gradient is add to the specified NDArray.
            - 'null' means no action is taken, the gradient may not be calculated.

        type_dict  : dict of str->numpy.dtype
            Input type dictionary, name->dtype

        group2ctx : dict of string to mx.Context
            The dict mapping the ``ctx_group`` attribute to the context assignment.

        kwargs : dict of str->shape
            Input shape dictionary, name->shape

        Returns
        -------
        executor : mxnet.Executor
            The generated Executor
=cut

method simple_bind(
            AI::MXNet::Context                 :$ctx=AI::MXNet::Context->current_ctx,
            HashRef[Shape]                     :$shapes,
            Str|HashRef[Str]                   :$grad_req='write',
            Maybe[HashRef[Dtype]]              :$type_dict=,
            Maybe[HashRef[AI::MXNet::Context]] :$group2ctx=
)
{
    if(not defined $type_dict)
    {
        $type_dict =  {};
        %$type_dict = map { $_ => 'float32' } @{ $self->list_arguments };
    }
    my @keys = keys %$shapes;
    my @shape_input;
    my @type_input;
    for my $k (@keys)
    {
        push @shape_input, ($k => $shapes->{$k});
        push @type_input,  ($k => $type_dict->{$k})
    }
    my ($arg_shapes, undef, $aux_shapes) = $self->infer_shape(@shape_input);
    my ($arg_types,  undef, $aux_types)  = $self->infer_type(@type_input);
    confess("Input node is not complete") 
        unless $arg_shapes and $arg_types;

    my ($arg_ctx, $aux_ctx) = ([], []); 
    if(defined $group2ctx)
    {
        my $attr_dict = $self->attr_dict();
        for my $name (@{ $self->list_arguments() })
        {
            if(
                exists $attr_dict->{ $name }
                    and
                exists $attr_dict->{ $name }{ __ctx_group__ }
                    and
                $group2ctx->{ $attr_dict->{ $name }{ __ctx_group__ } }
            )
            {
                push @{ $arg_ctx }, $group2ctx->{ $attr_dict->{ $name }{ __ctx_group__ } };
            }
            else
            {
                push @{ $arg_ctx }, $ctx;
            }
        }
        for my $name (@{ $self->list_auxiliary_states() })
        {
            if(
                exists $attr_dict->{ $name }
                    and
                exists $attr_dict->{ $name }{ __ctx_group__ }
                    and
                $group2ctx->{ $attr_dict->{ $name }{ __ctx_group__ } }
            )
            {
                push @{ $aux_ctx }, $group2ctx->{ $attr_dict->{ $name }{ __ctx_group__ } };
            }
            else
            {
                push @{ $aux_ctx }, $ctx;
            }
        }
    }
    else
    {
        @{ $arg_ctx } = (($ctx) x @{ $arg_shapes });
        @{ $aux_ctx } = (($ctx) x @{ $aux_shapes });
    }
    my @arg_ndarrays;
    for (my $i = 0; $i < @{ $arg_types }; $i++)
    {
        push @arg_ndarrays, AI::MXNet::NDArray->zeros(
            $arg_shapes->[$i], ctx => $arg_ctx->[$i], dtype => $arg_types->[$i]
        );
    }
    my $grad_ndarrays;
    if($grad_req ne 'null')
    {
        my $names = $self->list_arguments;
        for (my $i = 0; $i < @{ $arg_types }; $i++)
        {
            if(not ref $grad_req eq 'HASH' or not ($grad_req->{ $names->[$i] }//'') eq 'null')
            {
                $grad_ndarrays->{ $names->[$i] } = AI::MXNet::NDArray->zeros(
                    $arg_shapes->[$i], ctx => $arg_ctx->[$i], dtype => $arg_types->[$i]
                );
            }
        }
    }
    my @aux_ndarrays;
    for (my $i = 0; $i < @{ $aux_types }; $i++)
    {
        push @aux_ndarrays, AI::MXNet::NDArray->zeros(
            $aux_shapes->[$i], ctx => $aux_ctx->[$i], dtype => $aux_types->[$i]
        );
    }
    my $executor = $self->bind(
        ctx => $ctx, args => \@arg_ndarrays, args_grad => $grad_ndarrays,
        grad_req => $grad_req, aux_states => \@aux_ndarrays, group2ctx => $group2ctx
    );
    return $executor;
}

=head2 bind

        Bind current symbol to get an executor.

        Parameters
        ----------
        ctx : Context
            The device context the generated executor to run on.

        args : list of NDArray or dict of str to NDArray
            Input arguments to the symbol.

            - If type is list of NDArray, the position is in the same order of list_arguments.
            - If type is dict of str to NDArray, then it maps the name of arguments
              to the corresponding NDArray.
            - In either case, all the arguments must be provided.

        args_grad : list of NDArray or dict of str to NDArray, optional
            When specified, args_grad provide NDArrays to hold
            the result of gradient value in backward.

            - If type is list of NDArray, the position is in the same order of list_arguments.
            - If type is dict of str to NDArray, then it maps the name of arguments
              to the corresponding NDArray.
            - When the type is dict of str to NDArray, users only need to provide the dict
              for needed argument gradient.
              Only the specified argument gradient will be calculated.

        grad_req : {'write', 'add', 'null'}, or list of str or dict of str to str, optional
            Specifies how we should update the gradient to the args_grad.

            - 'write' means everytime gradient is write to specified args_grad NDArray.
            - 'add' means everytime gradient is add to the specified NDArray.
            - 'null' means no action is taken, the gradient may not be calculated.

        aux_states : list of NDArray, or dict of str to NDArray, optional
            Input auxiliary states to the symbol, only need to specify when
            list_auxiliary_states is not empty.

            - If type is list of NDArray, the position is in the same order of list_auxiliary_states
            - If type is dict of str to NDArray, then it maps the name of auxiliary_states
              to the corresponding NDArray,
            - In either case, all the auxiliary_states need to be provided.

        group2ctx : dict of string to mx.Context
            The dict mapping the ``ctx_group`` attribute to the context assignment.

        shared_exec : mx.executor.Executor
            Executor to share memory with. This is intended for runtime reshaping, variable length
            sequences, etc. The returned executor shares state with shared_exec, and should not be
            used in parallel with it.

        Returns
        -------
        executor : Executor
            The generated Executor

        Notes
        -----
        Auxiliary states are special states of symbols that do not corresponds to an argument,
        and do not have gradient. But still be useful for the specific operations.
        A common example of auxiliary state is the moving_mean and moving_variance in BatchNorm.
        Most operators do not have auxiliary states and this parameter can be safely ignored.

        User can give up gradient by using a dict in args_grad and only specify
        gradient they interested in.
=cut

method bind(
        AI::MXNet::Context                                              :$ctx,
        HashRef[AI::MXNet::NDArray]|ArrayRef[AI::MXNet::NDArray]        :$args,
        Maybe[HashRef[AI::MXNet::NDArray]|ArrayRef[AI::MXNet::NDArray]] :$args_grad=,
        Str|HashRef[Str]|ArrayRef[Str]                                  :$grad_req=,
        Maybe[HashRef[AI::MXNet::NDArray]|ArrayRef[AI::MXNet::NDArray]] :$aux_states=,
        Maybe[HashRef[AI::MXNet::Context]]                              :$group2ctx=,
        Maybe[AI::MXNet::Executor]                                      :$shared_exec=
)
{
    $grad_req //= 'write';
    my $listed_arguments = $self->list_arguments();
    my ($args_handle, $args_grad_handle, $aux_args_handle) = ([], [], []);
    ($args_handle, $args) = $self->_get_ndarray_inputs('args', $args, $listed_arguments);
    if(not defined $args_grad)
    {
        @$args_grad_handle = ((undef) x (@$args));
    }
    else
    {
        ($args_grad_handle, $args_grad) = $self->_get_ndarray_inputs(
                'args_grad', $args_grad, $listed_arguments, 1
        );
    }

    if(not defined $aux_states)
    {
        $aux_states = [];
    }
    ($aux_args_handle, $aux_states) = $self->_get_ndarray_inputs(
            'aux_states', $aux_states, $self->list_auxiliary_states()
    );

    # setup requirements
    my $req_map = { null => 0, write => 1, add =>  3 };
    my $req_array = [];
    if(not ref $grad_req)
    {
        confess('grad_req must be one of "null,write,add"')
            unless exists $req_map->{ $grad_req };
        @{ $req_array } = (($req_map->{ $grad_req }) x @{ $listed_arguments });
    }
    elsif(ref $grad_req eq 'ARRAY')
    {
        @{ $req_array } = map { $req_map->{ $_ } } @{ $grad_req };
    }
    else
    {
        for my $name (@{ $listed_arguments })
        {
            if(exists $grad_req->{ $name })
            {
                push @{ $req_array }, $req_map->{ $grad_req->{ $name } };
            }
            else
            {
                push @{ $req_array }, 0;
            }
        }
    }

    my $ctx_map_keys = [];
    my $ctx_map_dev_types = [];
    my $ctx_map_dev_ids = [];

    if(defined $group2ctx)
    {
        for (my ($key, $val) = each %{ $group2ctx })
        {
            push @{ $ctx_map_keys } , $key;
            push @{ $ctx_map_dev_types }, $val->device_type_id;
            push @{ $ctx_map_dev_ids }, $val->device_id;
        }
    }
    my $shared_handle = $shared_exec->handle if $shared_exec;
#map { print AI::MXNet::NDArray->new(handle => $_)->aspdl, "\n"; } @{$args_handle};
    my $handle = check_call(AI::MXNetCAPI::ExecutorBindEX(
                $self->handle,
                $ctx->device_type_id,
                $ctx->device_id,
                scalar(@{ $ctx_map_keys }),
                $ctx_map_keys,
                $ctx_map_dev_types,
                $ctx_map_dev_ids,
                scalar(@{ $args }),
                $args_handle,
                $args_grad_handle,
                $req_array,
                scalar(@{ $aux_states }),
                $aux_args_handle,
                $shared_handle
            )
    );
    my $executor = AI::MXNet::Executor->new(
        handle    => $handle,
        symbol    => $self,
        ctx       => $ctx,
        grad_req  => $grad_req,
        group2ctx => $group2ctx
    );
    $executor->arg_arrays($args);
    $executor->grad_arrays($args_grad);
    $executor->aux_arrays($aux_states);
    return $executor;
}

=head2  grad
        Get the autodiff of current symbol.

        This function can only be used if current symbol is a loss function.

        Parameters
        ----------
        wrt : Array of String
            keyword arguments of the symbol that the gradients are taken.

        Returns
        -------
        grad : Symbol
            A gradient Symbol with returns to be the corresponding gradients.
=cut

method grad(ArrayRef[Str] $wrt)
{
    my $handle = check_call(AI::MXNetCAPI::SymbolGrad(
                    $self->handle,
                    scalar(@$wrt),
                    $wrt
                 )
    );
    return __PACKAGE__->new(handle => $handle);
}

=head2 Variable(name, attr=None, shape=None, lr_mult=None, wd_mult=None, dtype=None):

    Create a symbolic variable with specified name.

    Parameters
    ----------
    name : str
        Name of the variable.
    attr : hash ref of string -> string
        Additional attributes to set on the variable.
    shape : array ref of positive integers
        Optionally, one can specify the shape of a variable. This will be used during
        shape inference. If user specified a different shape for this variable using
        keyword argument when calling shape inference, this shape information will be ignored.
    lr_mult : float
        Specify learning rate muliplier for this variable.
    wd_mult : float
        Specify weight decay muliplier for this variable.
    dtype : Dtype
        Similar to shape, we can specify dtype for this variable.

    Returns
    -------
    variable : Symbol
        The created variable symbol.
=cut

method Variable(Str $name, HashRef[Str] :$attr={}, Shape|Undef :$shape=, Num|Undef :$lr_mult=, Num|Undef :$wd_mult=, Dtype|Undef :$dtype=)
{
    my $handle = check_call(AI::MXNetCAPI::SymbolCreateVariable($name));
    my $ret = __PACKAGE__->new(handle => $handle);
    $attr = AI::MXNet::Symbol::AttrScope->current->get($attr);
    $attr->{__shape__}   = "(".join(',', @{ $shape }).")" if $shape;
    $attr->{__lr_mult__} =  $lr_mult if defined $lr_mult;
    $attr->{__wd_mult__} =  $wd_mult if defined $wd_mult;
    $attr->{__dtype__}   = DTYPE_STR_TO_MX->{ $dtype } if $dtype;
    $ret->_set_attr(%{ $attr });
    return $ret;
}

=head2 Group

    Create a symbol that groups symbols together.

    Parameters
    ----------
    symbols : array ref
        List of symbols to be grouped.

    Returns
    -------
    sym : Symbol
        The created group symbol.
=cut

method Group(ArrayRef[AI::MXNet::Symbol] $symbols)
{
    my $handle = check_call(AI::MXNetCAPI::SymbolCreateGroup($symbols));
    return __PACKAGE__->new(handle => $handle);
}

=head2 load

    Load symbol from a JSON file.

    You can also use pickle to do the job if you only work on python.
    The advantage of load/save is the file is language agnostic.
    This means the file saved using save can be loaded by other language binding of mxnet.
    You also get the benefit being able to directly load/save from cloud storage(S3, HDFS)

    Parameters
    ----------
    fname : str
        The name of the file, examples:

        - `s3://my-bucket/path/my-s3-symbol`
        - `hdfs://my-bucket/path/my-hdfs-symbol`
        - `/path-to/my-local-symbol`

    Returns
    -------
    sym : Symbol
        The loaded symbol.

    See Also
    --------
    AI::MXNet::Symbol->save : Used to save symbol into file.
=cut

method load(Str $fname)
{
    my $handle = check_call(AI::MXNetCAPI::SymbolCreateFromFile($fname));
    return __PACKAGE__->new(handle => $handle);
}

=head2 load_json
    Load symbol from json string.

    Parameters
    ----------
    json_str : str
        A json string.

    Returns
    -------
    sym : Symbol
        The loaded symbol.

    See Also
    --------
    Symbol.tojson : Used to save symbol into json string.
=cut

method load_json(Str $json)
{
    my $handle = check_call(AI::MXNetCAPI::SymbolCreateFromJSON($json));
    return __PACKAGE__->new(handle => $handle);
}

=head2 zeros

    Create a Tensor filled with zeros, similar to PDL::zeros

    Parameters
    ----------
    shape :  int or sequence of ints
        Shape of the new array.
    dtype : type, optional
        The value type of the NDArray, default to 'float32'

    Returns
    -------
    out : Symbol
        The created Symbol
=cut

method zeros(Shape $shape, Dtype :$dtype='float32', Str :$name)
{
    return __PACKAGE__->_zeros({ shape => $shape, dtype => $dtype, name => $name });
}

=head2 ones

    Create a Tensor filled with ones, similar to PDL::ones

    Parameters
    ----------
    shape :  int or sequence of ints
        Shape of the new array.
    dtype : type, optional
        The value type of the NDArray, default to 'float32'

    Returns
    -------
    out : Symbol
        The created Symbol
=cut

method ones(Shape $shape, Dtype :$dtype='float32', Str :$name)
{
    return __PACKAGE__->_ones({ shape => $shape, dtype => $dtype, name => $name });
}

=head2 arange

    Simlar function in the MXNet ndarray as numpy.arange
        See Also https://docs.scipy.org/doc/numpy/reference/generated/numpy.arange.html.

    Parameters
    ----------
    start : number
        Start of interval. The interval includes this value. The default start value is 0.
    stop : number, optional
        End of interval. The interval does not include this value.
    step : number, optional
        Spacing between values
    repeat : int, optional
        "The repeating time of all elements.
        E.g repeat=3, the element a will be repeated three times --> a, a, a.
    dtype : type, optional
        The value type of the NDArray, default to np.float32

    Returns
    -------
    out : Symbol
        The created Symbol
=cut

method arange(Index :$start=0, Index :$stop=, Num :$step=1.0, Index :$repeat=1, Str :$name, Dtype :$dtype='float32')
{
    return __PACKAGE__->_arange({
                 start => $start, (defined $stop ? (stop => $stop) : ()),
                 step => $step, repeat => $repeat, name => $name, dtype => $dtype
    });
}

sub _parse_arguments
{
    my $type = shift;
    my @args = @_;
    my $type_c = find_type_constraint($type);
    my $str_c  = find_type_constraint("Str");
    my @positional_arguments;
    my %kwargs;
    my @kwargs_order;
    my $only_dtypes_and_undefs = (@args == grep { not defined($_) or $type_c->check($_) } @args);
    my $only_dtypes_and_strs   = (@args == grep { $type_c->check($_) or $str_c->check($_) } @args);
    if(@args % 2 and $only_dtypes_and_undefs)
    {
        @positional_arguments = @args;
    }
    else
    {
        if($only_dtypes_and_undefs)
        {
            @positional_arguments = @args;
        }
        elsif($only_dtypes_and_strs)
        {
            my %tmp = @args;
            if(values(%tmp) == grep { $type_c->check($_) } values(%tmp))
            {
                %kwargs = %tmp;
                my $i = 0;
                @kwargs_order = grep { $i ^= 1 } @args;
            }
            else
            {
                confess("Argument need to be of type $type");
            }
        }
        else
        {
            confess("Argument need to be one type $type");
        }
    }
    return (\@positional_arguments, \%kwargs, \@kwargs_order);
}

sub  _ufunc_helper
{
    my ($lhs, $rhs, $fn_symbol, $lfn_scalar, $rfn_scalar, $reverse) = @_;
    ($rhs, $lhs) = ($lhs, $rhs) if $reverse and $rfn_scalar;
    if(not ref $lhs)
    {
        if(not $rfn_scalar)
        {
            return __PACKAGE__->can($lfn_scalar)->(__PACKAGE__, $rhs, { "scalar" => $lhs });
        }
        else
        {
            return __PACKAGE__->can($rfn_scalar)->(__PACKAGE__, $rhs, { "scalar" => $lhs });
        }
    }
    elsif(not ref $rhs)
    {
        return __PACKAGE__->can($lfn_scalar)->(__PACKAGE__, $lhs, { "scalar" => $rhs });
    }
    else
    {
        return __PACKAGE__->can($fn_symbol)->(__PACKAGE__, $lhs, $rhs);
    }
}

1;
