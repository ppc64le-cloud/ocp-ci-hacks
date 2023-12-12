# https://access.redhat.com/documentation/en-us/assisted_installer_for_openshift_container_platform/2023/html/assisted_installer_for_openshift_container_platform/index
# https://api.openshift.com/?urls.primaryName=assisted-service%20service
#

API_URL="https://api.openshift.com/api/assisted-install/v2"
OFFLINE_TOKEN_FILE="${OFFLINE_TOKEN_FILE:-/root/.sno/offline-token}"
PULL_SECRET_FILE="${PULL_SECRET_FILE:-/root/.sno/pull-secret}"
SSH_PUB_KEY_FILE="${PUBLIC_KEY_FILE:-/root/.sno/id_rsa.pub}"
OFFLINE_TOKEN=$(cat ${OFFLINE_TOKEN_FILE})
PULL_SECRET=$(cat ${PULL_SECRET_FILE} | tr -d '\n' | jq -R .)
SSH_PUB_KEY=$(cat ${SSH_PUB_KEY_FILE})

CONFIG_DIR="/tmp/${CLUSTER_NAME}-config"
IMAGES_DIR="/var/lib/tftpboot/images/${CLUSTER_NAME}"
WWW_DIR="/var/www/html/${CLUSTER_NAME}"

CPU_ARCH="ppc64le"
OCP_VERSION="${OCP_VERSION:-4.15}"
BASE_DOMAIN="${BASE_DOMAIN:-api.ai}"
CLUSTER_NAME="${CLUSTER_NAME:-sno}"
#SUBNET="${MACHINE_NETWORK}"

refresh_api_token() {
  echo "Refresh API token"
  export API_TOKEN=$( \
    curl \
    --silent \
    --header "Accept: application/json" \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "client_id=cloud-services" \
    --data-urlencode "refresh_token=${OFFLINE_TOKEN}" \
    "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token" \
    | jq --raw-output ".access_token" \
  )
}

create_cluster() {
  echo "Create cluster for ${CPU_ARCH}"
  cat > ${CONFIG_DIR}/cluster-create.json << EOF
{
    "base_dns_domain": "${BASE_DOMAIN}",
    "name": "${CLUSTER_NAME}",
    "cpu_architecture": "${CPU_ARCH}",
    "openshift_version": "${OCP_VERSION}",
    "high_availability_mode": "None",
    "user_managed_networking": true,
    "network_type": "OVNKubernetes",
    "cluster_network_cidr": "10.128.0.0/14",
    "cluster_network_host_prefix": 23,
    "service_network_cidr": "172.30.0.0/16",
    "pull_secret": ${PULL_SECRET},
    "ssh_public_key": "${SSH_PUB_KEY}"
}
EOF


  curl -s -X POST "${API_URL}/clusters" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${API_TOKEN}" \
      -d @${CONFIG_DIR}/cluster-create.json | jq . > ${CONFIG_DIR}/create-output.json

  export NEW_CLUSTER_ID=$(cat ${CONFIG_DIR}/create-output.json | jq '.id' | awk -F'"' '{print $2}')
  if [[ -z $NEW_CLUSTER_ID ]]; then
    echo "Failed to create the cluster ${CLUSTER_NAME}"
    cat ${CONFIG_DIR}/create-output.json
    exit 1
  fi
}

register_infra() {
  echo "Register the cluster: ${NEW_CLUSTER_ID}"

  cat > ${CONFIG_DIR}/cluster-register.json << EOF
{
    "cluster_id": "${NEW_CLUSTER_ID}",
    "name": "${CLUSTER_NAME}-infra-env",
    "cpu_architecture": "${CPU_ARCH}",
    "openshift_version": "${OCP_VERSION}",
    "image_type": "full-iso",
    "pull_secret": ${PULL_SECRET},
    "ssh_authorized_key": "${SSH_PUB_KEY}"
}
EOF

  curl -s -X POST "${API_URL}/infra-envs" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${API_TOKEN}" \
      -d @${CONFIG_DIR}/cluster-register.json | jq . > ${CONFIG_DIR}/register-output.json

  export NEW_INFRAENVS_ID=$(cat ${CONFIG_DIR}/register-output.json | jq '.id' | awk -F'"' '{print $2}')
  export ISO_URL=$(cat ${CONFIG_DIR}/register-output.json | jq '.download_url' | awk -F'"' '{print $2}')
  if [[ -z $ISO_URL ]]; then
    echo "Could not register cluster"
    cat ${CONFIG_DIR}/register-output.json
    exit 1
  fi
}

