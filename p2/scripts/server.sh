#!/bin/bash
set -e

apt-get update -qq
apt-get install -y curl

IFACE=$(ip -o -4 addr show | awk '$2 != "lo" && $2 !~ /eth0|enp0s3/ {print $2; exit}')

curl -sfL https://get.k3s.io | sh -s - server \
  --node-ip=192.168.56.110 \
  --bind-address=192.168.56.110 \
  --flannel-iface=$IFACE \
  --write-kubeconfig-mode=644 \
  --disable metrics-server

  until kubectl get nodes >/dev/null 2>&1; do
  sleep 2
done

kubectl apply -f /vagrant/confs/app1.yaml
kubectl apply -f /vagrant/confs/app2.yaml
kubectl apply -f /vagrant/confs/app3.yaml
kubectl apply -f /vagrant/confs/ingress.yaml