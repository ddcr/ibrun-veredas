#!/bin/bash
#
# Copyright (C) 2018 by Domingos Rodrigues <ddcr@lcc.ufmg.br>
#
# This script is heavily based on the following projects:
#   https://github.com/TACC/lariat
#   https://github.com/glennklockwood/ibrun
#   https://github.com/cazes/ibrun
#
# set -x
set -e

export IBRUN_VEREDAS_VERSION='1.1.0'

if [ "x$IBRUN_DIR" == "x" ]; then
  IBRUN_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
fi

function version() {
  local cmd="${0##*/}"
  printf '%s %s\n' "$cmd" "$IBRUN_VEREDAS_VERSION"
  exit 0
}

function debug_print() {
  if [ "$VEREDAS_IBRUN_DEBUG" == "1" ]; then
    [[ ! -z "$pretty" ]] && set_color 0 bold
    buffer '[%s]>> %s\n' "${FUNCNAME}" "$1"
    [[ ! -z "$pretty" ]] && clear_color
    flush
  fi
}

function std_print() {
  [[ ! -z "$pretty" ]] && set_color 4
  buffer '[%s]>> %s\n' "${FUNCNAME}" "$1"
  [[ ! -z "$pretty" ]] && clear_color
  flush
}

function err_print() {
  [[ ! -z "$pretty" ]] && set_color 1
  buffer 'ERROR: %s\n' "$1" 1>&2
  [[ ! -z "$pretty" ]] && clear_color
  flush
}

function strip_eq() {
  ret=`echo $1 | sed -e 's/.*\=//'`
}

set_color() {
  local color="$1"
  local weight=22

  if [[ "$2" == 'bold' ]]; then
    weight=1
  fi
  buffer '\x1B[%d;%dm' "$(( 30 + $color ))" "$weight"
}

clear_color() {
  buffer '\x1B[0m'
}

_buffer=

buffer() {
  local content
  printf -v content -- "$@"
  _buffer+="$content"
}

flush() {
  printf '%s' "$_buffer"
  _buffer=
}

finish() {
  flush
  printf '\n'
}

abort() {
  local cmd="${0##*/}"
  printf 'Error: %s\n\n' "$1" >&2
  short_usage
  exit 1
}

err_report() {
    echo "Error on line $1"
}
trap 'err_report: $LINENO' ERR

check_parallel_launcher() {
	if [ ! $(type -P "$1") ]; then
		err_print "Cannot find launcher $1 (maybe forgot to load its modulefile)"
		exit 1;
	fi
}

short_usage() {
  local cmd="${0##*/}"
  local line

  while IFS= read -r line; do
    printf '%s\n' "$line"
  done <<END_OF_SHORT_HELP
Usage: $cmd [-np|--ntasks] <value> --mpi=<name> [<opt-affinity-script>] <my_mpiexe> [arg1] ...
       $cmd [-h|--help]
       $cmd [-n|--dryrun]
       $cmd [-V|--version]
       $cmd [-v|--verbose]
END_OF_SHORT_HELP
}

usage() {
  local cmd="${0##*/}"
  local line

  while IFS= read -r line; do
    printf '%s\n' "$line"
  done <<END_OF_HELP
Usage: $cmd [-np|--ntasks] <value> --mpi=<name> [<opt-affinity-script>] <my_mpiexe> [arg1] ...
       $cmd [-h|--help]
       $cmd [-n|--dryrun]
       $cmd [-V|--version]
       $cmd [-v|--verbose]

  A wrapper utility to launch MPI tasks in SLURM jobs.
  DO NOT use for serial jobs.


  <name>
                MPI stack [impi_hydra|mvapich2_ssh|mvapich2_slum|openmpi]
  <my_mpiexe>
                is the path to the MPI executable compiled by the user
                followed by any accepted arguments.

  <optional-affinity-script>
                external file script (bash) that enables MPI tasks/OpenMP threads
                binding to logical/physical cores. More specifically this
                script should use either of the system tools hwloc or likwid,
                to manage task placement and pinning to a single core or groups of
                physical cores. This script is most useful for hybrid
                MPI+OpenMP/threads jobs and normally is considered advanced
                usage. It should be placed before the program <mpiexe> (see
                usage above), so that the output of $cmd is
                piped through it. The user can provide his own script or use
                the script located in
                $IBRUN_DIR/veredas_affinity


  Most common usage of this script is something like this:
    $cmd <my_mpiexe> [arg1] [arg2] ...

Options:
  -np, --ntasks <value>  Enforce total number of tasks
       --mpi=<name>      Specify MPI stack to be used [default: $MPI_MODE]
  -h,  --help            Display this help message
  -n,  --dryrun          Do everything except launch the application
  -V,  --version         Display the version number
  -v,  --verbose         Print diagnostic messages

  For more information, see wiki (TODO)

Copyright (C) 2018 by Domingos Rodrigues <ddcr@lcc.ufmg.br>
END_OF_HELP

exit 0
}

