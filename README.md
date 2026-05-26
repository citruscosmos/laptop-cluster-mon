# Proxmox Cluster Monitoring Setup

Single-command setup for a Prometheus + Grafana monitoring stack that watches a Proxmox VE cluster. Docker Compose manages all services on a dedicated monitoring VM.

## Prerequisites

- **Monitoring VM:** Debian or Ubuntu VM (not LXC) — 4 GB RAM, 2 vCPU, 20 GB disk minimum
- **Proxmox API token:** `PVEAuditor` role on one Proxmox node
- **Network:** Monitoring VM must reach Proxmox nodes on ports 8006 (API) and 9100 (Node Exporter)

### Create a Proxmox API token

On any Proxmox node, run:

```bash
pveum user add monitoring@pve --comment "monitoring VM"
pveum acl modify / --user monitoring@pve --role PVEAuditor
pveum user token add monitoring@pve monitoring --privsep 0
```

Save the token value from the output — you'll need it for setup.

## Quick Start

```bash
git clone https://github.com/citruscosmos/laptop-cluster-mon.git
cd laptop-cluster-mon
sudo PVE_NODE_IP=192.168.1.10 PVE_API_TOKEN="monitoring@pve!monitoring=<token>" ./setup.sh
```

The script handles Docker installation, cluster node discovery, config generation, and service startup.

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `PVE_NODE_IP` | Yes | — | IP of any Proxmox node in the cluster |
| `PVE_API_TOKEN` | Yes | — | API token (format: `user@pve!name=value`) |
| `PROMETHEUS_SCRAPE_INTERVAL` | No | `15s` | Prometheus scrape interval |
| `GRAFANA_ADMIN_USER` | No | `admin` | Grafana admin username |
| `GRAFANA_ADMIN_PASSWORD` | No | `admin` | Grafana admin password |

## Access

After setup completes:

| Service | URL |
|---------|-----|
| Grafana | `http://<monitoring-vm-ip>:3000` |
| Prometheus | `http://<monitoring-vm-ip>:9090` |

Default Grafana login: `admin` / `admin` (change via `GRAFANA_ADMIN_PASSWORD`).

### Pre-loaded Dashboards

- **Proxmox VE (10347):** Cluster overview, VM status, storage usage
- **Node Exporter Full (1860):** CPU, RAM, disk, network per node

## Node Exporter Installation

Run `node_setup.sh` on each Proxmox host. It installs node_exporter, smartmontools, nvme-cli, SMART disk monitoring via cron, and starts everything as a systemd service.

Since Proxmox nodes don't have git, download both files first:

```bash
# On each Proxmox node:
curl -sLO https://raw.githubusercontent.com/citruscosmos/laptop-cluster-mon/main/scripts/node_setup.sh
curl -sLO https://raw.githubusercontent.com/citruscosmos/laptop-cluster-mon/main/scripts/smartmon.sh
chmod +x node_setup.sh smartmon.sh
sudo ./node_setup.sh
```

After installation, ensure port 9100 is open so the monitoring VM can reach it.

## Architecture

```
[Proxmox Node 1]───node_exporter:9100────┐
[Proxmox Node 2]───node_exporter:9100────┤
[Proxmox Node 3]───node_exporter:9100────┤
                                          ├──Prometheus (host net)──Grafana
[Monitoring VM]                          │
  ┌──────────────────────────────────┐   │
  │ Docker Compose                   │   │
  │  - prometheus (network_mode:host)│◄──┘
  │  - grafana (bridge, :3000)       │
  │  - pve-exporter (bridge, :9221)  │────Proxmox API (:8006)
  └──────────────────────────────────┘
```

Prometheus uses host networking to reach Node Exporter on Proxmox hosts and pve-exporter via localhost. Grafana and pve-exporter use bridge networking with published ports.

## Disk Usage

Approximately 500 MB/day for 3 Proxmox nodes + 10 VMs/containers at a 15-second scrape interval. With the default 15-day retention, expect ~7.5 GB of Prometheus data. The recommended 20 GB disk provides a safe margin.

## Troubleshooting

**"Cannot authenticate to Proxmox API"**
- Verify `PVE_NODE_IP` is correct and reachable from the monitoring VM
- Verify the API token is valid: `pveum user list` on the Proxmox node
- Check port 8006 is open between the monitoring VM and Proxmox node

**"pve-exporter returned no Proxmox metrics"**
- Check pve-exporter logs: `docker compose logs pve-exporter`
- Verify API token permissions (`PVEAuditor` role)
- Test manually: `curl 'http://localhost:9221/pve?target=<node-ip>&module=default'`

**"Datasource not found" in Grafana dashboards**
- Check that Prometheus is running: `docker compose ps prometheus`
- Verify datasource provisioning: `docker compose logs grafana`
- The datasource UID is pinned to `PBFA97CFB590B2093` for dashboard compatibility

**Grafana dashboards are empty**
- Node Exporter dashboard (1860) requires Node Exporter installed on Proxmox hosts
- Prometheus targets page (`:9090/targets`) shows which scrape jobs are UP

**Re-running setup**
```bash
docker compose down
sudo PVE_NODE_IP=<ip> PVE_API_TOKEN=<token> ./setup.sh
```

Note: re-running overwrites config files. Prometheus and Grafana data in Docker volumes is preserved.

## Limitations

- Node IPs are discovered once at setup time. If Proxmox nodes change IPs, re-run setup.sh or update `prometheus.yml` manually.
- No HTTPS/TLS — intended for homelab use on trusted networks.
- Alerting not included (can be added via docker-compose override).
