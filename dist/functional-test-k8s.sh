#!/bin/bash
ETCD_IMG="${ETCD_IMG:-quay.io/coreos/etcd:v3.2.7}"
ETCD_LOCATION="${ETCD_LOCATION:-etcd}"
FLANNEL_NET="${FLANNEL_NET:-10.10.0.0/16}"
TAG=`git describe --tags --dirty`
FLANNEL_DOCKER_IMAGE="${FLANNEL_DOCKER_IMAGE:-quay.io/coreos/flannel:$TAG}"
K8S_VERSION="${K8S_VERSION:-1.7.6}"

docker_ip=$(ip -o -f inet addr show docker0 | grep -Po 'inet \K[\d.]+')
etcd_endpt="http://$docker_ip:2379"
k8s_endpt="http://$docker_ip:8080"

setup_suite() {
    # Run etcd, killing any existing one that was running

    # Start etcd
    docker rm -f flannel-e2e-test-etcd >/dev/null 2>/dev/null
    docker run --name=flannel-e2e-test-etcd -d -p 2379:2379 $ETCD_IMG etcd --listen-client-urls http://0.0.0.0:2379 --advertise-client-urls $etcd_endpt >/dev/null
    sleep 1

    # Start a kubernetes API server
    docker rm -f flannel-e2e-k8s-apiserver >/dev/null 2>/dev/null
    docker run -d --net=host --name flannel-e2e-k8s-apiserver gcr.io/google_containers/hyperkube-amd64:v$K8S_VERSION \
      /hyperkube apiserver --etcd-servers=$etcd_endpt \
      --service-cluster-ip-range=10.101.0.0/16 --insecure-bind-address=0.0.0.0 --allow-privileged >/dev/null
    sleep 1

    while ! cat <<EOF |  docker run -i --rm --net=host gcr.io/google_containers/hyperkube-amd64:v$K8S_VERSION /hyperkube kubectl create -f - >/dev/null 2>/dev/null
apiVersion: v1
kind: Node
metadata:
  name: flannel1
  annotations:
    dummy: value
spec:
  podCIDR: 10.10.1.0/24
EOF
do
    sleep 1
done

cat <<EOF |  docker run -i --rm --net=host gcr.io/google_containers/hyperkube-amd64:v$K8S_VERSION /hyperkube kubectl create -f - >/dev/null 2>/dev/null
apiVersion: v1
kind: Node
metadata:
  name: flannel2
  annotations:
    dummy: value
spec:
  podCIDR: 10.10.2.0/24
EOF
}

teardown_suite() {
    # Teardown the etcd server
    docker rm -f flannel-e2e-test-etcd >/dev/null
    docker rm -f flannel-e2e-k8s-apiserver >/dev/null
}

teardown() {
	docker rm -f flannel-e2e-test-flannel1 >/dev/null 2>/dev/null
	docker rm -f flannel-e2e-test-flannel2 >/dev/null 2>/dev/null
}

start_flannel() {
    local backend=$1

	flannel_conf="{ \"Network\": \"$FLANNEL_NET\", \"Backend\": { \"Type\": \"${backend}\" } }"
    for host_num in 1 2; do
       docker rm -f flannel-e2e-test-flannel$host_num >/dev/null 2>/dev/null
       docker run -e NODE_NAME=flannel$host_num --privileged --name flannel-e2e-test-flannel$host_num -tid --entrypoint /bin/sh $FLANNEL_DOCKER_IMAGE >/dev/null
       docker exec flannel-e2e-test-flannel$host_num /bin/sh -c 'mkdir -p /etc/kube-flannel'
       echo $flannel_conf | docker exec -i flannel-e2e-test-flannel$host_num /bin/sh -c 'cat > /etc/kube-flannel/net-conf.json'
       docker exec -d flannel-e2e-test-flannel$host_num /opt/bin/flanneld --kube-subnet-mgr --kube-api-url $k8s_endpt
    done
}

create_ping_dest() {
    # add a dummy interface with $FLANNEL_SUBNET so we have a known working IP to ping
    for host_num in 1 2; do
       while ! docker exec flannel-e2e-test-flannel$host_num ls /run/flannel/subnet.env >/dev/null 2>&1; do
         sleep 0.1
       done

       # Use declare to allow the host_num variable to be part of the ping_dest variable name. -g is needed to make it global
       declare -g ping_dest$host_num=$(docker "exec" --privileged flannel-e2e-test-flannel$host_num /bin/sh -c '\
		source /run/flannel/subnet.env && \
		ip link add name dummy0 type dummy && \
		ip addr add $FLANNEL_SUBNET dev dummy0 && ip link set dummy0 up && \
		echo $FLANNEL_SUBNET | cut -f 1 -d "/" ')
    done
}

test_vxlan() {
    start_flannel vxlan
    create_ping_dest # creates ping_dest1 and ping_dest2 variables
    pings
}

test_udp() {
    start_flannel udp
    create_ping_dest # creates ping_dest1 and ping_dest2 variables
    pings
}

test_host-gw() {
    start_flannel host-gw
    create_ping_dest # creates ping_dest1 and ping_dest2 variables
    pings
}

pings() {
    # ping in both directions
	assert "docker exec -it --privileged flannel-e2e-test-flannel1 /bin/ping -c 5 $ping_dest2" "Host 1 cannot ping host 2"
	assert "docker exec -it --privileged flannel-e2e-test-flannel2 /bin/ping -c 5 $ping_dest1" "Host 2 cannot ping host 1"
}

test_manifest() {
    # This just tests that the API server accepts the manifest, not that it actually acts on it correctly.
    assert "cat ../Documentation/kube-flannel.yml |  docker run -i --rm --net=host gcr.io/google_containers/hyperkube-amd64:v$K8S_VERSION /hyperkube kubectl create -f -"
}