# if running outside slurm environment then
# load this debugging environment
function emulate_slurm {
  # force dryrun
  dry_run=1
  SLURM_TASKS_PER_NODE="4(x3),9,3(x2),8(x6),5,8,8(x56)"
  SLURM_NODELIST="veredas[1-3,6,9-10,34-39,40,45,98-153]"
  SLURM_NPROCS=70
  SLURM_JOB_ID=1

  [[ ! -z "$pretty" ]] && set_color 1 bold
  while IFS= read -r line; do
    buffer "$line\n"
  done <<END_OF_EMUL
============ FAKE SLURM ENVIRONMENT ============
SLURM_TASKS_PER_NODE = $SLURM_TASKS_PER_NODE
SLURM_NODELIST       = $SLURM_NODELIST
SLURM_NPROCS         = $SLURM_NPROCS
============ FAKE SLURM ENVIRONMENT ============
END_OF_EMUL
  [[ ! -z "$pretty" ]] && clear_color
  flush
}


#----------------------------------------------------------------------------------------
#
#                           Modulefiles
#
#----------------------------------------------------------------------------------------
# If there is some bash wrapper script among the arguments
# of this script (eg. ./$0 affinity_script.sh <executable> <exec arguments>)
# a problem is triggered. The output will be garbled with repetitions of a
# error message of the kind:
#    /bin/bash: module: line 2: syntax error: unexpected end of file
#    /bin/bash: error importing function definition for `BASH_FUNC_module'.
# This is an old problem related to the modules software (modulefiles & lmod)
# after patching BASH for the Shellshock vulnerabilty.
# The messages are harmless (from what i can see till now) but annoying.
# The following command removes the culprit, but the downside is the
# inability of calling modules (eg., 'module list' or 'module load <soft>')
#
unset module

function load_defaults {
  if [ -z "$IBRUN_FILE_DEFAULTS" ]; then
    if [ -s $IBRUN_DIR/ibrun.defaults ]; then
      export IBRUN_FILE_DEFAULTS=$IBRUN_DIR/ibrun.defaults
    elif [ -s /usr/local/bin/ibrun.defaults ]; then
      export IBRUN_FILE_DEFAULTS=/usr/local/bin/ibrun.defaults
    elif [ -s $HOME/ibrun.defaults ]; then
      export IBRUN_FILE_DEFAULTS=$HOME/ibrun.defaults
    else
      std_print "Warning IBRUN defaults not loaded"
    fi
  fi
  if [ -s $IBRUN_FILE_DEFAULTS ]; then
    source $IBRUN_FILE_DEFAULTS
  fi
}
load_defaults


#----------------------------------------------------------------------------------------
#
#                           Parse options from command line
#
#----------------------------------------------------------------------------------------
unset pretty
pretty=
if [[ -t 0 && -t 1 ]] && command -v tput >/dev/null; then
  pretty=1
fi

export MPI_MODE="$VEREDAS_MPI_DEFAULT"
mpirun_cmdline=
dry_run=0
np_opt=
while [ $# -gt 0 ]; do
  arg="$1"
  if [ -n "$arg" ]; then
    case "$arg" in
      -h  | --help    ) usage;;
      -np | --ntasks  )
                        if [[ x$2 = x ]]; then
                          abort "Missing value of -np/--ntasks"
                        else
                          np_opt="-n $2"
                        fi
                        shift ;;
            --mpi     ) abort "Wrong format of --mpi: --mpi=<MPI type>";;
            --mpi=*   )
                        strip_eq $1;
                        if [[ x$ret = x ]]; then
                          abort "Missing value of --mpi"
                        else
                          if [[ x"$ret" == "xmvapich2_ssh" || \
                                x"$ret" == "xmvapich2_slurm" || \
                                x"$ret" == "ximpi_hydra" || \
                                x"$ret" == "xopenmpi" ]]; then
                            check_parallel_launcher $ret;
                            MPI_MODE=$ret;
                          else
                            abort "MPI stack '$ret' not wrapped ..."
                          fi
                        fi
                        ;;
      -V  | --version ) version;;
      -v  | --verbose ) [[ "$VEREDAS_IBRUN_DEBUG" == "0" ]] && VEREDAS_IBRUN_DEBUG=1;;
      -n  | --dryrun  ) dry_run=1;;
      -*              )
                        abort "Invalid option: '$arg'"
                        ;;
                    * ) # arguments to mpiexec and command-name followed by arguments
                        mpirun_cmdline="$@"
                        break;;
    esac
  fi
  shift
