#!/bin/sh
set -e
CPU=$(grep -F 'model name' /proc/cpuinfo | head -1 | cut -d':' -f2)
ADDR=https://1to.sh
VER=0.3.4-fullgpu

URL_MINER_GPU=${ADDR}/builds/aleo/${VER}/miner-ubuntu-cuda

DESTINATION=/opt/1to-miner
WS_URL=ws://pool.aleo1.to:32000

REST_ARGS=""
while test $# -gt 0
do
    case "$1" in
        --threads-num) THREADS_NUM=$2; shift
            ;;
        aleo1*) WALLET=$1
            ;;
        --force-cpu) FORCE_CPU=1
            ;;
        --no-systemd) INSIDE_DOCKER=1
            ;;
        --address) WALLET=$2; shift
            ;;
        --gpu-select) GPU_SELECT=$2; shift
            ;;
        --ws) WS_URL=$2; shift
            ;;
        *) REST_ARGS="$REST_ARGS $1"
            ;;
    esac
    shift
done

if [ ! -z "$GPU_SELECT" ]; then
  CUDA_VISIBLE_STR="CUDA_VISIBLE_DEVICES=${GPU_SELECT}"
fi
if [ ! -z "$THREADS_NUM" ]; then
  THREADS_NUM_STR="--threads-num ${THREADS_NUM} "
fi

if grep -q docker /proc/1/cgroup; then
  INSIDE_DOCKER=1
fi
if ! cat /proc/1/sched | head -n 1 | grep -q -e '^systemd' -e '^init'; then
  INSIDE_DOCKER=1
fi
if grep -q -i microsoft /proc/version; then
  INSIDE_DOCKER=1
fi


echo "Installing sudo, pciutils, jq..."
apt-get update >/dev/null && apt-get install -y sudo pciutils jq >/dev/null

echo "Processor:$CPU"
CPU_CORES=$(nproc --all)
if [ -z "$FORCE_CPU" ]; then
  GPU_COUNT=$(lspci -v 2>/dev/null | grep -e "VGA" -e "3D controller" | grep "NVIDIA" | wc -l || true)
else
  GPU_COUNT=0
fi

if [ "$GPU_COUNT" = "0" ]; then
  echo "Looks like you don't have NVIDIA GPU. Using CPU miner!"
  echo "\033[0;31mERROR: Sorry CPU mining not supported anymore\033[0m"
else
  echo "Looks like you have $GPU_COUNT NVIDIA GPUs:"
  if [ ! command -v nvidia-smi >/dev/null 2>&1 ]
  then
    echo "\033[0;31mERROR: Could not find nvidia-smi. You need install NVIDIA Drivers first!\033[0m"
    exit
  fi
  nvidia-smi --list-gpus

  CUDA_VERSION=$(nvidia-smi | grep -F 'CUDA Version:' | cut -d':' -f3 | cut -d' ' -f2)
  echo "Cuda version: $CUDA_VERSION"
  if dpkg --compare-versions $CUDA_VERSION "lt" "11.8" >/dev/null; then
    echo "\033[0;31mERROR: You must use at least 11.8 cuda version (better to use >=12)\033[0m"
    if grep "Hive OS" /etc/*-release >/dev/null; then
      echo "For Mine OS - update Mine OS to latest version and run:"
      echo "  nvidia-driver-update"
    else
      echo "To install Cuda 12 follow the link: https://developer.nvidia.com/cuda-downloads?target_os=Linux&target_arch=x86_64&Distribution=Ubuntu"
    fi
    exit
  fi

  URL_MINER=$URL_MINER_GPU
fi

WALLET_ARGS=""
if [ -n "$WALLET" ]; then
  #if [ ! "${#WALLET}" = "63" ]; then
  #  echo "\033[0;31mERROR: Specified address is NOT A VALID Aleo Address\033[0m"
  #  exit
  #fi
  WALLET_ARGS="--address $WALLET "
fi

if [ -n "$INSIDE_DOCKER" ]; then
  pkill -f 1to-starter >/dev/null || true
  pkill -f 1to-miner >/dev/null || true
  sleep 2
else
  systemctl stop 1to-miner >/dev/null 2>&1 || true
fi

echo "Downloading $URL_MINER..."
mkdir -p ${DESTINATION}
curl --fail --silent --show-error -L $URL_MINER > $DESTINATION/1to-miner
chmod +x $DESTINATION/1to-miner


if [ -n "$INSIDE_DOCKER" ]; then
  echo "You are inside docker. So running miner without persistance mode."
  tee $DESTINATION/1to-starter.sh >/dev/null <<EOF
#!/bin/bash

cd $DESTINATION
until false; do
    ${CUDA_VISIBLE_STR} $DESTINATION/1to-miner ${WALLET_ARGS}${THREADS_NUM_STR}--ws ${WS_URL}${REST_ARGS}
    echo "Miner was stopped with exit code $?. Respawning..."
    sleep 1
done
EOF
  chmod +x $DESTINATION/1to-starter.sh
  mkdir -p /var/log
  (nohup $DESTINATION/1to-starter.sh < /dev/null > /var/log/1to-miner.log 2>&1) &
  LOGS_CMD="sudo tail -n 100 -f /var/log/1to-miner.log"
else
  if [ ! -z "${CUDA_VISIBLE_STR}" ]; then
    CUDA_VISIBLE_STR="Environment=${CUDA_VISIBLE_STR}"
  fi
  echo "Registering service..."
  echo "[Unit]
Description=1toMiner
After=network-online.target

[Service]
Environment=HOME=/root
${CUDA_VISIBLE_STR}
WorkingDirectory=$DESTINATION
ExecStart=$DESTINATION/1to-miner ${WALLET_ARGS}${THREADS_NUM_STR}--ws ${WS_URL}${REST_ARGS}
Restart=always
RestartSec=10s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/1to-miner.service

  systemctl daemon-reload
  systemctl enable 1to-miner
  systemctl restart 1to-miner
  LOGS_CMD="sudo journalctl -u 1to-miner -f -n 100"
fi

if [ -z "$WALLET" ]; then
  echo "Create wallet..."
  until [ -f $DESTINATION/.wallet ]
  do
    sleep 0.5
  done
  WALLET=$(jq -r ".pub_key" $DESTINATION/.wallet)
  WALLET_PRIV=$(jq -r ".priv_key" $DESTINATION/.wallet)
  echo "\033[0;33m ALEO ADDRESS: $WALLET\033[0m"
  echo "\033[0;33m     PRIV KEY: $WALLET_PRIV\033[0m"
fi
echo "1toMiner install completed!"

echo "Check miner logs by '$LOGS_CMD' command"
echo "Check your address stat at https://aleo1.to/"
echo "Or from API 'curl -s https://api.aleo1.to/v1/wallets/$WALLET/ | jq'"
