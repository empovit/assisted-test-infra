#!/usr/bin/env bash

set -o nounset

export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
export NAMESPACE=${NAMESPACE:-assisted-installer}

PROXY_CONTAINER="nginx-proxy"
PROXY_IMAGE="nginx:1.19-alpine"

function print_log() {
    echo "$(basename $0): $1"
}

function url_reachable() {
    curl --insecure -s $1 --max-time 4 >/dev/null
    return $?
}

function spawn_port_forwarding_command() {
    service_name=$1
    external_port=$2
    service_host="$(minikube ip)"
    service_port="$(kubectl --kubeconfig=${KUBECONFIG} get svc/${service_name} -n ${NAMESPACE} -o=jsonpath='{.spec.ports[0].nodePort}')"

    echo "Clean up old proxy containers of ${service_name}"
    $CONTAINER_COMMAND stop "$PROXY_CONTAINER-$service_name" || true
    $CONTAINER_COMMAND rm "$PROXY_CONTAINER-$service_name" || true

    #TODO: Handle both TLS and non-TLS proxy
    #TODO: Reload config instead of re-creating containers

    echo "Generating proxy config for ${service_name}"
    cat <<EOF >build/nginx-proxy-${service_name}.conf
events {}
stream {
  upstream stream_backend {
    server ${service_host}:${service_port};
  }
  server {
    listen ${external_port} ssl;
    proxy_pass stream_backend;
    ssl_certificate       /etc/nginx/tls/server.cert;
    ssl_certificate_key   /etc/nginx/tls/server.key;
  }
}
EOF

    echo "Starting a new proxy for ${service_name}"
    $CONTAINER_COMMAND run -d --network=host -p ${external_port}:${service_port} \
      -v "$PWD/build/nginx-proxy-${service_name}.conf:/etc/nginx/nginx.conf:ro" \
      -v "$PWD/assisted-service/build/assisted-service.crt:/etc/nginx/tls/server.cert:ro" \
      -v "$PWD/assisted-service/build/assisted-service-key.pem:/etc/nginx/tls/server.key:ro" \
      --label purpose=test-infra-proxy \
      --name "$PROXY_CONTAINER-${service_name}" $PROXY_IMAGE
}

function run_in_background() {
    bash -c "nohup $1  >/dev/null 2>&1 &"
}

function kill_all_port_forwardings() {
    echo "Cleaning up all proxy containers"
    to_remove=$(${CONTAINER_COMMAND} ps -a --format {{.ID}} --filter label=purpose=test-infra-proxy)
    $CONTAINER_COMMAND stop $to_remove || true
    $CONTAINER_COMMAND rm $to_remove || true
    sudo systemctl stop xinetd
}

function get_main_ip() {
    echo "$(ip route get 1 | sed 's/^.*src \([^ ]*\).*$/\1/;q')"
}

function wait_for_url_and_run() {
    RETRIES=15
    RETRIES=$((RETRIES))
    STATUS=1
    url_reachable "$1" && STATUS=$? || STATUS=$?

    until [ $RETRIES -eq 0 ] || [ $STATUS -eq 0 ]; do

        RETRIES=$((RETRIES - 1))

        echo "Running given function"
        $2

        echo "Sleeping for 30 seconds"
        sleep 30s

        echo "Verifying URL and port are accessible: $1"
        url_reachable "$1" && STATUS=$? || STATUS=$?
    done
    if [ $RETRIES -eq 0 ]; then
        echo "Timeout reached, URL $1 not reachable"
        exit 1
    fi
}

function close_external_ports() {
    sudo firewall-cmd --zone=public --remove-port=6000/tcp
    sudo firewall-cmd --zone=public --remove-port=6008/tcp
}

"$@"
