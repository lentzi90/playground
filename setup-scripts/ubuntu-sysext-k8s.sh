#!/usr/bin/env bash

apt-get install -y conntrack socat
# Install crictl
curl -sSL -o /tmp/crictl.tar.gz https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.32.0/crictl-v1.32.0-linux-amd64.tar.gz
tar --extract --file /tmp/crictl.tar.gz
mv crictl /usr/local/bin/
# Folders where we store the raw files
mkdir -p /opt/extensions/crio
mkdir -p /opt/extensions/kubernetes
# Folder where systemd-sysext will look for the images
mkdir -p /var/lib/extensions
curl -o /opt/extensions/crio/crio-v1.31.3.raw -L https://github.com/flatcar/sysext-bakery/releases/download/latest/crio-v1.31.3-x86-64.raw
curl -o /opt/extensions/kubernetes/kubernetes-v1.32.0.raw -L https://github.com/flatcar/sysext-bakery/releases/download/latest/kubernetes-v1.32.0-x86-64.raw
ln -s /opt/extensions/crio/crio-v1.31.3.raw /var/lib/extensions/crio.raw
ln -s /opt/extensions/kubernetes/kubernetes-v1.32.0.raw /var/lib/extensions/kubernetes.raw
systemctl enable --now systemd-sysext
systemctl restart systemd-sysext
# Make sure crio is running before continuingt o kubeadm init
systemctl enable --now crio
# Apply sysctl settings (ip forwarding)
sysctl --system
