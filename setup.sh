#!/bin/bash

set -euo pipefail

# set -x

# REQUIREMENTS:
# - kubectl
# - istioctl v1.8.*
# - kind
# - envtpl

if [ $# = 0 ]; then
    echo "istio multi-cluster CLI"
    echo
    echo "Usage:"
    echo "  $0 [command]"
    echo
    echo "Available Commands:"
    echo "  install    Installs an Istio Mesh to a set of kind clusters"
    echo "  uninstall  Deletes the previously created kind clusters"
    echo "  status     Attempts cross-cluster communication"
    exit 0
fi

function check_istioctl_version {
    output=$(istioctl version | grep 1.8)
    if [[ $? != 0 ]]; then
        echo "Wrong istioctl version. Quitting"
        exit $?
    fi
}

function metallb_setup {
    export METALLB_ADDRESS_RANGE=$1
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.9.3/manifests/namespace.yaml
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.9.3/manifests/metallb.yaml
    kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"
    cat metallb/metallb-config.yaml | envtpl | kubectl apply -f -
}

function node_setup {
    local instance=$1
    local lb_subnet=$2

    kind create cluster --name ${instance} --config $ISTIO/istio/prow/config/trustworthy-jwt.yaml
    metallb_setup ${lb_subnet}
}

function infra_setup {
    # get the kind Docker network subnet
    # SUBNET=$(docker network inspect kind --format '{{(index .IPAM.Config 0).Subnet}}')

    node_setup cluster1 "172.18.1.0 - 172.18.1.255"
    node_setup cluster2 "172.18.2.0 - 172.18.2.255"
}

function install_istio {
    local CONTEXT="$1"
    local CLUSTER="$2"
    local NETWORK="$3"

    kubectl --context="${CONTEXT}" create namespace istio-system
    kubectl --context="${CONTEXT}" label namespace istio-system topology.istio.io/network=${NETWORK}
    kubectl --context="${CONTEXT}" create secret generic cacerts -n istio-system \
        --from-file=certs/${CLUSTER}/ca-cert.pem \
        --from-file=certs/${CLUSTER}/ca-key.pem \
        --from-file=certs/${CLUSTER}/root-cert.pem \
        --from-file=certs/${CLUSTER}/cert-chain.pem

    istioctl --context=${CONTEXT} install -y -f "${CLUSTER}/istio.yaml"
    istioctl --context=${CONTEXT} install -y -f "${CLUSTER}/eastwest-gateway.yaml"
    kubectl --context=${CONTEXT} apply  -f expose-services.yaml
}


function install_applications {
    local CONTEXT="$1"

    kubectl --context="${CONTEXT}" create   namespace sample
    kubectl --context="${CONTEXT}" label namespace sample istio-injection=enabled
    kubectl --context="${CONTEXT}" apply -f helloworld.yaml -l service=helloworld -n sample

    kubectl --context="${CONTEXT}" apply -f sleep.yaml -n sample
    kubectl --context="${CONTEXT}" rollout status deployment sleep -n sample
}

check_istioctl_version

COMMAND=$1

if [ $COMMAND = "install" ]; then

    infra_setup

    install_istio kind-cluster1 cluster1 network1
    install_istio kind-cluster2 cluster2 network2

    CLUSTER1_IP="$(docker container inspect cluster1-control-plane --format '{{.NetworkSettings.Networks.kind.IPAddress}}')"
    CLUSTER2_IP="$(docker container inspect cluster2-control-plane --format '{{.NetworkSettings.Networks.kind.IPAddress}}')"

    istioctl x create-remote-secret \
        --context=kind-cluster1 \
        --name=cluster1 | \
        sed -e "s|\(server:\) .*|\1 https://${CLUSTER1_IP}:6443|" | \
        kubectl apply -f - --context=kind-cluster2

    istioctl x create-remote-secret \
        --context=kind-cluster2 \
        --name=cluster2 | \
        sed -e "s|\(server:\) .*|\1 https://${CLUSTER2_IP}:6443|" | \
        kubectl apply -f - --context=kind-cluster1

    echo -e "\nMulti-DC Istio cluster setup completed."

elif [ $COMMAND = "apps" ]; then

    install_applications kind-cluster1
    install_applications kind-cluster2

    kubectl --context=kind-cluster1 apply -f helloworld.yaml -l version=v1 -n sample
    kubectl --context=kind-cluster2 apply -f helloworld.yaml -l version=v2 -n sample
    kubectl --context=kind-cluster1 rollout status deployment helloworld-v1 -n sample
    kubectl --context=kind-cluster2 rollout status deployment helloworld-v2 -n sample

elif [ $COMMAND = "status" ]; then
    # TODO: add some real checking here whether we're hitting the service in the remote cluster

    kubectl exec --context=kind-cluster1 -n sample -c sleep \
    "$(kubectl get pod --context="kind-cluster1" -n sample -l \
    app=sleep -o jsonpath='{.items[0].metadata.name}')" \
    -- curl helloworld.sample:5000/hello 2>/dev/null

    kubectl exec --context=kind-cluster2 -n sample -c sleep \
    "$(kubectl get pod --context="kind-cluster2" -n sample -l \
    app=sleep -o jsonpath='{.items[0].metadata.name}')" \
    -- curl helloworld.sample:5000/hello 2>/dev/null

elif [ $COMMAND = "uninstall" ]; then

    kind delete cluster --name cluster1
    kind delete cluster --name cluster2

else

    echo "unknown command: $COMMAND"

fi
