#!/bin/bash
#
# Copyright (C) 2018 by Domingos Rodrigues <ddcr@lcc.ufmg.br>
#
# This script is heavily based on the following projects:
#   https://github.com/TACC/lariat
#   https://github.com/glennklockwood/ibrun
#   https://github.com/cazes/ibrun
#

#
# set -xv
#

function debug_print {
    if [ "$VEREDAS_IBRUN_DEBUG" == "1" ]; then
	echo -e "DEBUG - ${FUNCNAME} $@"
    fi
}

function std_print {
    if [ "$IBRUN_QUIET" != "1" ]; then
	echo -e "VEREDAS - ${FUNCNAME} $@"
    fi
}

function err_print {
    echo -e "ERROR: $@" 1>&2
}

export debug_print
export std_print
export err_print

function usage {
    echo "----------------------------------------------------------------------------------"
    echo "A wrapper script to launch MPI jobs from an                                       "
    echo "implementation-independent way (hopefully).                                       "
    echo "                                                                                  "
    echo "Basic Usage:                                                                      "
    echo "$0 ./my_mpi_exec. <args>                                                          "
    echo "where my_mpi_exec is your parallel compiled executable.                           "
    echo "                                                                                  "
    echo "Advanced Usage:                                                                   "
    echo "$0 [OPTIONS] ./my_mpi_exec. <args>                                                "
    echo "Options:                                                                          "
    echo "  -n/-np {value}  number of MPI processes                                         "
    echo "  -mpi [mvapich2_slurm|mvapich2_ssh|impi_hydra]  Specify which MPI should be used."
    echo "                                                                                  "
    echo "----------------------------------------------------------------------------------"
}


# if running outside slurm, eg., debugging purposes, load below
function emulate_slurm {
    SLURM_TASKS_PER_NODE="4(x3),9,3(x2),8(x6),5,8,8(x56)"
    SLURM_NODELIST="veredas[1-3,6,9-10,34-39,40,45,98-153]"
    SLURM_NPROCS=70
    SLURM_JOB_ID=1
    std_print "============ TEST ENVIRONMENT ============"
    std_print "SLURM_TASKS_PER_NODE=$SLURM_TASKS_PER_NODE"
    std_print "SLURM_NODELIST      =$SLURM_NODELIST      "
    std_print "SLURM_NPROCS        =$SLURM_NPROCS        "
    std_print "============ TEST ENVIRONMENT ============"
}

# If there is some bash wrapper script among the arguments
# of this script (eg. ./$0 affinity_script.sh <executable> <exec arguments>)
# a problem is triggered. The output will be garbled with repetitions of a
# error message of the kind:
#    /bin/bash: module: line 2: syntax error: unexpected end of file
#    /bin/bash: error importing function definition for `BASH_FUNC_module'.
# This is an old problem related to the modules software (modulefiles & lmod)
# after patching BASH for the Shellshock vulnerabilty.
# The messages are harmless (rom what i can see till now) but annoying.
# The following command removes thw culprit, but the downside is the
# inability of calling modules (eg., 'module list' or 'module load <soft>')
#
unset module

function load_defaults {
    if [ -z "$IBRUN_FILE_DEFAULTS" ]; then
	IBRUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
	if [ -s $IBRUN_DIR/ibrun.defaults ]; then
	    export IBRUN_FILE_DEFAULTS=$IBRUN_DIR/ibrun.defaults
	elif [ -s /usr/local/bin/ibrun.defaults ]; then
	    export IBRUN_FILE_DEFAULTS=/usr/local/bin/ibrun.defaults
	else
	    std_print "Warning IBRUN defaults not loaded"
	fi
    fi
    
    if [ -s $IBRUN_FILE_DEFAULTS ]; then
        source $IBRUN_FILE_DEFAULTS
    fi
}

load_defaults

nlocal=$(hostname -f)
# our node configuration is fixed: all computing nodes are the same
debug_print "spn: Sockets per node    = 2"
debug_print "npn: Numanodes per node  = 1"
debug_print "cps: Cores per socket    = 4"
debug_print "cpn: Cores per node      = 8"
debug_print "tpc: HThreads per core   = 1"
debug_print "tps: HThreads per socket = 4"
debug_print "tpn: HThreads per node   = 8"
CPN=8


