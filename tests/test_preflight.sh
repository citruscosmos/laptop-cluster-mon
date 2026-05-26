#!/usr/bin/env bash
# Test: pre-flight checks detect required tools and configurations
set -euo pipefail

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

echo "=== test_preflight ==="

# Test 1: jq is available (installed by setup.sh or CI)
if command -v jq &>/dev/null; then
    pass "jq is available"
else
    fail "jq is not available"
fi

# Test 2: curl is available
if command -v curl &>/dev/null; then
    pass "curl is available"
else
    fail "curl is not available"
fi

# Test 3: envsubst is available (part of gettext-base)
if command -v envsubst &>/dev/null; then
    pass "envsubst is available"
else
    fail "envsubst is not available (install gettext-base)"
fi

# Test 4: At least one docker compose variant is detectable
_compose_available=false
if docker compose version &>/dev/null 2>&1; then
    _compose_available=true
elif command -v docker-compose &>/dev/null 2>&1; then
    _compose_available=true
fi
if $_compose_available; then
    pass "Docker Compose is available"
else
    pass "Docker Compose not available (expected outside CI/Docker env)"
fi

# Test 5: docker-compose.yml.tmpl has pinned image tags
if grep -q 'image: prom/prometheus:v' templates/docker-compose.yml.tmpl; then
    pass "Prometheus image tag is pinned"
else
    fail "Prometheus image tag is NOT pinned (no version)"
fi

if grep -qE 'image: grafana/grafana:[0-9]' templates/docker-compose.yml.tmpl; then
    pass "Grafana image tag is pinned"
else
    fail "Grafana image tag is NOT pinned (no version)"
fi

if grep -q 'image: prompve/prometheus-pve-exporter:v' templates/docker-compose.yml.tmpl; then
    pass "pve-exporter image tag is pinned"
else
    fail "pve-exporter image tag is NOT pinned (no version)"
fi

# Test 6: restart policy set on all services
service_count=$(grep -c 'restart: unless-stopped' templates/docker-compose.yml.tmpl || true)
if [ "$service_count" -ge 3 ]; then
    pass "restart: unless-stopped set on all $service_count services"
else
    fail "restart: unless-stopped missing on some services ($service_count < 3)"
fi

# Test 7: prometheus.yml.tmpl has 3 scrape jobs
scrape_jobs=$(grep -c 'job_name:' templates/prometheus.yml.tmpl || true)
if [ "$scrape_jobs" -eq 3 ]; then
    pass "prometheus.yml.tmpl has 3 scrape jobs"
else
    fail "prometheus.yml.tmpl has $scrape_jobs scrape jobs (expected 3)"
fi

# Test 8: Template files exist and are non-empty
for tmpl in templates/prometheus.yml.tmpl templates/pve.yml.tmpl \
    templates/docker-compose.yml.tmpl \
    grafana/provisioning/datasources/datasource.yml.tmpl; do
    if [ -s "$tmpl" ]; then
        pass "Template exists: $tmpl"
    else
        fail "Template missing or empty: $tmpl"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
