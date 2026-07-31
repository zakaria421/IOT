#!/bin/bash
set -e
apt-get update -qq
apt-get install -y curl

IFACE=$(ip -o -4 addr show | awk '$2 != "lo" && $2 !~ /eth0|enp0s3/ {print $2; exit}')

until [ -f /vagrant/confs/node-token ]; do
  sleep 2
done

K3S_TOKEN=$(cat /vagrant/confs/node-token)

curl -sfL https://get.k3s.io | K3S_URL="https://192.168.56.110:6443" K3S_TOKEN="$K3S_TOKEN" sh -s - agent \
  --node-ip=192.168.56.111 \
  --flannel-iface=$IFACE