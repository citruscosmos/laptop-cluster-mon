#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Style ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*"; }

# ── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage: sudo PVE_NODE_IP=<ip> PVE_API_TOKEN=<token> ./setup.sh

Environment variables:
  PVE_NODE_IP               IP of one Proxmox node (required)
  PVE_API_TOKEN             Proxmox API token (required)
  PROMETHEUS_SCRAPE_INTERVAL Prometheus scrape interval (default: 15s)
  GRAFANA_ADMIN_USER        Grafana admin username (default: admin)
  GRAFANA_ADMIN_PASSWORD    Grafana admin password (default: admin)

Example:
  sudo PVE_NODE_IP=192.168.1.10 PVE_API_TOKEN="monitoring@pve!monitoring=..." ./setup.sh
EOF
    exit 1
}

# ── Step 1: root check + OS check ───────────────────────────────────────────
check_root_and_os() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root (Docker installation required)."
        echo "Usage: sudo $0"
        exit 1
    fi

    if [ ! -f /etc/os-release ]; then
        error "Cannot detect OS. Only Debian and Ubuntu are supported."
        exit 1
    fi

    . /etc/os-release
    case "$ID" in
        debian|ubuntu) ;;
        *)
            error "Unsupported OS: $ID. Only Debian and Ubuntu are supported."
            exit 1
            ;;
    esac

    info "OS: $PRETTY_NAME"
}

# ── Step 2: Pre-flight checks ───────────────────────────────────────────────
run_preflight() {
    info "Running pre-flight checks..."

    # jq
    if ! command -v jq &>/dev/null; then
        info "Installing jq..."
        apt-get update -qq && apt-get install -y -qq jq
    fi

    # docker compose (plugin or standalone)
    if ! docker compose version &>/dev/null && ! command -v docker-compose &>/dev/null; then
        error "Docker Compose not found. Docker will be installed in the next step."
    fi

    # curl
    if ! command -v curl &>/dev/null; then
        info "Installing curl..."
        apt-get install -y -qq curl
    fi
}

# ── Step 3: Docker install ──────────────────────────────────────────────────
install_docker() {
    if command -v docker &>/dev/null; then
        info "Docker already installed: $(docker --version)"
    else
        info "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        info "Docker installed successfully."
    fi

    # Add user to docker group if sudo was used with a non-root SUDO_USER
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        if ! groups "$SUDO_USER" | grep -q docker; then
            usermod -aG docker "$SUDO_USER"
            warn "User '$SUDO_USER' added to docker group."
            warn "You may need to re-login or run 'newgrp docker' for this to take effect."
            warn "Until then, use 'sudo docker' or 'sudo docker compose'."
        fi
    fi
}

# ── Step 4: Env var validation ──────────────────────────────────────────────
validate_env_vars() {
    info "Validating required environment variables..."

    if [ -z "${PVE_NODE_IP:-}" ]; then
        error "PVE_NODE_IP is not set."
        echo ""
        echo "  PVE_NODE_IP: IP address of one Proxmox node in your cluster."
        echo "  PVE_API_TOKEN: API token (format: user@pve!token_name=token_value)"
        echo ""
        usage
    fi

    if [ -z "${PVE_API_TOKEN:-}" ]; then
        error "PVE_API_TOKEN is not set."
        echo ""
        echo "Create one on your Proxmox node:"
        echo "  pveum user add monitoring@pve --comment 'monitoring VM'"
        echo "  pveum acl modify / --user monitoring@pve --role PVEAuditor"
        echo "  pveum user token add monitoring@pve monitoring --privsep 0"
        echo ""
        usage
    fi

    info "PVE_NODE_IP=$PVE_NODE_IP"
    info "PVE_API_TOKEN=***"
}

# ── Step 4b: API connectivity check ─────────────────────────────────────────
check_api_connectivity() {
    info "Checking connectivity to Proxmox API at ${PVE_NODE_IP}:8006..."

    if ! curl -sk --connect-timeout 5 "https://${PVE_NODE_IP}:8006/api2/json/access/permissions" \
        -H "Authorization: PVEAPIToken=${PVE_API_TOKEN}" \
        -o /dev/null -w "%{http_code}" | grep -q '200'; then
        error "Cannot authenticate to Proxmox API at https://${PVE_NODE_IP}:8006"
        error "Check:"
        error "  1. PVE_NODE_IP is correct and reachable from this VM"
        error "  2. API token is valid (create via 'pveum user token add')"
        error "  3. Monitoring VM can reach Proxmox node on port 8006"
        exit 1
    fi

    info "Proxmox API reachable and authenticated."
}

