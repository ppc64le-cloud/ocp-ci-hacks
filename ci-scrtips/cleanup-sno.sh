#!/bin/bash

# This script tries to clean up things configured for SNO cluster by setup-sno.sh
# Run this script inside the bastion configured for pxe boot.
# Usage: ./cleanup-sno.sh $CLUSTER_NAME.
#
# Sample usage: ./cleanup-sno.sh test-cluster
#


set -x
set +e

export CLUSTER_NAME=$1
POWERVS_VSI_NAME="${CLUSTER_NAME}-worker"

CONFIG_DIR="/tmp/${CLUSTER_NAME}-config"
IMAGES_DIR="/var/lib/tftpboot/images/${CLUSTER_NAME}"
WWW_DIR="/var/www/html/${CLUSTER_NAME}"

rm -rf /tmp/${CLUSTER_NAME}* ${IMAGES_DIR} ${WWW_DIR}

LOCK_FILE="lockfile.lock"
(
flock -n 200 || exit 1;
echo "removing server host entry from dhcpd.conf"
HOST_ENTRY="host ${POWERVS_VSI_NAME}"
sed -i "/$(printf '%s' "$HOST_ENTRY")/d" /etc/dhcp/dhcpd.conf

systemctl restart dhcpd;

echo "removing menuentry from grub.cfg"
sed -i "/# menuentry for $(printf '%s' "${CLUSTER_NAME}") start/,/# menuentry for $(printf '%s' "${CLUSTER_NAME}") end/d" /var/lib/tftpboot/boot/grub2/grub.cfg

echo "restarting tftp & dhcpd"
systemctl restart tftp;
) 200>"$LOCK_FILE"
