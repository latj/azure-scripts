#!/usr/bin/env bash

# Script: vmss-metrics-disk.sh
# Purpose: Collect per-node VMSS disk throughput metrics, summarize results, and export to CSV/JSON.
# Requirements: Azure CLI logged in, jq installed. Works in Azure Cloud Shell.

set -uo pipefail

# ====== DEFAULTS ======
RESOURCE_GROUP=""
VMSS_NAME=""
TIME_RANGE="1h"
INTERVAL="PT1M"
OUT_DIR="."
PREFIX="vmss_disk"
START_TIME=""
END_TIME=""

bytes_to_mb() {
    local bytes="$1"
    jq -nr --argjson b "$bytes" '($b / 1048576)'
}

offset_to_seconds() {
    local offset="$1"
    if [[ "$offset" =~ ^([0-9]+)d$ ]]; then
        echo "$(( ${BASH_REMATCH[1]} * 86400 ))"
        return 0
    fi
    if [[ "$offset" =~ ^([0-9]+)h$ ]]; then
        echo "$(( ${BASH_REMATCH[1]} * 3600 ))"
        return 0
    fi
    if [[ "$offset" =~ ^([0-9]+)m$ ]]; then
        echo "$(( ${BASH_REMATCH[1]} * 60 ))"
        return 0
    fi

    echo "Error: Could not convert offset '$offset' to seconds." >&2
    return 1
}

normalize_datetime_to_utc() {
    local input="$1"
    local normalized

    if ! normalized=$(date -u -d "$input" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null); then
        echo "Error: Invalid datetime '$input'. Use a format accepted by GNU date (example: '2026-04-14 10:00' or 'yesterday 10:00')." >&2
        return 1
    fi

    echo "$normalized"
}

safe_exit() {
    local code="${1:-1}"
    # If sourced, return to prompt instead of closing the shell session.
    if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
        return "$code"
    fi
    exit "$code"
}

usage() {
    cat <<'EOF'
Usage:
  ./vmss-metrics-disk.sh -g <resource-group> -n <vmss-name> [options]

Required:
  -g, --resource-group     Resource group of the VMSS
  -n, --vmss-name          VMSS name

Optional:
  -t, --time-range         Offset duration (examples: 1h, 30m, 1d; also accepts PT1H/PT30M/PT1D)
  -s, --start-time         Absolute window start (examples: "2026-04-14 10:00", "yesterday 10:00")
  -e, --end-time           Absolute window end (examples: "2026-04-14 11:00", "yesterday 11:00")
  -i, --interval           ISO8601 interval (default: PT1M)
  -o, --out-dir            Output directory (default: .)
  -p, --prefix             Output filename prefix (default: vmss_disk)
  -h, --help               Show this help

Examples:
  ./vmss-metrics-disk.sh -g rg-prod -n app-vmss
  ./vmss-metrics-disk.sh -g rg-prod -n app-vmss -t 6h -i PT5M -o ./out -p nightly
  ./vmss-metrics-disk.sh -g rg-prod -n app-vmss -s "yesterday 10:00" -e "yesterday 11:00"
EOF
}

normalize_offset() {
    local input="$1"
    if [[ "$input" =~ ^[0-9]+[dhm]$ ]]; then
        echo "$input"
        return 0
    fi

    if [[ "$input" =~ ^PT([0-9]+)H$ ]]; then
        echo "${BASH_REMATCH[1]}h"
        return 0
    fi
    if [[ "$input" =~ ^PT([0-9]+)M$ ]]; then
        echo "${BASH_REMATCH[1]}m"
        return 0
    fi
    if [[ "$input" =~ ^P([0-9]+)D$ ]]; then
        echo "${BASH_REMATCH[1]}d"
        return 0
    fi

    echo "Error: Invalid time range '$input'. Use values like 1h, 30m, 1d, PT1H, PT30M, or P1D." >&2
    return 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -g|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -n|--vmss-name)
            VMSS_NAME="$2"
            shift 2
            ;;
        -t|--time-range)
            TIME_RANGE="$2"
            shift 2
            ;;
        -s|--start-time)
            START_TIME="$2"
            shift 2
            ;;
        -e|--end-time)
            END_TIME="$2"
            shift 2
            ;;
        -i|--interval)
            INTERVAL="$2"
            shift 2
            ;;
        -o|--out-dir)
            OUT_DIR="$2"
            shift 2
            ;;
        -p|--prefix)
            PREFIX="$2"
            shift 2
            ;;
        -h|--help)
            usage
            safe_exit 0
            ;;
        *)
            echo "Error: Unknown argument '$1'" >&2
            usage
            safe_exit 1
            ;;
    esac