# ── Step 5: Cluster auto-discovery ──────────────────────────────────────────
discover_cluster_nodes() {
    info "Discovering cluster nodes via Proxmox API..."

    local cluster_json
    cluster_json=$(curl -sk --connect-timeout 5 \
        -H "Authorization: PVEAPIToken=${PVE_API_TOKEN}" \
        "https://${PVE_NODE_IP}:8006/api2/json/cluster/status" 2>/dev/null || true)

    if [ -z "$cluster_json" ]; then
        warn "Failed to query cluster status from API."
        warn "Falling back to single node: ${PVE_NODE_IP}"
        NODE_IPS=("$PVE_NODE_IP")
        return
    fi

    # Parse IPs from cluster status
    local ips
    ips=$(echo "$cluster_json" | jq -r '.data[]?.ip // empty' 2>/dev/null || true)

    if [ -z "$ips" ]; then
        warn "Could not parse node IPs from cluster status."
        warn "Falling back to single node: ${PVE_NODE_IP}"
        NODE_IPS=("$PVE_NODE_IP")
        return
    fi

    # Read into array
    readarray -t NODE_IPS <<< "$ips"

    if [ "${#NODE_IPS[@]}" -eq 1 ]; then
        warn "Only 1 node detected. Verify cluster quorum if you expected more."
    fi

    info "Discovered ${#NODE_IPS[@]} node(s): ${NODE_IPS[*]}"
}

# ── Step 6: Generate configs from templates ─────────────────────────────────
generate_configs() {
    info "Generating configuration files..."

    # Extract token secret from full PVE_API_TOKEN (format: user@realm!token_name=secret)
    PVE_TOKEN_VALUE="${PVE_API_TOKEN##*=}"
    if [ -z "$PVE_TOKEN_VALUE" ] || [ "$PVE_TOKEN_VALUE" = "$PVE_API_TOKEN" ]; then
        warn "Could not parse token secret from PVE_API_TOKEN."
        warn "Expected format: user@realm!token_name=secret"
        warn "Falling back to full token string, but pve-exporter may fail to authenticate."
        PVE_TOKEN_VALUE="$PVE_API_TOKEN"
    fi

    # Build YAML-formatted IP lists for Prometheus targets
    NODE_IPS_YAML=""
    NODE_IPS_9100_YAML=""
    for ip in "${NODE_IPS[@]}"; do
        NODE_IPS_YAML="${NODE_IPS_YAML}          - '${ip}'"$'\n'
        NODE_IPS_9100_YAML="${NODE_IPS_9100_YAML}          - '${ip}:9100'"$'\n'
    done
    export NODE_IPS_YAML
    export NODE_IPS_9100_YAML
    export PVE_TOKEN_VALUE
    export PVE_FIRST_NODE_IP="${NODE_IPS[0]}"
    export SCRAPE_INTERVAL="${PROMETHEUS_SCRAPE_INTERVAL:-15s}"
    export DATASOURCE_UID="PBFA97CFB590B2093"

    # Helper: replace __VAR__ with ${VAR} then run envsubst
    # Pattern requires UPPERCASE first char so Prometheus labels (__address__) are not matched.
    _subst() {
        local input="$1"
        local output="$2"
        sed 's/__\([A-Z][A-Z_0-9]*\)__/${\1}/g' "$input" | envsubst > "$output"
    }

    _subst "templates/prometheus.yml.tmpl" "prometheus.yml"
    _subst "templates/pve.yml.tmpl" "pve.yml"
    _subst "templates/docker-compose.yml.tmpl" "docker-compose.yml"
    _subst "grafana/provisioning/datasources/datasource.yml.tmpl" \
            "grafana/provisioning/datasources/datasource.yml"

    info "Configuration files generated."
}

# ── Step 7: Grafana dashboards ──────────────────────────────────────────────
setup_grafana_dashboards() {
    info "Setting up Grafana dashboards..."
    # Dashboard JSONs are already in grafana/provisioning/dashboards/ from the repo.
    # The docker-compose.yml mounts ./grafana/provisioning to /etc/grafana/provisioning.
    # No additional copy step needed.
    local count
    count=$(find grafana/provisioning/dashboards -name '*.json' -type f 2>/dev/null | wc -l)
    info "Found ${count} dashboard JSON(s) ready for provisioning."
}

