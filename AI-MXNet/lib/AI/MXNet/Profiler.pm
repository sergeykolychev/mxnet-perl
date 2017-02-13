package AI::MXNet::Profiler;
use strict;
use warnings;
use AI::MXNet::Base;
use AI::MXNet::Function::Parameters;

=head2 profiler_set_config

    Set up the configure of profiler.

    Parameters
    ----------
    mode : string, optional
        Indicting whether to enable the profiler, can
        be 'symbolic' or 'all'. Default is `symbolic`.
    filename : string, optional
        The name of output trace file. Default is
        'profile.json'.
=cut

method profiler_set_config(ProfilerMode $mode='symbolic', Str $filename='profile.json')
{
    my %mode2int = qw/symbolic 0 all 1/;
    check_call(AI::MXNet::SetProfilerConfig($mode2int{ $mode }, $filename));
}

=head2 profiler_set_state

    Set up the profiler state to record operator.

    Parameters
    ----------
    state : string, optional
        Indicting whether to run the profiler, can
        be 'stop' or 'run'. Default is `stop`.
=cut

method profiler_set_state(ProfilerState $state='stop')
{
    my %state2int = qw/stop 0 run 1/;
    check_call(AI::MXNet::SetProfilerState($state2int{ $state }));
}

1;