done

if [[ -z "$RESOURCE_GROUP" || -z "$VMSS_NAME" ]]; then
    echo "Error: --resource-group and --vmss-name are required." >&2
    usage
    safe_exit 1
fi

TIME_MODE="offset"
WINDOW_LABEL=""
START_TIME_UTC=""
END_TIME_UTC=""

if [[ -n "$START_TIME" || -n "$END_TIME" ]]; then
    if [[ -z "$START_TIME" || -z "$END_TIME" ]]; then
        echo "Error: --start-time and --end-time must be provided together." >&2
        safe_exit 1
    fi

    if ! START_TIME_UTC=$(normalize_datetime_to_utc "$START_TIME"); then
        safe_exit 1
    fi
    if ! END_TIME_UTC=$(normalize_datetime_to_utc "$END_TIME"); then
        safe_exit 1
    fi

    START_EPOCH=$(date -u -d "$START_TIME_UTC" +%s)
    END_EPOCH=$(date -u -d "$END_TIME_UTC" +%s)
    WINDOW_SECONDS=$(( END_EPOCH - START_EPOCH ))

    if [[ "$WINDOW_SECONDS" -le 0 ]]; then
        echo "Error: --end-time must be later than --start-time." >&2
        safe_exit 1
    fi

    TIME_MODE="absolute"
    WINDOW_LABEL="From $START_TIME_UTC to $END_TIME_UTC"
else
    if ! TIME_RANGE=$(normalize_offset "$TIME_RANGE"); then
        safe_exit 1
    fi

    if ! WINDOW_SECONDS=$(offset_to_seconds "$TIME_RANGE"); then
        safe_exit 1
    fi

    WINDOW_LABEL="Last $TIME_RANGE"
fi

# ====== VALIDATION ======
if ! command -v az >/dev/null 2>&1; then
    echo "Error: Azure CLI (az) is not installed." >&2
    safe_exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for JSON parsing." >&2
    safe_exit 1
fi

if ! az account show >/dev/null 2>&1; then
    echo "Error: Not logged into Azure CLI. Run 'az login' first." >&2
    safe_exit 1
fi

mkdir -p "$OUT_DIR"

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
CSV_FILE="$OUT_DIR/${PREFIX}_${VMSS_NAME}_${TIMESTAMP}.csv"
JSON_FILE="$OUT_DIR/${PREFIX}_${VMSS_NAME}_${TIMESTAMP}.json"
TMP_FILE=$(mktemp)

trap 'rm -f "$TMP_FILE"' EXIT