# ── Step 8: Docker Compose up ───────────────────────────────────────────────
start_services() {
    info "Starting services with Docker Compose..."

    local compose_cmd
    if docker compose version &>/dev/null; then
        compose_cmd="docker compose"
    else
        compose_cmd="docker-compose"
    fi

    $compose_cmd down --remove-orphans 2>/dev/null || true
    $compose_cmd up -d

    info "Services started."
    $compose_cmd ps
}

# ── Step 9: Post-setup validation ───────────────────────────────────────────
validate_metrics() {
    info "Waiting 5s for pve-exporter to start..."
    sleep 5

    info "Validating pve-exporter metrics..."
    local target_ip="${NODE_IPS[0]}"

    local metrics
    metrics=$(curl -s "http://localhost:9221/pve?target=${target_ip}&module=default" 2>/dev/null || true)

    if [ -z "$metrics" ]; then
        warn "pve-exporter returned no response. It may still be starting."
        warn "Check: docker compose logs pve-exporter"
        return
    fi

    if ! echo "$metrics" | grep -q 'pve_version_info'; then
        warn "pve-exporter did not return Proxmox metrics."
        warn "Check API token permissions and connectivity."
        warn "Run: curl 'http://localhost:9221/pve?target=${target_ip}&module=default'"
        return
    fi

    # Verify at least one metric has a non-zero value
    if echo "$metrics" | grep -v '^#' | grep -qE 'pve_[a-z_]+ [1-9]'; then
        info "pve-exporter is serving Proxmox metrics. Validation passed."
    else
        warn "pve-exporter returned metrics but all values appear to be zero."
        warn "This may be normal for a new/idle cluster."
    fi
}

# ── Step 10: Completion message ─────────────────────────────────────────────
print_completion() {
    echo ""
    echo "=============================================="
    info "Setup complete!"
    echo "=============================================="
    echo ""
    echo "  Grafana:    http://$(hostname -I | awk '{print $1}'):3000"
    echo "  Prometheus: http://$(hostname -I | awk '{print $1}'):9090"
    echo ""
    echo "  Default Grafana login:"
    echo "    User: ${GRAFANA_ADMIN_USER:-admin}"
    echo "    Pass: ${GRAFANA_ADMIN_PASSWORD:-admin}"
    echo ""
    echo "  Pre-loaded dashboards:"
    echo "    - Proxmox VE (10347): cluster overview, VM status, storage"
    echo "    - Node Exporter Full (1860): CPU, RAM, disk per node"
    echo ""
    echo "── Next: Install Node Exporter on each Proxmox node ──"
    echo ""
    for ip in "${NODE_IPS[@]}"; do
        echo "  On ${ip}:"
        echo "    curl -sL https://github.com/prometheus/node_exporter/releases/download/v1.9.1/node_exporter-1.9.1.linux-amd64.tar.gz | sudo tar xz -C /usr/local/bin --strip-components=1"
        echo "    sudo useradd -rs /bin/false node_exporter 2>/dev/null || true"
        echo "    sudo tee /etc/systemd/system/node_exporter.service <<'EOS'"
        echo "    [Unit]"
        echo "    Description=Node Exporter"
        echo "    After=network.target"
        echo "    [Service]"
        echo "    User=node_exporter"
        echo "    ExecStart=/usr/local/bin/node_exporter"
        echo "    [Install]"
        echo "    WantedBy=multi-user.target"
        echo "    EOS"
        echo "    sudo systemctl daemon-reload && sudo systemctl enable --now node_exporter"
        echo ""
    done
    echo "── Notes ──"
    echo ""
    echo "  Disk usage: ~500MB/day for 3 nodes + 10 VMs at 15s scrape interval."
    echo "  Data retention: 15 days (Prometheus default)."
    echo "  VM sizing: 4GB RAM, 2 vCPU, 20GB disk minimum recommended."
    echo ""
    echo "  To stop:  docker compose down"
    echo "  To update: git pull && docker compose down && sudo ./setup.sh"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo ""
    info "Proxmox Cluster Monitoring Setup"
    info "================================"
    echo ""

    check_root_and_os
    run_preflight

    # Show usage if --help or no required vars
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        usage
    fi

    validate_env_vars
    check_api_connectivity
    install_docker
    discover_cluster_nodes
    generate_configs
    setup_grafana_dashboards
    start_services
    validate_metrics
    print_completion
}

main "$@"
