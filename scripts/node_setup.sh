#!/usr/bin/env bash
set -euo pipefail

# ── Style ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*"; }

# ── Root check ─────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root."
    echo "Usage: sudo ./node_setup.sh"
    exit 1
fi

NODE_EXPORTER_VERSION="1.9.1"
ARCH="amd64"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 1. Install node_exporter ───────────────────────────────────────────────
install_node_exporter() {
    if [ -x /usr/local/bin/node_exporter ]; then
        local ver
        ver=$(/usr/local/bin/node_exporter --version 2>&1 | head -1 || true)
        info "node_exporter already installed: ${ver}"
    else
        info "Installing node_exporter v${NODE_EXPORTER_VERSION}..."
        curl -sL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz" \
            | tar xz -C /usr/local/bin --strip-components=1
        info "node_exporter installed."
    fi

    if ! id -u node_exporter &>/dev/null; then
        useradd -rs /bin/false node_exporter
        info "Created node_exporter user."
    fi
}

# ── 2. Setup textfile collector dir ────────────────────────────────────────
setup_textfile_dir() {
    mkdir -p "$TEXTFILE_DIR"
    chown -R node_exporter:node_exporter /var/lib/node_exporter
    info "Textfile collector directory ready: ${TEXTFILE_DIR}"
}

# ── 3. Install systemd unit ────────────────────────────────────────────────
install_systemd_unit() {
    local unit_file="/etc/systemd/system/node_exporter.service"
    local exec_line="ExecStart=/usr/local/bin/node_exporter --collector.textfile.directory=${TEXTFILE_DIR}"

    if [ -f "$unit_file" ] && grep -qF "$exec_line" "$unit_file"; then
        info "systemd unit already up-to-date."
    else
        info "Writing systemd unit..."
        cat > "$unit_file" <<'EOS'
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter --collector.textfile.directory=/var/lib/node_exporter/textfile_collector

[Install]
WantedBy=multi-user.target
EOS
        systemctl daemon-reload
        info "systemd unit installed."
    fi
}

# ── 4. Install deps ────────────────────────────────────────────────────────
install_deps() {
    local missing=()
    command -v smartctl &>/dev/null || missing+=(smartmontools)
    command -v nvme &>/dev/null    || missing+=(nvme-cli)
    command -v jq &>/dev/null      || missing+=(jq)
    command -v curl &>/dev/null    || missing+=(curl)

    if [ "${#missing[@]}" -gt 0 ]; then
        info "Installing: ${missing[*]}"
        apt-get update -qq
        apt-get install -y -qq "${missing[@]}"
    else
        info "All dependencies already installed."
    fi
}

# ── 5. Deploy smartmon.sh ──────────────────────────────────────────────────
deploy_smartmon() {
    local dest="/usr/local/bin/smartmon.sh"

    # If smartmon.sh exists alongside this script, copy it
    if [ -f "${SCRIPT_DIR}/smartmon.sh" ]; then
        cp "${SCRIPT_DIR}/smartmon.sh" "$dest"
        chmod +x "$dest"
        info "Deployed smartmon.sh from ${SCRIPT_DIR}."
    elif [ -f "$dest" ]; then
        info "smartmon.sh already present at ${dest}."
    else
        error "smartmon.sh not found in ${SCRIPT_DIR}."
        error "Place smartmon.sh next to node_setup.sh and re-run."
        exit 1
    fi
}

# ── 6. Install cron job ────────────────────────────────────────────────────
install_cron() {
    local cron_file="/etc/cron.d/smartmon"

    if [ -f "$cron_file" ]; then
        info "cron job already installed."
    else
        echo "0 * * * * root /usr/local/bin/smartmon.sh" > "$cron_file"
        info "cron job installed (every 60 min)."
    fi
}

# ── 7. Start node_exporter ─────────────────────────────────────────────────
start_service() {
    systemctl enable --now node_exporter
    sleep 2
    if systemctl is-active --quiet node_exporter; then
        info "node_exporter is running."
    else
        error "node_exporter failed to start. Check: systemctl status node_exporter"
        exit 1
    fi
}

# ── 8. Initial SMART collection ─────────────────────────────────────────────
run_initial_smartmon() {
    info "Running initial SMART collection..."
    if /usr/local/bin/smartmon.sh; then
        local f="${TEXTFILE_DIR}/smartmon.prom"
        if [ -f "$f" ]; then
            info "SMART metrics written:"
            grep -v '^#' "$f" | head -20 || true
        fi
    else
        warn "SMART collection ran but may have partial results."
        warn "Ensure smartmontools and nvme-cli are installed."
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo ""
    info "Proxmox Node Exporter + SMART Setup"
    info "==================================="
    echo ""

    install_deps
    install_node_exporter
    setup_textfile_dir
    install_systemd_unit
    deploy_smartmon
    install_cron
    start_service
    run_initial_smartmon

    echo ""
    info "Node setup complete."
    echo ""
    echo "  Metrics exposed at:"
    echo "    http://$(hostname -I | awk '{print $1}'):9100/metrics"
    echo ""
    echo "  SMART metrics update: every 60 min (cron)"
    echo "  To test: curl -s localhost:9100/metrics | grep node_smart"
}

main