echo "Fetching VMSS instances from $VMSS_NAME..."
INSTANCE_IDS=$(az vmss list-instances \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VMSS_NAME" \
    --query "[].instanceId" -o tsv)

if [[ -z "$INSTANCE_IDS" ]]; then
    echo "No instances found in VMSS '$VMSS_NAME'."
    safe_exit 1
fi

echo "instanceId,diskReadBytes,diskWriteBytes,totalBytes,diskReadMB,diskWriteMB,totalMB,diskReadMBps,diskWriteMBps,totalMBps" > "$CSV_FILE"

echo "Collecting disk throughput metrics per instance..."
echo "Window: $WINDOW_LABEL | Interval: $INTERVAL"

METRIC_TIME_ARGS=()
if [[ "$TIME_MODE" == "absolute" ]]; then
    METRIC_TIME_ARGS+=(--start-time "$START_TIME_UTC" --end-time "$END_TIME_UTC")
else
    METRIC_TIME_ARGS+=(--offset "$TIME_RANGE")
fi

for INSTANCE_ID in $INSTANCE_IDS; do
    RESOURCE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Compute/virtualMachineScaleSets/$VMSS_NAME/virtualMachines/$INSTANCE_ID"

    if ! METRICS_JSON=$(az monitor metrics list \
        --resource "$RESOURCE_ID" \
        --metrics "Disk Read Bytes" "Disk Write Bytes" \
        --interval "$INTERVAL" \
        --aggregation Total \
        "${METRIC_TIME_ARGS[@]}" \
        -o json); then
        echo "Warning: Failed to fetch metrics for instance $INSTANCE_ID. Skipping." >&2
        continue
    fi

    if ! DISK_READ=$(jq -r '[.value[] | select(.name.value=="Disk Read Bytes") | .timeseries[].data[].total // 0] | add // 0' <<< "$METRICS_JSON"); then
        echo "Warning: Failed to parse Disk Read Bytes for instance $INSTANCE_ID. Skipping." >&2
        continue
    fi
    if ! DISK_WRITE=$(jq -r '[.value[] | select(.name.value=="Disk Write Bytes") | .timeseries[].data[].total // 0] | add // 0' <<< "$METRICS_JSON"); then
        echo "Warning: Failed to parse Disk Write Bytes for instance $INSTANCE_ID. Skipping." >&2
        continue
    fi
    if ! TOTAL=$(jq -nr --argjson r "$DISK_READ" --argjson w "$DISK_WRITE" '$r + $w'); then
        echo "Warning: Failed to calculate totals for instance $INSTANCE_ID. Skipping." >&2
        continue
    fi

    DISK_READ_MB=$(bytes_to_mb "$DISK_READ")
    DISK_WRITE_MB=$(bytes_to_mb "$DISK_WRITE")
    TOTAL_MB=$(bytes_to_mb "$TOTAL")
    DISK_READ_MBPS=$(jq -nr --argjson mb "$DISK_READ_MB" --argjson sec "$WINDOW_SECONDS" 'if $sec > 0 then ($mb / $sec) else 0 end')
    DISK_WRITE_MBPS=$(jq -nr --argjson mb "$DISK_WRITE_MB" --argjson sec "$WINDOW_SECONDS" 'if $sec > 0 then ($mb / $sec) else 0 end')
    TOTAL_MBPS=$(jq -nr --argjson mb "$TOTAL_MB" --argjson sec "$WINDOW_SECONDS" 'if $sec > 0 then ($mb / $sec) else 0 end')

    jq -n \
        --arg instanceId "$INSTANCE_ID" \
        --argjson diskReadBytes "$DISK_READ" \
        --argjson diskWriteBytes "$DISK_WRITE" \
        --argjson totalBytes "$TOTAL" \
        --argjson diskReadMB "$DISK_READ_MB" \
        --argjson diskWriteMB "$DISK_WRITE_MB" \
        --argjson totalMB "$TOTAL_MB" \
        --argjson diskReadMBps "$DISK_READ_MBPS" \
        --argjson diskWriteMBps "$DISK_WRITE_MBPS" \
        --argjson totalMBps "$TOTAL_MBPS" \
        '{instanceId:$instanceId, diskReadBytes:$diskReadBytes, diskWriteBytes:$diskWriteBytes, totalBytes:$totalBytes, diskReadMB:$diskReadMB, diskWriteMB:$diskWriteMB, totalMB:$totalMB, diskReadMBps:$diskReadMBps, diskWriteMBps:$diskWriteMBps, totalMBps:$totalMBps}' >> "$TMP_FILE"

    printf '%s,%s,%s,%s,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n' "$INSTANCE_ID" "$DISK_READ" "$DISK_WRITE" "$TOTAL" "$DISK_READ_MB" "$DISK_WRITE_MB" "$TOTAL_MB" "$DISK_READ_MBPS" "$DISK_WRITE_MBPS" "$TOTAL_MBPS" >> "$CSV_FILE"
    printf 'Instance %s: READ=%s bytes (%.2f MB, %.4f MB/s), WRITE=%s bytes (%.2f MB, %.4f MB/s), TOTAL=%s bytes (%.2f MB, %.4f MB/s)\n' "$INSTANCE_ID" "$DISK_READ" "$DISK_READ_MB" "$DISK_READ_MBPS" "$DISK_WRITE" "$DISK_WRITE_MB" "$DISK_WRITE_MBPS" "$TOTAL" "$TOTAL_MB" "$TOTAL_MBPS"
done

if ! jq -s '.' "$TMP_FILE" > "$JSON_FILE"; then
    echo "Error: Failed to write JSON export file." >&2
    safe_exit 1
fi

echo
echo "=== Disk Throughput Comparison (Highest to Lowest) ==="
echo "Window: $WINDOW_LABEL | Interval: $INTERVAL"
tail -n +2 "$CSV_FILE" | sort -t, -k4,4nr | awk -F',' '{
    printf "Instance %s: TOTAL=%s bytes (%.2f MB, %.4f MB/s), READ=%s bytes (%.2f MB, %.4f MB/s), WRITE=%s bytes (%.2f MB, %.4f MB/s)\n", $1, $4, $7, $10, $2, $5, $8, $3, $6, $9
}'

