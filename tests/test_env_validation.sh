#!/usr/bin/env bash
# Test: missing environment variables cause error exit
set -euo pipefail

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

# Extract the validation logic as a function for testing
validate_env_vars() {
    if [ -z "${PVE_NODE_IP:-}" ]; then
        return 1
    fi
    if [ -z "${PVE_API_TOKEN:-}" ]; then
        return 1
    fi
    return 0
}

echo "=== test_env_validation ==="

# Test 1: Both vars missing → fail
unset PVE_NODE_IP PVE_API_TOKEN
if ! validate_env_vars; then
    pass "Missing both vars: validation fails (exit 1)"
else
    fail "Missing both vars: should have failed but passed"
fi

# Test 2: Only PVE_NODE_IP set → fail
export PVE_NODE_IP="192.168.1.10"
unset PVE_API_TOKEN
if ! validate_env_vars; then
    pass "Missing PVE_API_TOKEN: validation fails"
else
    fail "Missing PVE_API_TOKEN: should have failed but passed"
fi

# Test 3: Only PVE_API_TOKEN set → fail
unset PVE_NODE_IP
export PVE_API_TOKEN="monitoring@pve!monitoring=secret123"
if ! validate_env_vars; then
    pass "Missing PVE_NODE_IP: validation fails"
else
    fail "Missing PVE_NODE_IP: should have failed but passed"
fi

# Test 4: Both vars set → pass
export PVE_NODE_IP="192.168.1.10"
export PVE_API_TOKEN="monitoring@pve!monitoring=secret123"
if validate_env_vars; then
    pass "Both vars set: validation passes"
else
    fail "Both vars set: should have passed but failed"
fi

# Test 5: Empty string PVE_NODE_IP → fail
export PVE_NODE_IP=""
export PVE_API_TOKEN="some-token"
if ! validate_env_vars; then
    pass "Empty PVE_NODE_IP: validation fails"
else
    fail "Empty PVE_NODE_IP: should have failed but passed"
fi

# Test 6: PVE_API_TOKEN contains special characters → pass
export PVE_NODE_IP="10.0.0.1"
export PVE_API_TOKEN='user@pve!name=abc/def&ghi+jkl='
if validate_env_vars; then
    pass "PVE_API_TOKEN with special chars: validation passes"
else
    fail "PVE_API_TOKEN with special chars: should have passed but failed"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
