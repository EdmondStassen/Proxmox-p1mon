#!/usr/bin/env bash
# ===========================================================
# P1 Monitor Helper Script voor Proxmox
# Zie Marcel Claassen: https://marcel.duketown.com/p1-monitor-docker-versie/
# ===========================================================

set -euo pipefail

############# Config (pas gerust aan) #############
CTID="${CTID:-991}"                   # Container ID
HOSTNAME="${HOSTNAME:-p1monitor}"         # Hostname
MEMORY_MB="${MEMORY_MB:-1024}"        # RAM in MB
CORES="${CORES:-2}"                   # vCPU's
DISK_GB="${DISK_GB:-8}"               # Rootfs grootte in GB
BRIDGE="${BRIDGE:-vmbr0}"             # Netwerk bridge
VLAN_TAG="${VLAN_TAG:-}"              # bv. 20  (leeg = geen VLAN)
STATIC_IP="${STATIC_IP:-}"            # bv. 192.168.1.123/24  (leeg = DHCP)
GATEWAY_IP="${GATEWAY_IP:-}"          # bv. 192.168.1.1       (alleen bij statisch IP)
NAMESERVER="${NAMESERVER:-1.1.1.1}"   # DNS in CT
STORAGE="${STORAGE:-local-lvm}"       # Opslag voor rootfs
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"  # Voor templates
P1MON_HTTP_PORT="${P1MON_HTTP_PORT:-81}"       # Externe poort
P1MON_DIR="${P1MON_DIR:-/opt/p1mon}"           # Map in CT
SOCAT_CONF="${SOCAT_CONF:-}"          # Optioneel: bv. TCP4:192.168.1.50:23
###################################################

# --- Helpers ---
die() { echo "ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Vereiste command ontbreekt: $1"; }
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $*";  }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }

require_cmd pct
require_cmd pveversion

# --- Template bepalen/halen ---
pick_debian12_template() {
  pveam update >/dev/null 2>&1 || true
  local tmpl
  tmpl="$(pveam available --section system | awk '/debian-12.*standard.*\.tar\.zst/ {print $2}' | tail -n1 || true)"
  [[ -n "$tmpl" ]] || die "Geen Debian 12 template gevonden via pveam."
  echo "$tmpl"
}

ensure_template_present() {
  local tmpl="$1"
  if ! pveam list "$TEMPLATE_STORAGE" | awk '{print $2}' | grep -qx "$tmpl"; then
    info "Download template $tmpl..."
    pveam download "$TEMPLATE_STORAGE" "$tmpl"
  else
    ok "Template aanwezig: $tmpl"
  fi
}

create_ct() {
  local tmpl="$1"
  local net
  if [[ -n "$STATIC_IP" ]]; then
    [[ -n "$GATEWAY_IP" ]] || die "STATIC_IP is gezet, maar GATEWAY_IP niet."
    if [[ -n "$VLAN_TAG" ]]; then
      net="name=eth0,bridge=${BRIDGE},tag=${VLAN_TAG},ip=${STATIC_IP},gw=${GATEWAY_IP}"
    else
      net="name=eth0,bridge=${BRIDGE},ip=${STATIC_IP},gw=${GATEWAY_IP}"
    fi
  else
    if [[ -n "$VLAN_TAG" ]]; then
      net="name=eth0,bridge=${BRIDGE},tag=${VLAN_TAG},ip=dhcp"
    else
      net="name=eth0,bridge=${BRIDGE},ip=dhcp"
    fi
  fi

  if pct status "$CTID" >/dev/null 2>&1; then
    warn "CT $CTID bestaat al, overslaan..."
  else
    info "Maak CT $CTID aan..."
    pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${tmpl}" \
      -hostname "$HOSTNAME" \
      -cores "$CORES" \
      -memory "$MEMORY_MB" \
      -rootfs "${STORAGE}:${DISK_GB}" \
      -features nesting=1 \
      -unprivileged 0 \
      -net0 "$net" \
      -nameserver "$NAMESERVER" \
      -onboot 1
  fi
}

start_ct() {
  if [[ "$(pct status "$CTID" | awk '{print $2}')" != "running" ]]; then
    info "Start CT $CTID..."
    pct start "$CTID"
    sleep 3
  fi
  ok "CT $CTID draait."
}

ct_exec() { pct exec "$CTID" -- bash -lc "$*"; }

install_docker_in_ct() {
  info "Installeer Docker in CT..."
  ct_exec "apt-get update -y"
  ct_exec "apt-get install -y ca-certificates curl gnupg"
  ct_exec "install -m 0755 -d /etc/apt/keyrings"
  ct_exec "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
  ct_exec "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$(. /etc/os-release; echo \$VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list"
  ct_exec "apt-get update -y"
  ct_exec "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
  ok "Docker geïnstalleerd."
}

prepare_p1mon_dirs() {
  ct_exec "mkdir -p ${P1MON_DIR}/alldata/{data,mnt/usb,mnt/ramdisk}"
}

write_compose_file() {
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
    tmpfs:
      - /run
      - /tmp
    restart: unless-stopped
YAML"

  # Optioneel: voeg SOCAT_CONF toe
  if [[ -n "$SOCAT_CONF" ]]; then
    info "Voeg SOCAT_CONF toe (${SOCAT_CONF})..."
    ct_exec "sed -i '\$a\\    environment:\\n      - SOCAT_CONF=${SOCAT_CONF}' ${P1MON_DIR}/docker-compose.yml"
  fi
}

bring_up_stack() {
  info "Start P1 Monitor container..."
  ct_exec "cd ${P1MON_DIR} && docker compose up -d"
}

print_access_info() {
  local ip
  ip="$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" | tr -d '\r')"
  echo
  echo "============================================"
  echo "✅  P1 Monitor draait!"
  echo "URL: http://${ip}:${P1MON_HTTP_PORT}"
  echo "CT beheren: pct enter ${CTID}"
  echo "Docker beheer: cd ${P1MON_DIR} && docker compose ps"
  echo "============================================"
}

main() {
  info "Start P1 Monitor setup..."
  tmpl="$(pick_debian12_template)"
  ensure_template_present "$tmpl"
  create_ct "$tmpl"
  start_ct
  install_docker_in_ct
  prepare_p1mon_dirs
  write_compose_file
  bring_up_stack
  print_access_info
}

main "$@"
