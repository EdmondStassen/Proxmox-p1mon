#!/usr/bin/env bash
# ===========================================================
# P1 Monitor Helper Script voor Proxmox
# Zie Marcel Claassen: https://marcel.duketown.com/p1-monitor-docker-versie/
# ===========================================================

#!/usr/bin/env bash
# ===========================================================
# P1 Monitor Helper Script voor Proxmox
# -----------------------------------------------------------
# Maakt automatisch een Debian 12 LXC, installeert Docker,
# zet P1 Monitor op met een virtuele seriële poort via socat.
# -----------------------------------------------------------
# Auteur: ChatGPT (GPT-5)
# ===========================================================

set -euo pipefail

############# Config #############
CTID="${CTID:-}"                    # Automatisch bepaald als leeg
HOSTNAME="${HOSTNAME:-p1monitor}"   # Naam van de container
MEMORY_MB="${MEMORY_MB:-1024}"      # RAM in MB
CORES="${CORES:-2}"                 # CPU cores
DISK_GB="${DISK_GB:-8}"             # Rootfs grootte in GB
BRIDGE="${BRIDGE:-vmbr0}"           # Netwerk bridge
VLAN_TAG="${VLAN_TAG:-}"            # Optioneel VLAN
STATIC_IP="${STATIC_IP:-}"          # bv. 192.168.1.123/24  (leeg = DHCP)
GATEWAY_IP="${GATEWAY_IP:-}"        # bv. 192.168.1.1
NAMESERVER="${NAMESERVER:-1.1.1.1}" # DNS in CT
STORAGE="${STORAGE:-local-lvm}"     # Opslag
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"  # Voor templates
P1MON_HTTP_PORT="${P1MON_HTTP_PORT:-81}"       # Externe poort

# TCP-bron van je slimme-meter-gateway (PAS DIT AAN!)
SOCAT_TARGET="${SOCAT_TARGET:-TCP4:192.168.1.50:23}"

# Locaties in de container
P1MON_DIR="${P1MON_DIR:-/opt/p1mon}"
VIRTUAL_SERIAL="/dev/ttyUSB0"
##################################

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }
die()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Vereiste command ontbreekt: $1"; }

require_cmd pct

# ---- Automatische CTID ----
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

# ---- Container aanmaken ----
NETCFG="name=eth0,bridge=${BRIDGE}"
[[ -n "$VLAN_TAG" ]] && NETCFG="${NETCFG},tag=${VLAN_TAG}"
[[ -n "$STATIC_IP" ]] && NETCFG="${NETCFG},ip=${STATIC_IP},gw=${GATEWAY_IP}" || NETCFG="${NETCFG},ip=dhcp"

if pct status "$CTID" >/dev/null 2>&1; then
  info "Container $CTID bestaat al, overslaan..."
else
  info "Maak container $CTID aan..."
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

pct start "$CTID"
ct_exec() { pct exec "$CTID" -- bash -lc "$*"; }

# ---- Docker + socat ----
info "Installeer Docker + socat in CT..."
ct_exec "apt-get update -y && apt-get install -y ca-certificates curl gnupg socat"
ct_exec "install -m 0755 -d /etc/apt/keyrings"
ct_exec "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
ct_exec "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$(. /etc/os-release; echo \$VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list"
ct_exec "apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin"
ok "Docker en socat geïnstalleerd."

# ---- Virtuele poort via socat ----
info "Start virtuele seriële poort via socat..."
ct_exec "nohup socat pty,link=${VIRTUAL_SERIAL},raw,echo=0 ${SOCAT_TARGET} &>/tmp/socat.log & disown"
ct_exec "sleep 2"

# ---- P1 Monitor data directories ----
ct_exec "mkdir -p ${P1MON_DIR}/alldata/{data,mnt/usb,mnt/ramdisk}"

# ---- docker-compose.yml ----
info "Maak docker-compose.yml..."
ct_exec "cat > ${P1MON_DIR}/docker-compose.yml <<'YAML'
services:
  p1monitor:
    hostname: ${HOSTNAME}
    image: mclaassen/p1mon
    ports:
      - \"${P1MON_HTTP_PORT}:80\"
    volumes:
      - ./alldata/data:/p1mon/data
      - ./alldata/mnt/usb:/p1mon/mnt/usb
      - ./alldata/mnt/ramdisk:/p1mon/mnt/ramdisk
    devices:
      - \"${VIRTUAL_SERIAL}:${VIRTUAL_SERIAL}\"
    tmpfs:
      - /run
      - /tmp
    restart: unless-stopped
YAML"

# ---- Start P1 Monitor ----
info "Start P1 Monitor container..."
ct_exec "cd ${P1MON_DIR} && docker compose up -d"

# ---- Toon resultaat ----
IP=$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" | tr -d '\r')
echo
echo "================================================="
echo "✅  P1 Monitor draait!"
echo "URL: http://${IP}:${P1MON_HTTP_PORT}"
echo "Virtuele poort: ${VIRTUAL_SERIAL} (socat → ${SOCAT_TARGET})"
echo "Container ID: ${CTID}"
echo "CT beheren: pct enter ${CTID}"
echo "================================================="
