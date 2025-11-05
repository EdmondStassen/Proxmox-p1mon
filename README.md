# Proxmox-p1mon
Script to initiate P1 monitor (ZTATZ) on Proxmox server


bash <(curl -fsSL https://raw.githubusercontent.com/EdmondStassen/Proxmox-p1mon//main/p1mon-proxmox-setup.sh)

SOCAT_CONF="TCP4:192.168.179.21:23" | curl -fsSL https://raw.githubusercontent.com/EdmondStassen/Proxmox-p1mon//main/p1mon-proxmox-setup.sh | sed 's/\r$//' | bash

