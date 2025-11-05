#!/usr/bin/env bash
# ===========================================================
# P1 Monitor Helper Script voor Proxmox
# Zie Marcel Claassen: https://marcel.duketown.com/p1-monitor-docker-versie/
# ===========================================================

set -euo pipefail

############# Config #############
CTID="${CTID:-}"
HOSTNAME="${HOSTNAME:-p1monitor}"
MEMORY_MB="${MEMORY_MB:-1024}"
CORES="${CORES:-2}"
DISK_GB="${DISK_GB:-8}"
BRIDGE="${BRIDGE:-vmbr0}"
VLAN_TAG="${VLAN_TAG:-}"
STATIC_IP="${STATIC_IP:-}"
GATEWAY_IP="${GATEWAY_IP:-}"
NAMESERVER="${NAMESERVER:-1.1.1.1}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
P1MON_HTTP_PORT="${P1MON_HTTP_PORT:-81}"
P1MON_DIR="${P1MON_DIR:-/opt/p1mon}"

# De TCP-bron van je slimme meter
# voorbeeld: TCP4:192.168.1.50:23
SOCAT_TARGET="${SOCAT_TARGET:-TCP4:192.168.1.50:23}"

# Virtuele seriële poort binnen de container
VIRTUAL_SERIAL="/dev/ttyUSB0"
##################################

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $*";  }
die()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Vereiste command ontbreekt: $1"; }
require_cmd pct

# ---- Helper: kies volgende vrije CTID ----
autopick_ctid() {
  if command -v pvesh >/dev/null 2>&1; then
    pvesh get /cluster/nextid 2>/dev/null && return
  fi
  local max=100
  if pct list >/dev/null 2>&1; then
    max=$(pct list | awk 'NR>1 {print $1}' | sort -n | tail -n1)
  fi
  echo $((max + 1))
}

if [[ -z "$CTID" ]]; then
  CTID=$(autopick_ctid)
  info "Gebruik volgende vrije CTID: ${CTID}"
fi

# ---- Template ophalen ----
pveam update >/dev/null 2>&1 || true
TEMPLATE=$(pveam available --section system | awk '/debian-12.*standard.*\.tar\.zst/ {print $2}' | tail -n1)
[[ -n "$TEMPLATE" ]] || die "Geen Debian 12 template gevonden."
if ! pveam list "$TEMPLATE_STORAGE" | awk '{print $2}' | grep -qx "$TEMPLATE"; then
  info "Download template $TEMPLATE..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

# ---- Container maken ----
NETCFG="name=eth0,bridge=${BRIDGE}"
[[ -n "$VLAN_TAG" ]] && NETCFG="${NETCFG},tag=${VLAN_TAG}"
[[ -n "$STATIC_IP" ]] && NETCFG="${NETCFG},ip=${STATIC_IP},gw=${GATEWAY_IP}" || NETCFG="${NETCFG},ip=dhcp"

if pct status "$CTID" >/dev/null 2>&1; then
  info "Container $CTID bestaat al, overslaan aanmaken..."
else
  info "Maak CT $CTID aan..."
  pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    -hostname "$HOSTNAME" \
    -cores "$CORES" \
    -memory "$MEMORY_MB" \
    -rootfs "${STORAGE}:${DISK_GB}" \
    -features nesting=1 \
    -unprivileged 0 \
    -net0 "$NETCFG" \
    -nameserver "$NAMESERVER" \
    -onboot 1
fi

pct start "$CTID" || die "Kan container niet starten."

ct_exec() { pct exec "$CTID" -- bash -lc "$*"; }

# ---- Docker + SOCAT installeren ----
info "Installeer Docker + socat in CT..."
ct_exec "apt-get update -y && apt-get install -y ca-certificates curl gnupg socat"
ct_exec "install -m 0755 -d /etc/apt/keyrings"
ct_exec "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
ct_exec "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$(. /etc/os-release; echo \$VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list"
ct_exec "apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin"
ok "Docker en socat geïnstalleerd."

# ---- Virtuele poort aanmaken ----
info "Maak virtuele seriële poort aan via socat..."
ct_exec "nohup socat pty,link=${VIRTUAL_SERIAL},raw,echo=0 ${SOCAT_TARGET} &>/tmp/socat.log & disown"
ct_exec "sleep 2"
ct_exec "ls -l ${VIRTUAL_SERIAL}" || warn "Virtuele poort nog niet zichtbaar; check socat.log"

# ---- P1 Monitor volumes ----
ct_exec "mkdir -p ${P1MON_DIR}/alldata/{data,mnt/usb,mnt/ramdisk}"

# ---- docker-compose.yml ----
info "Schrijf docker-compose.yml..."
ct_exec "cat > ${P1MON_DIR}/docker-compose.yml <<'YAML'
services:
  p1monitor:
    hostname: ${HOSTNAME}
    image: mclaassen/p1mon
    ports:
      - "${P1MON_HTTP_PORT}:80"
    volumes:
      - ./alldata/data:/p1mon/data
      - ./alldata/mnt/usb:/p1mon/mnt/usb
      - ./alldata/mnt/ramdisk:/p1mon/mnt/ramdisk
    devices:
      - "${VIRTUAL_SERIAL}:${VIRTUAL_SERIAL}"
    tmpfs:
      - /run
      - /tmp
    restart: unless-stopped
YAML"

# ---- Start container stack ----
info "Start P1 Monitor..."
ct_exec "cd ${P1MON_DIR} && docker compose up -d"

# ---- Toon IP ----
IP=$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" | tr -d '\r')
echo
echo "================================================="
echo "✅  P1 Monitor draait!"
echo "URL: http://${IP}:${P1MON_HTTP_PORT}"
echo "Virtuele poort: ${VIRTUAL_SERIAL} (via socat → ${SOCAT_TARGET})"
echo "Container ID: ${CTID}"
echo "================================================="