SUMMARY=$(jq '
  {
        timeMode: $timeMode,
        interval: $interval,
        timeRange: (if $timeMode == "offset" then $timeRange else null end),
        startTime: (if $timeMode == "absolute" then $startTime else null end),
        endTime: (if $timeMode == "absolute" then $endTime else null end),
        windowSeconds: $windowSeconds,
        nodeCount: length,
        totalReadBytes: (map(.diskReadBytes) | add // 0),
        totalWriteBytes: (map(.diskWriteBytes) | add // 0),
        totalBytes: (map(.totalBytes) | add // 0),
        totalReadMB: (map(.diskReadMB) | add // 0),
        totalWriteMB: (map(.diskWriteMB) | add // 0),
        totalMB: (map(.totalMB) | add // 0),
        totalReadMBps: (if $windowSeconds == 0 then 0 else ((map(.diskReadMB) | add // 0) / $windowSeconds) end),
        totalWriteMBps: (if $windowSeconds == 0 then 0 else ((map(.diskWriteMB) | add // 0) / $windowSeconds) end),
        totalMBps: (if $windowSeconds == 0 then 0 else ((map(.totalMB) | add // 0) / $windowSeconds) end),
        averageBytesPerNode: (if length == 0 then 0 else ((map(.totalBytes) | add // 0) / length) end),
        averageMBPerNode: (if length == 0 then 0 else ((map(.totalMB) | add // 0) / length) end),
        highest: (if length == 0 then null else max_by(.totalBytes) end),
        lowest: (if length == 0 then null else min_by(.totalBytes) end)
  }
' --arg timeMode "$TIME_MODE" --arg interval "$INTERVAL" --arg timeRange "$TIME_RANGE" --arg startTime "$START_TIME_UTC" --arg endTime "$END_TIME_UTC" --argjson windowSeconds "$WINDOW_SECONDS" "$JSON_FILE")

echo
echo "=== Summary ==="
echo "$SUMMARY" | jq '.'

echo
echo "Exported files:"
echo "- CSV: $CSV_FILE"
echo "- JSON: $JSON_FILE"
