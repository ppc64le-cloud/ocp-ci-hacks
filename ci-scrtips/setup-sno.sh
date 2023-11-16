#!/bin/bash

# This script tries to setup things required for creating a SNO cluster via bastion
# Run this script inside the bastion configured for pxe boot which will generate ignition config and configure the net boot for SNO node to boot
# Need to create the SNO worker before running this script to retrieve mac, ip addresses and volume wwn to use it as a installation disk while generating the ignition for SNO
# Volume wwn will usually in 600507681381021CA800000000002CF2 this format need to format it like this /dev/disk/by-id/wwn-0x600507681381021ca800000000002cf2 and pass it to the script
#
# Usage: ./setup-sno.sh $CLUSTER_NAME $BASE_DOMAIN $MACHINE_NETWORK $INSTALLATION_DISK $ROOTFS_URL $KERNEL_URL $INITRAMFS_URL $BASTION_HTTP_URL $MAC_ADDRESS $IP_ADDRESS
# $CLUSTER_NAME $BASE_DOMAIN $MACHINE_NETWORK $INSTALLATION_DISK are required to create install-config.yaml to generate the ignition via single-node-ignition-config openshift-install command
# MAC, IP and ISO URLs are required to download and setup the net boot for SNO node
#
# Sample usage: ./setup-sno.sh test-cluster ocp-dev-ppc64le.com 192.168.140.0/24 /dev/disk/by-id/wwn-0x600507681381021ca800000000002cf2 https://mirror.openshift.com/pub/openshift-v4/ppc64le/dependencies/rhcos/4.14/latest/rhcos-live-rootfs.ppc64le.img https://mirror.openshift.com/pub/openshift-v4/ppc64le/dependencies/rhcos/4.14/latest/rhcos-live-kernel-ppc64le https://mirror.openshift.com/pub/openshift-v4/ppc64le/dependencies/rhcos/4.14/latest/rhcos-live-initramfs.ppc64le.img http://rh-sno-ci-bastion.ocp-dev-ppc64le.com fa:c2:10:e3:5a:20 192.168.140.105
#

set -euox pipefail

export CLUSTER_NAME=$1
export BASE_DOMAIN=$2
export MACHINE_NETWORK=$3
export INSTALLATION_DISK=$4
ROOTFS_URL=$5
KERNEL_URL=$6
INITRAMFS_URL=$7
BASTION_HTTP_URL=$8
export MAC_ADDRESS=$9
IP_ADDRESS=${10}

IFS=""

POWERVS_VSI_NAME="${CLUSTER_NAME}-worker"

set +x

export PULL_SECRET="$(cat /root/.sno/pull-secret)"
SSH_PUB_KEY_FILE=/root/.sno/id_rsa.pub
export SSH_PUB_KEY="$(cat $SSH_PUB_KEY_FILE)"

set -x

CONFIG_DIR="/tmp/${CLUSTER_NAME}-config"
IMAGES_DIR="/var/lib/tftpboot/images/${CLUSTER_NAME}"
WWW_DIR="/var/www/html/${CLUSTER_NAME}"

mkdir -p $CONFIG_DIR $IMAGES_DIR $WWW_DIR

cat install-config-template.yaml | envsubst > ${CONFIG_DIR}/install-config.yaml

openshift-install --dir=${CONFIG_DIR} create single-node-ignition-config

cp ${CONFIG_DIR}/bootstrap-in-place-for-live-iso.ign ${WWW_DIR}/bootstrap.ign
chmod 644 ${WWW_DIR}/bootstrap.ign
curl ${ROOTFS_URL} -o ${WWW_DIR}/rootfs.img

curl ${INITRAMFS_URL} -o ${IMAGES_DIR}/initramfs.img
curl ${KERNEL_URL} -o ${IMAGES_DIR}/kernel

export GRUB_MAC_CONFIG="\${net_default_mac}"
export ROOTFS_URL=${BASTION_HTTP_URL}/${CLUSTER_NAME}/rootfs.img
export IGNITION_URL=${BASTION_HTTP_URL}/${CLUSTER_NAME}/bootstrap.ign
export KERNEL_PATH="images/${CLUSTER_NAME}/kernel"
export INITRAMFS_PATH="images/${CLUSTER_NAME}/initramfs.img"

GRUB_MENU_START="# menuentry for ${CLUSTER_NAME} start\n"
GRUB_MENU_END="\n# menuentry for ${CLUSTER_NAME} end"

GRUB_MENU_OUTPUT+=${GRUB_MENU_START}
MENU_ENTRY_CONTENT=$(cat grub-menu.template | envsubst)
GRUB_MENU_OUTPUT+=${MENU_ENTRY_CONTENT}
GRUB_MENU_OUTPUT+=${GRUB_MENU_END}

GRUB_MENU_OUTPUT_FILE="/tmp/${CLUSTER_NAME}-grub-menu.output"
echo -e ${GRUB_MENU_OUTPUT} > ${GRUB_MENU_OUTPUT_FILE}

LOCK_FILE="lockfile.lock"
(
flock 200 || exit 1
echo "writing menuentry to grub.cfg "
sed -i -e "/menuentry 'RHEL CoreOS (Live)' --class fedora --class gnu-linux --class gnu --class os {/r $(printf '%s' "$GRUB_MENU_OUTPUT_FILE")" /var/lib/tftpboot/boot/grub2/grub.cfg;
systemctl restart tftp;

echo "writing host entries to dhcpd.conf"
HOST_ENTRY="host ${POWERVS_VSI_NAME} { hardware ethernet ${MAC_ADDRESS}; fixed-address ${IP_ADDRESS}; }"
sed -i "/# Static entries/a\    $(printf '%s' "$HOST_ENTRY")" /etc/dhcp/dhcpd.conf;

echo "restarting services tftp & dhcpd"
systemctl restart dhcpd;
)200>"$LOCK_FILE"

