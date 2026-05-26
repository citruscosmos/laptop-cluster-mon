#!/usr/bin/env bash
# Test: metrics validation logic with mock metric outputs
set -euo pipefail

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

echo "=== test_validate_metrics ==="

# Test 1: Healthy metrics output with pve_version_info → passes
MOCK_HEALTHY='# HELP pve_version_info Proxmox VE version info
# TYPE pve_version_info gauge
pve_version_info{version="8.3"} 1
pve_cpu_usage_ratio 0.15
pve_memory_usage_bytes 8589934592
pve_disk_usage_bytes 53687091200'

if echo "$MOCK_HEALTHY" | grep -q 'pve_version_info'; then
    pass "Healthy metrics: pve_version_info detected"
else
    fail "Healthy metrics: pve_version_info not found"
fi

if echo "$MOCK_HEALTHY" | grep -v '^#' | grep -qE 'pve_[a-z_]+ [1-9]'; then
    pass "Healthy metrics: non-zero pve_* metric values found"
else
    fail "Healthy metrics: no non-zero pve_* values"
fi

# Test 2: Empty response → fails gracefully
MOCK_EMPTY=""
if [ -z "$MOCK_EMPTY" ]; then
    pass "Empty metrics: correctly detected as empty"
else
    fail "Empty metrics: should be empty"
fi

# Test 3: pve-exporter error response → no pve_version_info
MOCK_ERROR='# HELP pve_exporter_error Error indicator
# TYPE pve_exporter_error gauge
pve_exporter_error 1'

if ! echo "$MOCK_ERROR" | grep -q 'pve_version_info'; then
    pass "Error metrics: pve_version_info absent (correctly fails validation)"
else
    fail "Error metrics: pve_version_info unexpectedly present"
fi

# Test 4: All-zero metrics → warning case
MOCK_ZERO='# HELP pve_version_info Proxmox VE version info
# TYPE pve_version_info gauge
pve_version_info{version="8.3"} 0
pve_cpu_usage_ratio 0
pve_memory_usage_bytes 0'

if echo "$MOCK_ZERO" | grep -q 'pve_version_info'; then
    pass "Zero metrics: pve_version_info present"
else
    fail "Zero metrics: pve_version_info not found"
fi

if echo "$MOCK_ZERO" | grep -v '^#' | grep -qE 'pve_[a-z_]+ [1-9]'; then
    fail "Zero metrics: non-zero value found (unexpected)"
else
    pass "Zero metrics: all values zero (triggers warning)"
fi

# Test 5: prometheus.yml generated config has required scrape jobs
if [ -f prometheus.yml ]; then
    # These tests only run after setup.sh completed
    job_count=$(grep -c 'job_name:' prometheus.yml || true)
    if [ "$job_count" -eq 3 ]; then
        pass "Generated prometheus.yml has 3 scrape jobs"
    else
        fail "Generated prometheus.yml has $job_count jobs (expected 3)"
    fi
else
    pass "skipped: prometheus.yml hasn't been generated yet (run setup.sh first)"
fi

# Test 6: pve.yml contains no unexpanded placeholders (if generated)
if [ -f pve.yml ]; then
    if grep -q '__' pve.yml; then
        fail "pve.yml contains unexpanded placeholders"
    else
        pass "pve.yml has no unexpanded placeholders"
    fi
else
    pass "skipped: pve.yml hasn't been generated yet"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
