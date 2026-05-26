#!/usr/bin/env bash
# Test: cluster status JSON parsing extracts IPs correctly
set -euo pipefail

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

# Mock cluster status with 3 nodes
MOCK_JSON_3_NODES='{
  "data": [
    {"ip": "192.168.1.10", "name": "pve1", "type": "node", "online": 1},
    {"ip": "192.168.1.11", "name": "pve2", "type": "node", "online": 1},
    {"ip": "192.168.1.12", "name": "pve3", "type": "node", "online": 1}
  ]
}'

# Mock cluster status with 1 node
MOCK_JSON_1_NODE='{
  "data": [
    {"ip": "10.0.0.5", "name": "solo", "type": "node", "online": 1}
  ]
}'

# Mock empty/invalid response
MOCK_JSON_EMPTY='{"data": []}'
MOCK_JSON_NO_IP='{"data": [{"name": "bad-node", "type": "node"}]}'
MOCK_JSON_MALFORMED='not json'

echo "=== test_parse_cluster_status ==="

# Test 1: 3 nodes → 3 IPs extracted
ips=$(echo "$MOCK_JSON_3_NODES" | jq -r '.data[]?.ip // empty' 2>/dev/null || true)
count=$(echo "$ips" | wc -l)
if [ "$count" -eq 3 ]; then
    pass "3-node cluster: extracted $count IPs"
else
    fail "3-node cluster: expected 3 IPs, got $count"
fi

# Test 2: 1 node → 1 IP extracted
ips=$(echo "$MOCK_JSON_1_NODE" | jq -r '.data[]?.ip // empty' 2>/dev/null || true)
count=$(echo "$ips" | wc -l)
if [ "$count" -eq 1 ]; then
    pass "1-node cluster: extracted $count IP"
else
    fail "1-node cluster: expected 1 IP, got $count"
fi

# Test 3: Empty data → no IPs (fallback path)
ips=$(echo "$MOCK_JSON_EMPTY" | jq -r '.data[]?.ip // empty' 2>/dev/null || true)
if [ -z "$ips" ]; then
    pass "Empty cluster: no IPs extracted (triggers fallback)"
else
    fail "Empty cluster: expected no IPs, got: $ips"
fi

# Test 4: Data without IP field → no IPs (fallback path)
ips=$(echo "$MOCK_JSON_NO_IP" | jq -r '.data[]?.ip // empty' 2>/dev/null || true)
if [ -z "$ips" ]; then
    pass "No IP field: no IPs extracted (triggers fallback)"
else
    fail "No IP field: expected no IPs, got: $ips"
fi

# Test 5: Malformed JSON → jq fails gracefully
ips=$(echo "$MOCK_JSON_MALFORMED" | jq -r '.data[]?.ip // empty' 2>/dev/null || true)
if [ -z "$ips" ]; then
    pass "Malformed JSON: jq fails gracefully (empty result)"
else
    fail "Malformed JSON: expected empty, got: $ips"
fi

# Test 6: IPs contain valid IPv4 addresses
ips=$(echo "$MOCK_JSON_3_NODES" | jq -r '.data[]?.ip // empty' 2>/dev/null || true)
all_valid=true
for ip in $ips; do
    if ! echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        all_valid=false
    fi
done
if $all_valid; then
    pass "All IPs are valid IPv4 addresses"
else
    fail "Some IPs are not valid IPv4 addresses"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
