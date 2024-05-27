#!/bin/bash

########## Install Utill ########
apt install -y git

########## Move Miner Directory ########
cd /MineOS/miner/config

########## Download ########
git clone https://github.com/cryptoecc/WorldLand

########## Build ########
cd WorldLand
make worldland
make all


########## Make Workspace ########
mkdir -p work
