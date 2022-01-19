#! /bin/bash -e

BASE="opensuse-4"
CONFDIR="/etc/libvirt/qemu"
RESDIR="/root/results"

if [[ ! -f "$CONFDIR/$BASE.xml" ]]; then 
    echo >&2 "File '$CONFDIR/$BASE.xml' doesn't exist"
    exit 1
fi

if virsh vcpuinfo "$BASE" | grep -q '^CPU Affinity:.*-'; then
    echo >&2 "File '$CONFDIR/$BASE.xml' already has pinning"
    exit 1
fi

if virsh list | grep -q 'running$'; then
    echo >&2 "There are VMs running, please shut them down"
    exit 1
fi

mkdir -p "$RESDIR"

exec 3>&1  # save stdout to spare file hanlde 3
exec 4>&2  # save stderr to spare file hanlde 4

#========== default cpu topology ==========
if ! virsh start "$BASE"; then
    echo >&2 "Failed to start $BASE"
    exit 1
fi

VMIP="$(virsh domifaddr "$BASE" | sed -nr 's,.* (\S*)/.*,\1,p')" 

WAIT="$((EPOCHSECONDS+40))"
while true; do
    if nc -nzw2 "$VMIP" 22; then
        break
    fi
    if [[ "$EPOCHSECONDS" -gt "$WAIT" ]]; then
        echo >&2 "VM $BASE failed to boot"
        exit 1
    fi
done

ssh root@"$VMIP" "date '+%F %T %Z'"

exec &>> "$RESDIR/$BASE-default"

echo "========== $(date '+%F %T %Z') =========="

ssh root@"$VMIP" cyclictest -a 0,1 -q -l 10000