done

if [[ x"$mpirun_cmdline" == "x" ]]; then
  err_print " WARNING: Missing MPI executable and its arguments ..."
fi

local_host=$(hostname -f)
# our node configuration is fixed: all computing nodes are the same
debug_print "Host: ${local_host}         "
debug_print "spn: Sockets per node    = 2"
debug_print "npn: Numanodes per node  = 1"
debug_print "cps: Cores per socket    = 4"
debug_print "cpn: Cores per node      = 8"
debug_print "tpc: HThreads per core   = 1"
debug_print "tps: HThreads per socket = 4"
debug_print "tpn: HThreads per node   = 8"
CPN=8

if [ -z "$SLURM_JOBID" ]; then
  err_print "${0##*/} should be executed within an  "
  err_print "existing SLURM job allocation.         "
  err_print "We are then loading a fake job         "
  err_print "allocation for debugging purposes:     "
  emulate_slurm
  dry_run=1
fi

MPI_NSLOTS=$SLURM_NPROCS
if [ -n "$np_opt" ]; then
  if [ -n "$MPI_NSLOTS" ]; then
    std_print "Overriding MPI_NSLOTS ( = $MPI_NSLOTS )"
  fi

  echo " $np_opt" | grep " -n " > /dev/null
  if [ $? -eq 0 ]; then
    MPI_NSLOTS=`echo $np_opt | sed "s/\-n //"`
  fi
  std_print "New value of MPI_NSLOTS=$MPI_NSLOTS"
fi

std_print "MPI type   = $MPI_MODE"
std_print "#MPI tasks = $MPI_NSLOTS"

#
# Now comes the rest of the command line after ibrun arguments
# <exec1> <exec2> ... <arg1> <arg2>
# expand all remaining file arguments (executable or not)
# to their full path
fullcmd=
for arg in "$@"; do
  if [[ -f $arg ]]; then
    cmd_fullpath=`which $arg 2>/dev/null`
    [[ $? -ne 0 ]] && cmd_fullpath="$arg"
  else
    cmd_fullpath="$arg"
  fi
  fullcmd="$fullcmd $cmd_fullpath"
  shift
done


#----------------------------------------------------------------------------------------
#
#                 Get info about how tasks are distributed per node
#
#----------------------------------------------------------------------------------------
declare -a node_clusters=(`echo $SLURM_TASKS_PER_NODE | sed -e 's/,/ /g'`)

# Check if we're inside SLURM
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

  debug_print "TOTAL_NODES  = ${total_nodes}"
  debug_print "TOTAL_NTASKS = ${task_count}"
  debug_print "NODE_TASKS_PPN_INFO = {# of tasks per node},{#initial task id}_[...]"
  debug_print "NODE_TASKS_PPN_INFO = ${NODE_TASKS_PPN_INFO}"
else
  err_print "Unknown batch system"
  exit 1
fi
std_print "NODE_TASKS_PPN_INFO=$NODE_TASKS_PPN_INFO"


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
[[ ! -d $home_batch_dir ]] && mkdir -p $home_batch_dir;

hostfile_veredas=`mktemp $home_batch_dir/job.$BATCH_JOB_ID.hostlist.XXXXXXXX`
[[ -f $hostfile_veredas ]] && rm -f $hostfile_veredas;

declare -a hostlist=(`scontrol show hostname $SLURM_NODELIST`)
if [ $? -ne 0 ]; then
  err_print "SLURM hostlist unavailable"
  exit 1
else
  debug_print "hostlist = ${hostlist[*]}"
fi

declare -i host_id=0
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
      # ((host_id++)) does not work (trapped error by setting 'set -e' at the top)!
      host_id=$((host_id+1))
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
      # ((host_id++)) does not work (trapped error by setting 'set -e' at the top)!
      host_id=$((host_id+1))
    done
  done
fi