download_iso() {

  echo "Downloading ISO ${ISO_URL} ..."
  curl ${ISO_URL} -o ${CONFIG_DIR}/assisted.iso

  if [[ -f "${CONFIG_DIR}/assisted.iso" ]]; then
    echo "Extract pxe files from ISO"
    rm -rf ${CONFIG_DIR}/pxe
    mkdir ${CONFIG_DIR}/pxe
    coreos-installer iso ignition show ${CONFIG_DIR}/assisted.iso > ${CONFIG_DIR}/pxe/assisted.ign
    coreos-installer iso extract pxe -o ${CONFIG_DIR}/pxe ${CONFIG_DIR}/assisted.iso

    echo "install pxe file to tftp/http"
    cp ${CONFIG_DIR}/pxe/assisted-initrd.img ${IMAGES_DIR}/initramfs.img
    cp ${CONFIG_DIR}/pxe/assisted-vmlinuz ${IMAGES_DIR}/kernel
    chmod +x ${IMAGES_DIR}/*
    cp ${CONFIG_DIR}/pxe/assisted-rootfs.img ${WWW_DIR}/rootfs.img
    chmod +x ${WWW_DIR}/rootfs.img
    cp ${CONFIG_DIR}/pxe/assisted.ign ${WWW_DIR}/bootstrap.ign
  else
    echo "Failed to download ISO: ${ISO_URL}"
    exit 1
  fi
}

get_cluster_status() {
  #echo "Get cluster status"
  curl -s -X GET "${API_URL}/clusters/${NEW_CLUSTER_ID}" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${API_TOKEN}" | jq . > ${CONFIG_DIR}/cluster-status-output.json
}

start_install() {
  echo "Start install"
  curl -s -X POST "${API_URL}/clusters/${NEW_CLUSTER_ID}/actions/install" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${API_TOKEN}" | jq . > ${CONFIG_DIR}/cluster-start-install-output.json
}

download_kubeconfig() {
  echo "Download kubeconfig"
  mkdir -p ${CONFIG_DIR}/auth
  curl -s -X GET "${API_URL}/clusters/${NEW_CLUSTER_ID}/downloads/credentials?file_name=kubeconfig" \
      -H "Authorization: Bearer ${API_TOKEN}" > ${CONFIG_DIR}/auth/kubeconfig
  curl -s -X GET "${API_URL}/clusters/${NEW_CLUSTER_ID}/downloads/credentials?file_name=kubeadmin-password" \
      -H "Authorization: Bearer ${API_TOKEN}" > ${CONFIG_DIR}/auth/kubeadmin-password
  mkdir -p ~/.kube
  cp ${CONFIG_DIR}/auth/kubeconfig ~/.kube/config
}

wait_to_install() {
  echo "wait to install"
  refresh_api_token
  for i in {1..15}; do
    get_cluster_status
    status=$(cat ${CONFIG_DIR}/cluster-status-output.json | jq '.status' | awk -F'"' '{print $2}')
    echo "Current cluster_status: ${status}"
    if [[ ${status} == "ready" ]]; then
      sleep 30
      start_install
    elif [[ ${status} == "installed" || ${status} == "installing" ]]; then
      download_kubeconfig
      break
    fi
    sleep 60
  done
}

wait_install_complete() {
  echo "wait the installation completed"
  pre_status=""
  for count in {1..10}; do
    echo "Refresh token: ${count}"
    refresh_api_token
    for i in {1..15}; do
      get_cluster_status
      status=$(cat ${CONFIG_DIR}/cluster-status-output.json | jq '.status' | awk -F'"' '{print $2}')
      if [[ ${pre_status} != ${status} ]]; then
        echo "Current installation status: ${status} : ${i}"
        pre_status=${status}
      fi
      if [[ ${status} == "installed" ]]; then
        echo "Done of OCP installation" 
        break
      fi
      sleep 60
    done
    if [[ ${status} == "installed" ]]; then
      break
    fi
  done
}

ai_prepare_cluster() {
  refresh_api_token
  create_cluster
  register_infra
  download_iso
}

ai_wait_compelete() {
  export NEW_CLUSTER_ID=$(cat ${CONFIG_DIR}/create-output.json | jq '.id' | awk -F'"' '{print $2}')
  wait_to_install
  wait_install_complete
}

main() {
  ai_prepare_cluster
  echo "To restart the VM and wait for 2 mins"
  sleep 120
  ai_wait_complete
}

# main
# echo "cluster info: "
# oc get clusterversion
# oc get nodes
# echo "Done"

