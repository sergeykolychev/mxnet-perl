package AI::MXNet::Symbol::Base;
use strict;
use warnings;
use AI::MXNet::Base;
use AI::MXNet::Symbol::AttrScope;
use AI::MXNet::Symbol::Doc;
use AI::MXNet::Symbol::NameManager;
use Mouse;
use AI::MXNet::Function::Parameters;

my %function_meta;
method function_meta($code)
{
    return $function_meta{$code};
}

method function_meta_hash()
{
    return \%function_meta;
}

=head2 _compose

        Compose symbol on inputs.

        This call mutates the current symbol.

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

sub _compose
{
    my $self = shift;
    my (@args, %kwargs);
    if(@_ and ref $_[-1] eq 'HASH')
    {
        %kwargs = %{ pop(@_) };
    }
    @args = @_;
    my $name = delete $kwargs{'name'};
    if(@args and %kwargs)
    {
        confess("_compose only accept input Symbols \
            either as positional or keyword arguments, not both");
    }
    if(grep { not blessed($_) or not $_->isa(__PACKAGE__) } (@args, values %kwargs))
    {
        confess("_compose expect 'Symbol' as arguments");
    }

    my $num_args = scalar(@args) + scalar(keys %kwargs);
    my $keys = [];
    my $args = [];
    for my $key (keys %kwargs)
    {
        push @$keys, $key;
        push @$args, $kwargs{ $key }->handle;
    }
    @$args = map { $_->handle } @args if @args;
    check_call(
        AI::NNVMCAPI::SymbolCompose(
            $self->handle, $name, $num_args, $keys, $args
        )
    );
}

# Create an atomic symbol function by handle and funciton name
func _make_atomic_symbol_function($handle, $name)
{
    my ($real_name, $desc, $arg_names, 
        $arg_types, $arg_descs, $key_var_num_args, 
        $ret_type) = @{ check_call(AI::MXNetCAPI::SymbolGetAtomicSymbolInfo($handle)) };
    $ret_type //= '';
    my $func_name = $name;
    my $doc_str = build_doc($func_name,
                            $desc,
                            $arg_names,
                            $arg_types, 
                            $arg_descs,
                            $key_var_num_args,
                            $ret_type
    );
=head2

        Activation Operator of Neural Net.
        The parameters listed below can be passed in as keyword arguments.

        Parameters
        ----------
        name : string, required.
            Name of the resulting symbol.

        Returns
        -------
        symbol: Symbol
            the resulting symbol
=cut

    my $creator = sub {
 
        my $class = shift;
        my (@args, %kwargs);
        if(@_ and ref $_[-1] eq 'HASH')
        {
            %kwargs = %{ pop(@_) };
        }
        @args = @_;
        my $params = {};
        my $symbol_kwargs = {};
        my $attr = delete $kwargs{ 'attr' };
        %kwargs = (%kwargs, % { AI::MXNet::Symbol::AttrScope->current->get($attr) });
        $name = delete $kwargs{ 'name' };
        if($key_var_num_args and not exists $kwargs { $key_var_num_args })
        {
            $params->{ $key_var_num_args } = scalar(@args);
        }
        for my $key (keys %kwargs)
        {
            $kwargs{ $key } = "(" .join(",", @{ $kwargs{ $key } }) .")" 
                if ref $kwargs{ $key } eq 'ARRAY';
        }
        while(my ($k, $v) = each %kwargs)
        {
            if(blessed($v) and $v->isa(__PACKAGE__))
            {
                $symbol_kwargs->{ $k } = $v;
            }
            else
            {
                $params->{ $k } = "$v";
            }
        }
        # create atomic symbol
        my $sym_handle = check_call(
            AI::MXNetCAPI::SymbolCreateAtomicSymbol(
                $handle,
                scalar(keys %$params),
                $params
            )
        );

        my $s = $class->new(handle => $sym_handle);
        my $hint = lc($func_name);
        $name = AI::MXNet::Symbol::NameManager->current->get($name, $hint);
        $s->_compose(@args, { name => $name, %$symbol_kwargs });
        return $s;
    };
    $function_meta{ $creator }{__name__} = $func_name;
    $function_meta{ $creator }{__doc__} = $doc_str;
    return $creator;
}

method _init_symbol_module()
{
    my $op_names = check_call(AI::MXNetCAPI::ListAllOpNames());
    for my $name (@$op_names)
    {
        my $handle = check_call(AI::NNVMCAPI::GetOpHandle($name));
        my $function = _make_atomic_symbol_function($handle, $name);
        {
            no strict 'refs';
            {
                *{__PACKAGE__."::$name"} = $function;
            } 
        }
    }
}

__PACKAGE__->_init_symbol_module;

1;