if [ "$nlocal" == "veredas0" ]; then
    err_print "\t Do not run $0 on the login node"
    err_print "\t It must be called inside a batch script"
    std_print "Loading a SLURM environment example:"
    emulate_slurm
    VEREDAS_EMULATE=1
fi


#----------------------------------------------------------------------------------------
#
#                 Get info of how tasks are distributed per node
#
#----------------------------------------------------------------------------------------

declare -a node_clusters=(`echo $SLURM_TASKS_PER_NODE | sed -e 's/,/ /g'`)
debug_print "SLURM: node_clusters ${node_clusters[@]}"

# Check that we possible under SLURM
if [ -n "$SLURM_JOB_ID" ]; then
    SCHEDULER=SLURM
    BATCH_JOB_ID=$SLURM_JOB_ID
    MPI_NSLOTS=$SLURM_NPROCS
    
    node_tasks_ppn_info=""
    task_count=0
    total_nodes=0

    for nodes in ${node_clusters[@]}; do
	tasks_ppn_cluster=`echo $nodes | awk -F '(' '{print $1}'`
	debug_print "TASKS_PPN_CLUSTER=$tasks_ppn_cluster"
	node_tasks_ppn_info="${node_tasks_ppn_info}${tasks_ppn_cluster}"
	if [[ `echo $nodes | grep x` ]]; then
	    node_count=`echo $nodes | sed -e 's/.*x\([0-9]\+\).*/\1/'`
	else
	    node_count=1
	fi
	let "total_nodes=$total_nodes+$node_count"
	node_tasks_ppn_info="${node_tasks_ppn_info},${task_count}_"
	let "total_tasks_per_node_cluster=$node_count*$tasks_ppn_cluster"
	let "task_count=$task_count+$total_tasks_per_node_cluster"
	debug_print "NODE_TASKS_PPN_INFO = ${node_tasks_ppn_info}"
    done

    # add extra quotes
    export NODE_TASKS_PPN_INFO="\"${node_tasks_ppn_info}\""

    debug_print "TOTAL_NODES = ${total_nodes}"
    debug_print "NODE_TASKS_PPN_INFO = {# of tasks per node},{#initial task id}_[...]"
    debug_print "NODE_TASKS_PPN_INFO = ${NODE_TASKS_PPN_INFO}"
else
    err_print "Unknown batch system"
    exit 1
fi
std_print "NODE_TASKS_PPN_INFO=$NODE_TASKS_PPN_INFO"




#----------------------------------------------------------------------------------------
#
#                           Parse options from command line
#
#----------------------------------------------------------------------------------------
strip_eq() {
    ret=`echo $1 | sed -e 's/.*\=//'`
}

np_opt=
MPI_MODE="$VEREDAS_MPI_DEFAULT"

while [ $# -gt 0 ]; do
    arg="$1"
    if [ -n "$arg" ]; then
        case "$arg" in
            -help | -h )
		usage;
		exit 0;;
            -np | -n )
		np_opt="-n $2"; shift ;;
            --mpi=* )
		strip_eq $1; MPI_MODE=$ret ;;
            * ) # arguments to script and command-name followed by arguments
		cmd=$1;
		shift;
                break;;
        esac
    fi
    shift
done

if [ -n "$np_opt" ]; then

    if [ -n "$MPI_NSLOTS" ]; then
	std_print "Overriding MPI_NSLOTS (=$MPI_NSLOTS)"
    fi

    echo " $np_opt" | grep " -np " > /dev/null
    if [ $? -eq 0 ]; then
	MPI_NSLOTS=`echo $np_opt | sed "s/\-np //"`
    else
	MPI_NSLOTS=`echo $np_opt | sed "s/\-n //"`
    fi
    std_print "New value of MPI_NSLOTS=$MPI_NSLOTS"
fi

debug_print "MPI type=$MPI_MODE"

# double check the executable
fullcmd=`which $cmd 2> /dev/null`
if [ $? -ne 0 ]; then
    fullcmd="$cmd"
fi
debug_print "fullcmd = $fullcmd"




