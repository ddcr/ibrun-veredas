#!/bin/bash
#
# 16 GB

MEM_PER_CPU_GB=

CPU_BIND_OPT=verbose,rank_ldom
#!NTASKS=9
NTASKS=9
# --- CPUS_PER_TASK=8 => one MPI process per computational node (machine)
# --- CPUS_PER_TASK=4 => one MPI process per socket (there are 2 sockets per node)
# --- CPUS_PER_TASK=2 => one MPI process per cache L2 domain (there are 2 cache domain per socket)
# --- CPUS_PER_TASK=1 => one MPI process per core (there are 8 cores per comput. node)
CPUS_PER_TASK=2
NTASKS_PER_NODE=
NODES=

#GROUP=eng772
GROUP=testes
PARTITION=short

# ========== choose partition 'short' for testing 
#!SALLOC_OPTS="-U eng772 -p long -t 5:00:00 -J NFF_Multipolos"
SALLOC_OPTS="-U $GROUP -p $PARTITION -J NFF_Multipolos"

SALLOC_OPTS="${SALLOC_OPTS} --ntasks=${NTASKS} --exclusive --cpu_bind=${CPU_BIND_OPT}"

if [ ! -z ${CPUS_PER_TASK:+x} ]; then
    SALLOC_OPTS="${SALLOC_OPTS} --cpus-per-task=${CPUS_PER_TASK}";
elif [ ! -z ${NTASKS_PER_NODE:+x} ]; then
    SALLOC_OPTS="${SALLOC_OPTS} --ntasks-per-node=${NTASKS_PER_NODE}";
elif [ ! -z ${NODES:+x} ]; then
    SALLOC_OPTS="${SALLOC_OPTS} --nodes=${NODES}";
else
    echo "DEFINE either CPUS_PER_TASK, NTASKS_PER_NODE or NODES";
fi

if [ ! -z ${MEM_PER_CPU_GB:+x} ]; then
    SALLOC_OPTS="${SALLOC_OPTS} --mem-per-cpu=$(($MEM_PER_CPU_GB*1024))"
fi

#========== Infiniband constraint for MPI processes
#!SALLOC_OPTS="${SALLOC_OPTS} --constraint=ib"




# ============================== SRUN ===============================
SRUN_OPTS="--pty"
SRUN_OPTS="${SRUN_OPTS} --mpi=none"
# SRUN_OPTS="${SRUN_OPTS} --mpi=openmpi"
# SRUN_OPTS="${SRUN_OPTS} --mpi=mvapich"

# =============================== MAIN ===============================
echo "/usr/bin/salloc ${SALLOC_OPTS} /usr/bin/srun ${SRUN_OPTS} /bin/bash -l"
/usr/bin/salloc ${SALLOC_OPTS} /usr/bin/srun ${SRUN_OPTS} /bin/bash -l
