# VMSS Node Network Metrics Script

This repository contains a Bash script that collects per-instance network traffic metrics for an Azure Virtual Machine Scale Set (VMSS), then exports results to CSV and JSON.

## File

- `vmss-metrics-node.sh`

## What the script does

- Lists all VMSS instances.
- Queries Azure Monitor metrics for each instance:
  - Network In Total
  - Network Out Total
- Calculates per-node totals in:
  - Bytes
  - MB
  - MB/s (based on the selected window)
- Prints per-node output and a sorted traffic comparison.
- Exports detailed data to:
  - CSV file
  - JSON file

## Prerequisites

- Bash shell (tested in Azure Cloud Shell / Linux shell)
- Azure CLI (`az`) installed and logged in
- `jq` installed

Validate prerequisites quickly:

```bash
az account show
jq --version
```

## Usage

```bash
./vmss-metrics-node.sh -g <resource-group> -n <vmss-name> [options]
```

## Required arguments

- `-g, --resource-group` : Resource group containing the VMSS
- `-n, --vmss-name` : VMSS name

## Optional arguments

- `-t, --time-range` : Relative window like `1h`, `30m`, `1d`, `PT1H`, `PT30M`, `P1D` (default: `1h`)
- `-s, --start-time` : Absolute start time (for example `"2026-04-14 10:00"` or `"yesterday 10:00"`)
- `-e, --end-time` : Absolute end time (for example `"2026-04-14 11:00"` or `"yesterday 11:00"`)
- `-i, --interval` : Metric interval in ISO8601 format (default: `PT1M`)
- `-o, --out-dir` : Output folder (default: current directory)
- `-p, --prefix` : Output file prefix (default: `vmss_metrics`)
- `-h, --help` : Show help

## Time window behavior

The script supports two modes:

1. Relative mode (default)
- Uses `--time-range`
- Example: last 1 hour

2. Absolute mode
- Uses `--start-time` and `--end-time`
- Both must be provided together
- End time must be greater than start time
- Times are normalized to UTC for Azure Monitor queries

If start/end time is provided, absolute mode is used and `--time-range` is ignored.

## Examples

Relative time range (last 1 hour):

```bash
./vmss-metrics-node.sh -g rg-prod -n app-vmss
```

Relative time range (last 6 hours, 5-minute interval):

```bash
./vmss-metrics-node.sh -g rg-prod -n app-vmss -t 6h -i PT5M
```

Absolute custom window (yesterday 10:00 to 11:00):

```bash
./vmss-metrics-node.sh -g rg-prod -n app-vmss -s "yesterday 10:00" -e "yesterday 11:00"
```

Absolute custom window with explicit timestamps:

```bash
./vmss-metrics-node.sh -g rg-prod -n app-vmss -s "2026-04-14 10:00" -e "2026-04-14 11:00"
```

Custom output location and filename prefix:

```bash
./vmss-metrics-node.sh -g rg-prod -n app-vmss -o ./out -p nightly
```

## Output files

Each run creates timestamped files:

- CSV: `<prefix>_<vmss-name>_<timestamp>.csv`
- JSON: `<prefix>_<vmss-name>_<timestamp>.json`

## Notes

- The script uses Azure CLI metric command:
  - `az monitor metrics list`
- Ensure the signed-in Azure account has permission to read VMSS and metric data.
- If running in a non-GNU environment (for example macOS default `date`), datetime parsing behavior may differ.