#----------------------------------------------------------------------------------------
#
#                    This is the place to preload libraries if needed
#
#----------------------------------------------------------------------------------------




#----------------------------------------------------------------------------------------
#
#                           Build the hostfile
#
#----------------------------------------------------------------------------------------

home_batch_dir="$HOME/.slurm"

if [ ! -d $home_batch_dir ]; then
    mkdir -p $home_batch_dir
fi

hostfile_veredas=`mktemp $home_batch_dir/job.$BATCH_JOB_ID.hostlist.XXXXXXXX`
if [ -f $hostfile_veredas ]; then
    rm -f $hostfile_veredas
fi


declare -a hostlist=(`scontrol show hostname $SLURM_NODELIST`)
if [ $? -ne 0 ]; then
    err_print "SLURM hostlist unavailable"
    exit 1
else
    debug_print "hostlist = ${hostlist[@]}"
fi

host_id=0
if [ x"$MPI_MODE" == "xopenmpi_ssh" ]; then

    std_print "Setting up parallel environment for OpenMPI mpirun"

    for nodes in ${node_clusters[@]}; do
	task_count=`echo $nodes | awk -F '(' '{print $1}'`
	if [[ `echo $nodes | grep x` ]]; then
	    node_count=`echo $nodes | sed -e 's/.*x\([0-9]\+\).*/\1/'`
	else
	    node_count=1
	fi
	debug_print "nodes = ${nodes} => task_count=${task_count} / node_count=${node_count}"
	for i in `seq 0 $((node_count-1))`; do
	    echo "${hostlist[${host_id}]} slots=${task_count}" >> ${hostfile_veredas}
	    ((host_id++))
	done
    done

else 

    if [ x"$MPI_MODE" == "xmvapich2_slurm" ]; then
	std_print "Setting up parallel environment for MVAPICH2+SLURM"
    elif [ x"$MPI_MODE" == "xmvapich2_ssh" ]; then
	std_print "Setting up parallel environment for MVAPICH2+mpispawn"
    elif [ x"$MPI_MODE" == "ximpi_hydra" ]; then
	std_print "Setting up parallel environment for Intel MPI hydra"
    else
	err_print "$MPI_MODE stack is not available"
	exit 1
    fi

    for nodes in ${node_clusters[@]}; do
	task_count=`echo $nodes | awk -F '(' '{print $1}'`
	if [[ `echo $nodes | grep x` ]]; then
	    node_count=`echo $nodes | sed -e 's/.*x\([0-9]\+\).*/\1/'`
	else
	    node_count=1
	fi
	debug_print "nodes = ${nodes} => task_count=${task_count} / node_count=${node_count}"
	for i in `seq 0 $((node_count-1))`; do
	    for j in `seq 0 $((task_count-1))`; do
		echo ${hostlist[${host_id}]} >> ${hostfile_veredas}
	    done
	    ((host_id++))
	done
    done
fi



#------------------------------------------------
#
#     MVAPICH2 default environment variables
#
#------------------------------------------------

if [ -z "$MV2_USE_UD_HYBRID" ]; then
    export MV2_USE_UD_HYBRID=0
fi

# optimizing startup for homogeneous clusters
if [ -z "$MV2_HOMOGENEOUS_CLUSTER" ]; then
    export MV2_HOMOGENEOUS_CLUSTER=1
fi

export MV2_IBA_HCA=mthca0
export MV2_SHOW_CPU_BINDING=1

# Intra-node kernel assistance
# Let us not use LIMIC2 unless for large messages 
#    the switch point is: export MV2_SMP_EAGERSIZE=<nbytes>
#
if [ -z "$MV2_SMP_USE_LIMIC2" ]; then
    export MV2_SMP_USE_LIMIC2=0
fi

if [ -z "$GFORTRAN_UNBUFFERED_ALL" ]; then
    export GFORTRAN_UNBUFFERED_ALL=y
fi

# export MV2_USE_RING_STARTUP=0 if mpirun_rsh is used
# export MV2_USE_RING_STARTUP=1 otherwise

# not needed, our cluster is not that big
# export MV2_FASTSSH_THRESHOLD=50
# export MV2_NPROCS_THRESHOLD=

