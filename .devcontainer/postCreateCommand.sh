#!/bin/bash

echo 'source /usr/share/bash-completion/completions/git' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -F __start_kubectl k' >> ~/.bashrc

sudo apt-get update
sudo apt-get install -y python3-dev python3-pip # python3.10-venv
pip install python-openstackclient jmespath