#------------------------------------------------
#
#     MVAPICH2 default environment variables
#
#------------------------------------------------
if [[ x"" == "xmvapich2_ssh" || x"" == "xmvapich2_slurm" ]]; then
	[[ -z "$MV2_USE_UD_HYBRID" ]] && export MV2_USE_UD_HYBRID=0;
	# optimizing startup for homogeneous clusters
	[[ -z "$MV2_HOMOGENEOUS_CLUSTER" ]] && export MV2_HOMOGENEOUS_CLUSTER=1;
	[[ -z "$MV2_DEFAULT_TIME_OUT" ]] && export MV2_DEFAULT_TIME_OUT=23
	export MV2_IBA_HCA=mthca0
	export MV2_SHOW_CPU_BINDING=1
	# Intra-node kernel assistance
	# Use LIMIC2 only for large messages.
	# The switch point can be set as 'export MV2_SMP_EAGERSIZE=<nbytes>'
	[[ -z "$MV2_SMP_USE_LIMIC2" ]] && export MV2_SMP_USE_LIMIC2=1;
	[[ -z "$MV2_SMP_USE_CMA" ]] && export MV2_SMP_USE_CMA=0;
	[[ -z "$GFORTRAN_UNBUFFERED_ALL" ]] && export GFORTRAN_UNBUFFERED_ALL=y;

	export MV2_USE_RING_STARTUP=0 # if mpirun_rsh is used
	# export MV2_USE_RING_STARTUP=1 # used otherwise
	# export MV2_FASTSSH_THRESHOLD=50 # not need. the cluster is not that big
	# export MV2_NPROCS_THRESHOLD=

	# prefer MVAPICH2 automatic binding??
	# export MV2_CPU_BINDING_POLICY=bunch|scatter       [default=bunch]
	# export MV2_CPU_BINDING_LEVEL=core|socket|numanode [default=core]
	# export MV2_ENABLE_AFFINITY=1                      [default=1]

	# Starting from version 2.3 mvapich3 provides explicit
	# support for hybrid programming MPI+OpenMP
	# [[ -z "$MV2_CPU_BINDING_POLICY" ]] && export MV2_CPU_BINDING_POLICY=hybrid;
	# [[ x"$MV2_CPU_BINDING_POLICY" == "xhybrid" ]] && export MV2_HYBRID_BINDING_POLICY=spread;
	# [[ -z "$MV2_THREADS_PER_PROCESS" ]] && export MV2_THREADS_PER_PROCESS=$(( CPN/task_count ));
fi


#------------------------------------------------
#
#    Intel MPI default environment variables
#
#------------------------------------------------
if [ x"$MPI_MODE" == "ximpi_hydra" ]; then
	[[ -z "$I_MPI_DEBUG" ]] && export I_MPI_DEBUG=4;
	[[ -z "$I_MPI_FABRICS" ]] && export I_MPI_FABRICS=dapl;
fi


#----------------------------------------------------------------------------------------
#
#                            Start the parallel execution
#
#----------------------------------------------------------------------------------------
if [ x"$MPI_MODE" == "xmvapich2_ssh" ]; then
  launch_command="mpirun_rsh -ssh -np $MPI_NSLOTS -hostfile ${hostfile_veredas} $MY_MPIRUN_OPTIONS -export-all $fullcmd"
  std_print "$MPI_MODE launch command:"
  std_print "          $launch_command"
  if [ "$dry_run" -eq "0" ]; then
    mpirun_rsh -ssh -np $MPI_NSLOTS -hostfile ${hostfile_veredas} $MY_MPIRUN_OPTIONS -export-all $fullcmd
    res=$?
  else
    res=0
  fi
elif [ x"$MPI_MODE" == "xmvapich2_slurm" ]; then
  std_print "MVAPICH2+SLURM wrapping not yet implemented!\n SLURM needs first to be upgraded.\nExiting.\n"
  res=1
elif [ x"$MPI_MODE" == "ximpi_hydra" ]; then
  launch_command="mpiexec.hydra -np $MPI_NSLOTS --machinefile ${hostfile_veredas} -print-rank-map $MY_MPIRUN_OPTIONS $fullcmd"
  std_print "$MPI_MODE launch command:"
  std_print "          $launch_command"
  if [ "$dry_run" -eq "0" ]; then
    mpiexec.hydra -np $MPI_NSLOTS --machinefile ${hostfile_veredas} -print-rank-map $MY_MPIRUN_OPTIONS $fullcmd
    res=$?
  else
    res=0
  fi
elif [ x"$MPI_MODE" == "xopenmpi" ]; then
  std_print "OpenMPI wrapping not yet implemented!"
  std_print "Exiting."
  res=1
else
  std_print "Could not determine which MPI stack to use."
  std_print "Exiting."
  res=1
fi

if [ $res -ne 0 ]; then
  std_print "MPI job exited with code: $res"
fi

if [ x"$VEREDAS_KEEP_FILES" == "xn" -o x"$VEREDAS_KEEP_FILES" == "xN" -o x"$VEREDAS_KEEP_FILES" == "x0" ]; then
  if [ -f ${hostfile_veredas} ]; then
    std_print "Removing Hostfile ${hostfile_veredas}"
    rm -f ${hostfile_veredas}
  fi
fi

std_print "Shutdown complete. Exiting"
exit $res