# prefer automatic binding??
# export MV2_CPU_BINDING_POLICY=bunch|scatter       [default=bunch]
# export MV2_CPU_BINDING_LEVEL=core|socket|numanode [default=core]
# export MV2_ENABLE_AFFINITY=1                      [default=1]

# Starting from version 2.3 mvapich3 provides explicit
# support for hybrid programming MPI+OpenMP
#
# if [ -z "$MV2_CPU_BINDING_POLICY" ]; then
#     export MV2_CPU_BINDING_POLICY=hybrid
# fi
# if [ x"$MV2_CPU_BINDING_POLICY" == "xhybrid" ]; then
#     export MV2_HYBRID_BINDING_POLICY=spread
# fi
# 
# if [ -z "$MV2_THREADS_PER_PROCESS" ]; then
#     export MV2_THREADS_PER_PROCESS=$(( CPN/task_count )) not really correct!
# fi

#------------------------------------------------
#
#    Intel MPI default environment variables
#
#------------------------------------------------
if [ -z "$I_MPI_DEBUG" ]; then
    export I_MPI_DEBUG=4
fi

if [ -z "$I_MPI_FABRICS" ]; then
    export I_MPI_FABRICS=dapl
fi



#----------------------------------------------------------------------------------------
#
#                            Start the parallel execution
#
#----------------------------------------------------------------------------------------

if [ x"$MPI_MODE" == "xmvapich2_ssh" ]; then

    launch_command="mpirun_rsh -ssh -np $MPI_NSLOTS -hostfile ${hostfile_veredas} $MY_MPIRUN_OPTIONS -export-all $fullcmd $@"
    debug_print "$MPI_MODE launch command:\n\t $launch_command"
    if [ -z "$VEREDAS_EMULATE" ]; then
	mpirun_rsh -ssh -np $MPI_NSLOTS -hostfile ${hostfile_veredas} $MY_MPIRUN_OPTIONS -export-all $fullcmd "$@"
	res=$?
    else
	res=0
    fi

elif [ x"$MPI_MODE" == "xmvapich2_slurm" ]; then

    std_print "MVAPICH2+SLURM wrapping not implemented yet!\n I need to upgrade SLURM first.\nExiting.\n"
    res=1

elif [ x"$MPI_MODE" == "ximpi_hydra" ]; then
    
    launch_command="mpiexec.hydra -np $MPI_NSLOTS --machinefile ${hostfile_veredas} -print-rank-map $MY_MPIRUN_OPTIONS $fullcmd $@"
    debug_print "$MPI_MODE launch command:\n\t $launch_command"
    if [ -z "$VEREDAS_EMULATE" ]; then
	mpiexec.hydra -np $MPI_NSLOTS --machinefile ${hostfile_veredas} -print-rank-map $MY_MPIRUN_OPTIONS $fullcmd "$@"
	res=$?
    else
	res=0
    fi

elif [ x"$MPI_MODE" == "xopenmpi" ]; then

    std_print "OpenMPI wrapping not implemented yet!\nExiting.\n"
    res=1

elif [ x"$MPI_MODE" == "xVEREDAS_DBG_INTERNAL" ]; then

    # this is for internal debug purposes
    debug_print "$0 launched process with PID $$"

    #     # listing /proc/self gives us the PID of the ls that was ran from the shell
    #     # "exec /bin/ls" will not fork, but just replaces the shell.
    #     exec ls -l /proc/self
    #     # .. and so the following command does not run
    #     echo foo
        
    #     # here things are different
    #     eval ls -l /proc/self
    #     echo foo
    
    res=0

else

    std_print "Could not determine which MPI stack to use.\nExiting.\n"
    res=1

fi

if [ $res -ne 0 ]; then
    echo "MPI job exited with code: $res"
fi

if [ x"$VEREDAS_KEEP_FILES" == "xn" -o x"$VEREDAS_KEEP_FILES" == "xN" -o x"$VEREDAS_KEEP_FILES" == "x0" ]; then
    if [ -f ${hostfile_veredas} ]; then
	std_print "Removing Hostfile ${hostfile_veredas}"
	rm -f ${hostfile_veredas}
    fi
fi

std_print "Shutdown complete. Exiting"
exit $res
