CLUSTER_NAME=$1
INSTALL_TYPE=$2

export OFFLINE_TOKEN_FILE=/root/.sno/offline-token
export CONFIG_DIR="/tmp/${CLUSTER_NAME}-config"

#################################
# for agent based install
#################################
get_cluster_id() {
    echo "Get cluster_id"
    for i in {1..30}; do
        curl -s -X GET "${API_URL}/infra-envs" \
             -H "Content-Type: application/json" | jq . > ${CONFIG_DIR}/infra-evns-output.json
        NEW_CLUSTER_ID=$(cat ${CONFIG_DIR}/infra-evns-output.json | jq '.[0].cluster_id' |  awk -F'"' '{print $2}')
        if [[ ! -z "${NEW_CLUSTER_ID}" ]]; then
            echo "NEW_CLUSTER_ID: ${NEW_CLUSTER_ID}"
            break
        fi
        sleep 30
    done
    if [[ -z "${NEW_CLUSTER_ID}" ]]; then
        echo "Could not get cluster ID"
        exit 1
    fi
}

get_cluster_status() {
  #echo "Get cluster status"
  curl -s -X GET "${API_URL}/clusters/${NEW_CLUSTER_ID}" \
       -H "Content-Type: application/json" | jq . > ${CONFIG_DIR}/cluster-status-output.json
}

start_install() {
  echo "Start install"
  curl -s -X POST "${API_URL}/clusters/${NEW_CLUSTER_ID}/actions/install" \
       -H "Content-Type: application/json" | jq . > ${CONFIG_DIR}/cluster-start-install-output.json
}

wait_to_install() {
  echo "wait to install"
  get_cluster_id
  for i in {1..15}; do
    get_cluster_status
    status=$(cat ${CONFIG_DIR}/cluster-status-output.json | jq '.status' | awk -F'"' '{print $2}')
    echo "Current cluster_status: ${status}"
    if [[ ${status} == "ready" ]]; then
      sleep 30
      start_install
    elif [[ ${status} == "installed" || ${status} == "installing" ]]; then
      break
    fi
    sleep 60
  done
}
###################################

sno_wait() {
    openshift-install --dir="${CONFIG_DIR}" wait-for bootstrap-complete
    openshift-install --dir="${CONFIG_DIR}" wait-for install-complete
}

agent_wait() {
    IP_ADDRESS=$(cat ${CONFIG_DIR}/rendezvousIP)
    API_URL="http://${IP_ADDRESS}:8090/api/assisted-install/v2"
    wait_to_install
    ./openshift-install --dir="${CONFIG_DIR}" agent wait-for bootstrap-complete
    ./openshift-install --dir="${CONFIG_DIR}" agent wait-for install-complete
}

assisted_wait() {
    . assisted-sno.sh
    ai_wait_compelete
}

if [[ ${INSTALL_TYPE} == "assisted" ]]; then
    assisted_wait
elif [[ ${INSTALL_TYPE} == "agent" ]]; then
    agent_wait
else
    sno_wait
fi
