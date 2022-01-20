#! /bin/bash -e

NAME="opensuse-4"           # name of the VM to use for testing
RESDIR="/root/results"      # path to directory for test results
VMIP=                       # global to hold the current VM's IP address

#============== initial checks =============================================

# check that the named VM exists
if ! virsh list --all | grep -qE "^ *\S+ +$NAME +"; then
    echo >&2 "VM $NAME doesn't exist"
    exit 1
fi

# check that the named VM does not already have vCPU pinning
if virsh vcpuinfo "$NAME" | grep -q '^CPU Affinity:.*-'; then
    echo >&2 "VM $NAME already has vCPU pinning"
    exit 1
fi

# check that there are no running VMs
if virsh list | grep -q 'running$'; then
    echo >&2 "There are VMs running, please shut them down"
    exit 1
fi

# ensure that the results output dir exists
mkdir -p "$RESDIR"

exec 3>&1   # save stdout to spare file handle 3
exec 4>&2   # save stderr to spare file handle 4

#============== functions ==================================================

# all the tests to run via ssh
# arg is the topology name
runtests() {
    exec &>> "$RESDIR/$NAME-$1" # redirect all stdout and stderr to the results file
    echo "==================== Starting $(date '+%F %T %Z') ===================="
    cat "$RESDIR/.topo"


    echo; echo "---------- cyclictest ----------"
    sshrun cyclictest -a 0,1 -q -l 10000


    echo; echo "==================== Stopping $(date '+%F %T %Z') ===================="; echo
    exec >&3 2>&4 # end the redirection
}

# factor out the tedious repetition of ssh root@"$VMIP"
sshrun() { ssh root@"$VMIP" "$@" }

# start the VM with the given vCPU pinning
# with no args, it starts the VM without pinning
# otherwise the args are the host CPU numbers to pin to, eg:
# vmstart 1 17 2 18
vmstart() {
    local N=0 PIN=""
    while [[ $# -ne 0 ]]; do
        PIN="$PIN,vcpupin$N.vcpu=$N,vcpupin$N.cpuset=$1"
        N="$((N+1))"
        shift
    done
    if [[ -n "$PIN" ]]; then
        virt-xml "$NAME" --build-xml --cputune=clearxml=yes"$PIN"
    else
        echo "No vCPU pinning"
    fi > "$RESDIR/.topo"
    if ! virsh create <(virt-xml "$NAME" --edit --cputune=clearxml=yes"$PIN" --print-xml); then
        echo >&2 "Failed to start $NAME"
        exit 1
    fi
    getip       # also get the IP
    waitssh     # also wait for ssh daemon
}

# read the IP of the VM
getip() {
    VMIP="$(virsh domifaddr "$NAME" | sed -nr 's,.* (\S*)/.*,\1,p')"
}

# wait for the VM to boot and ssh daemon to be ready
waitssh() {
    local WAIT
    WAIT="$((EPOCHSECONDS+40))"
    while true; do
        if nc -nzw2 "$VMIP" 22; then
            break
        fi
        if [[ "$EPOCHSECONDS" -gt "$WAIT" ]]; then
            echo >&2 "VM $NAME failed to boot"
            exit 1
        fi
        sleep 2
    done
}

# tell the VM to shutdown
vmstop() {
    ssh root@"$VMIP" poweroff
    waitstop    # also wait for it to shut down
}

# wait for the VM to shutdown
waitstop() {
    WAIT="$((EPOCHSECONDS+20))"
    while true; do
        if virsh list --all | grep -qE "^ *\S+ +$NAME +shut off$"; then
            break
        fi
        if [[ "$EPOCHSECONDS" -gt "$WAIT" ]]; then
            echo >&2 "VM $NAME failed to shut down"
            exit 1
        fi
        sleep 2
    done
}

#============== default unpinned topology ==================================

vmstart

# check ssh connection before running any tests
# so the user can enter YES at the prompt before continuing
ssh root@"$VMIP" "date '+%F %T %Z'"

runtests no-pin
vmstop

#============== four independent cores =====================================

vmstart 0 2 4 6
runtests indep-4x1
vmstop

#============== two hyperthread pairs ======================================

vmstart 1 17 2 18
runtests ht-2x2
vmstop

