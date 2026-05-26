#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="${1:-/var/lib/node_exporter/textfile_collector}"
OUTPUT_FILE="${OUTPUT_DIR}/smartmon.prom"
TMP_FILE="${OUTPUT_FILE}.tmp"

mkdir -p "$OUTPUT_DIR"

# ── Helpers ────────────────────────────────────────────────────────────────

# Write a metric line in Prometheus exposition format
write_metric() {
    local name="$1"
    local labels="$2"
    local value="$3"
    echo "${name}{${labels}} ${value}"
}

# ── Detect available drives ─────────────────────────────────────────────────

collect_nvme() {
    local nvme_devs
    nvme_devs=$(nvme list -o json 2>/dev/null | jq -r '.Devices[]?.DevicePath // empty' 2>/dev/null || true)

    if [ -z "$nvme_devs" ]; then
        # Fallback: glob
        for d in /dev/nvme*n1; do
            [ -e "$d" ] && nvme_devs="${nvme_devs}${d}"$'\n'
        done
        nvme_devs="${nvme_devs%$'\n'}"
    fi

    if [ -z "$nvme_devs" ]; then
        return
    fi

    while IFS= read -r dev; do
        [ -z "$dev" ] && continue
        local short
        short=$(basename "$dev")

        # Model
        local model
        model=$(nvme id-ctrl "$dev" -o json 2>/dev/null | jq -r '.mn // "unknown"' 2>/dev/null || echo "unknown")
        model="${model%"${model##*[![:space:]]}"}"  # trim trailing spaces

        # Percentage Used (0-100+, >100 means over provisioned capacity consumed)
        local pct_used
        pct_used=$(smartctl -A "$dev" 2>/dev/null | awk '/Percentage Used:/{print $3}' || true)
        [ -z "$pct_used" ] && pct_used=$(nvme id-ctrl "$dev" -o json 2>/dev/null | jq -r '.pct_used // empty' 2>/dev/null || true)

        # Available Spare
        local avail_spare
        avail_spare=$(smartctl -A "$dev" 2>/dev/null | awk '/Available Spare:/{print $3}' || true)

        # Data Units Written (for rate-of-wear insight)
        local data_units
        data_units=$(smartctl -A "$dev" 2>/dev/null | awk '/Data Units Written:/{print $4}' || true)
        [ -z "$data_units" ] && data_units="0"

        # Media Errors
        local media_errors
        media_errors=$(smartctl -A "$dev" 2>/dev/null | awk '/Media and Data Integrity Errors:/{print $6}' || true)
        [ -z "$media_errors" ] && media_errors="0"

        if [ -n "$pct_used" ]; then
            write_metric "node_smart_percentage_used" "device=\"${short}\",model=\"${model}\"" "$pct_used"
        fi
        if [ -n "$avail_spare" ]; then
            write_metric "node_smart_available_spare" "device=\"${short}\",model=\"${model}\"" "$avail_spare"
        fi
        [ -n "$data_units" ] && write_metric "node_smart_data_units_written" "device=\"${short}\",model=\"${model}\"" "$data_units"
        [ -n "$media_errors" ] && write_metric "node_smart_media_errors" "device=\"${short}\",model=\"${model}\"" "$media_errors"

    done <<< "$nvme_devs"
}

collect_sata() {
    local sata_devs
    sata_devs=$(smartctl --scan -j 2>/dev/null | jq -r '.devices[]?.name // empty' 2>/dev/null || true)

    if [ -z "$sata_devs" ]; then
        return
    fi

    while IFS= read -r dev; do
        [ -z "$dev" ] && continue
        # Skip NVMe (already handled)
        [[ "$dev" == *nvme* ]] && continue

        local short
        short=$(basename "$dev")

        # Model
        local model
        model=$(smartctl -i "$dev" 2>/dev/null | awk -F: '/Device Model|Product/{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo "unknown")

        # SMART health status
        local health
        health=$(smartctl -H "$dev" 2>/dev/null | awk -F: '/SMART overall-health|SMART Health Status/{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
        local health_val=1
        [ "${health,,}" = "passed" ] || [ "${health,,}" = "ok" ] && health_val=1
        [ "${health,,}" != "passed" ] && [ "${health,,}" != "ok" ] && health_val=0

        # Wear Leveling Count - common SSD attribute (ID varies: 177, 202, 231, etc.)
        # Try multiple known attribute IDs
        local wear_level
        wear_level=$(smartctl -A "$dev" 2>/dev/null | awk '/^177 /{print $4}' || true)
        [ -z "$wear_level" ] && wear_level=$(smartctl -A "$dev" 2>/dev/null | awk '/^202 /{print $4}' || true)
        [ -z "$wear_level" ] && wear_level=$(smartctl -A "$dev" 2>/dev/null | awk '/^231 /{print $4}' || true)
        [ -z "$wear_level" ] && wear_level=$(smartctl -A "$dev" 2>/dev/null | awk '/^233 /{print $4}' || true)

        # Reallocated sectors (attribute 5)
        local realloc
        realloc=$(smartctl -A "$dev" 2>/dev/null | awk '/^  5 /{print $10}' || true)

        if [ -n "$wear_level" ]; then
            write_metric "node_smart_wear_level_count" "device=\"${short}\",model=\"${model}\"" "$wear_level"
        fi
        [ -n "$realloc" ] && write_metric "node_smart_reallocated_sectors" "device=\"${short}\",model=\"${model}\"" "$realloc"
        write_metric "node_smart_health_ok" "device=\"${short}\",model=\"${model}\"" "$health_val"

    done <<< "$sata_devs"
}

# ── Main ─────────────────────────────────────────────────────────────────────

{
    echo "# HELP node_smart_percentage_used NVMe Percentage Used (0-100, >100 = over-provisioned)"
    echo "# TYPE node_smart_percentage_used gauge"
    echo "# HELP node_smart_available_spare NVMe Available Spare percentage"
    echo "# TYPE node_smart_available_spare gauge"
    echo "# HELP node_smart_data_units_written NVMe Data Units Written (in 512B blocks * 1000)"
    echo "# TYPE node_smart_data_units_written counter"
    echo "# HELP node_smart_media_errors NVMe Media and Data Integrity Errors"
    echo "# TYPE node_smart_media_errors counter"
    echo "# HELP node_smart_wear_level_count SSD Wear Leveling Count (normalized; lower = more worn)"
    echo "# TYPE node_smart_wear_level_count gauge"
    echo "# HELP node_smart_reallocated_sectors Reallocated sector count"
    echo "# TYPE node_smart_reallocated_sectors counter"
    echo "# HELP node_smart_health_ok SMART overall health (1 = passed, 0 = failed)"
    echo "# TYPE node_smart_health_ok gauge"

    if command -v nvme &>/dev/null; then
        collect_nvme
    fi

    if command -v smartctl &>/dev/null; then
        collect_sata
    fi
} > "$TMP_FILE"

mv "$TMP_FILE" "$OUTPUT_FILE"
