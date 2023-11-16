#!/bin/bash

# This script will update the boot disk of SNO node to the volume mounted where coreos is downloaded and written by initial boot
# Run this script inside the bastion configured for pxe boot
# Once ./setup-sno.sh is invoked and machines are rebooted invoke this script to update the boot disk
# Usage: ./update-boot-disk.sh $IP_ADDRESS $INSTALLATION_DISK
#
# Sample usage: ./update-boot-disk.sh 192.168.140.105 /dev/disk/by-id/wwn-0x600507681381021ca800000000002cf2
#

set -x
set +e

IP_ADDRESS=$1
INSTALLATION_DISK=$2

SSH_OPTIONS=(-o 'PreferredAuthentications=publickey' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -i /root/.sno/id_rsa)

for _ in {1..20}; do
    echo "Set boot dev to disk in worker"
    ssh "${SSH_OPTIONS[@]}" core@${IP_ADDRESS} "sudo bootlist -m normal -o ${INSTALLATION_DISK}"
    if [ $? == 0 ]; then
        echo "Successfully set boot dev to disk in worker"
        break
    else
        echo "Retrying after a minute"
        sleep 60
    fi
done
