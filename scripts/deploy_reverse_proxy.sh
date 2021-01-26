#!/bin/sh

PORT=`cat haproxy.cfg | grep bind | awk -F'[: ]+' '{print $3}'`
CONTAINER=reverse-proxy

echo "Removing old reverse proxy container"
podman rm -f "$CONTAINER" || true

echo "Opening port in firewall"
firewall-cmd --add-port=$PORT/tcp --zone=libvirt

echo "Starting proxy at $PORT"
podman run -d \
  --privileged \
  --net=host \
  --name "$CONTAINER" \
  -v "$(pwd)"/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg \
  docker.io/haproxy:latest
