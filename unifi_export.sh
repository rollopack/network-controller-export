#!/usr/bin/env bash
#
# unifi_export.sh — Export UniFi device inventory to a TSV file
# https://github.com/rollopack/unifi-site-devices
# SPDX-License-Identifier: GPL-3.0-only
# Version 1.3.0

set -euo pipefail

# Default
CONTROLLER="${CONTROLLER:-https://controller.unifi.net:8443}"
SITE="${SITE:-}"
API_PATH="${API_PATH:-}"
USER="${USER:-admin}"
SORT="ip"   # ip | desc
OUTFILE=""
HIDE_OFFLINE=false
VERSION="1.3.0"

usage() {
  echo "Usage: $0 [-s <site_id>] [-c controller_url] [-u username] [-o output_file] [-O ip|desc] [-H] [-p api_path]"
  echo "  -s <id>  : site ID (if omitted, pick interactively)"
  echo "  -c <url> : controller URL (default: $CONTROLLER)"
  echo "  -u <usr> : controller username (default: $USER)"
  echo "  -o <file>: output file (default: Unifi-devices_<site>.txt)"
  echo "  -O ip    : order by IP (default)"
  echo "  -O desc  : order by Description (name)"
  echo "  -H       : hide offline devices"
  echo "  -p <path>: API path prefix, e.g. /proxy/network for UniFi OS (default: none)"
  echo "  -V       : show version"
  echo
  echo "Example:"
  echo "  $0 -s abcdef12 -c https://controller.unifi.net:8443 -u admin -O desc"
  echo "  $0 -s abcdef12 -p /proxy/network        # UniFi OS (UDM)"
  echo "  $0                                       # interactive site selection"
  exit 1
}

while getopts "c:s:u:o:O:Hp:Vh" opt; do
  case "$opt" in
    c) CONTROLLER="$OPTARG" ;;
    s) SITE="$OPTARG" ;;
    u) USER="$OPTARG" ;;
    o) OUTFILE="$OPTARG" ;;
    O)
      case "$OPTARG" in
        ip|desc) SORT="$OPTARG" ;;
        *) echo "Invalid value for -O, use 'ip' or 'desc'." >&2; exit 1 ;;
      esac
      ;;
    H) HIDE_OFFLINE=true ;;
    p) API_PATH="$OPTARG" ;;
    V) echo "unifi_export.sh v$VERSION"; exit 0 ;;
    h|*) usage ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq not found. Install jq and try again." >&2
  exit 1
fi

read -s -p "Password for user '$USER': " PASS
echo

COOKIE_FILE="$(mktemp)"
trap 'rm -f "$COOKIE_FILE"' EXIT

echo "Logging in to $CONTROLLER ..."
curl -sk -c "$COOKIE_FILE" \
  -X POST "$CONTROLLER${API_PATH}/api/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$USER\",\"password\":\"$PASS\"}" >/dev/null || {
  echo "Error: login failed for user '$USER' on $CONTROLLER${API_PATH}/api/login" >&2
  exit 1
}

echo "Fetching available sites ..."
SITES_JSON="$(curl -sk -b "$COOKIE_FILE" "$CONTROLLER${API_PATH}/api/self/sites")" || {
  echo "Error: failed to fetch sites from $CONTROLLER${API_PATH}/api/self/sites" >&2
  exit 1
}
SITES_RC="$(echo "$SITES_JSON" | jq -r '.meta.rc')"
if [[ "$SITES_RC" != "ok" ]]; then
  echo "Error fetching sites: meta.rc=$SITES_RC" >&2
  echo "$SITES_JSON" | jq . >&2
  exit 1
fi

if [[ -z "$SITE" ]]; then
  echo "Available sites:"
  echo "$SITES_JSON" | jq -r '.data[] | "\(.name)\t\(.desc)"' | \
    awk '{printf "%3d  %s\n", NR, $0}'
  echo
  read -p "Select site (number): " SEL
  SITE=$(echo "$SITES_JSON" | jq -r --arg n "$SEL" '.data[$n | tonumber - 1] | .name')
  if [[ -z "$SITE" || "$SITE" == "null" ]]; then
    echo "Error: invalid selection." >&2
    exit 1
  fi
  echo "Selected site: $SITE"
else
  SITE_VALID=$(echo "$SITES_JSON" | jq -r --arg site "$SITE" '.data[] | select(.name == $site) | "ok"')
  if [[ -z "$SITE_VALID" ]]; then
    echo "Error: site '$SITE' not found." >&2
    echo "Available sites:" >&2
    echo "$SITES_JSON" | jq -r '.data[] | "  \(.name)\t\(.desc)"' >&2
    exit 1
  fi
fi

if [[ -z "$OUTFILE" ]]; then
  OUTFILE="Unifi-devices_${SITE}.txt"
fi

echo "Fetching device list for site '$SITE' ..."
JSON="$(curl -sk -b "$COOKIE_FILE" \
  "$CONTROLLER${API_PATH}/api/s/$SITE/stat/device")" || {
  echo "Error: failed to fetch devices from $CONTROLLER${API_PATH}/api/s/$SITE/stat/device" >&2
  exit 1
}

RC="$(echo "$JSON" | jq -r '.meta.rc')"
if [[ "$RC" != "ok" ]]; then
  echo "API error: meta.rc=$RC" >&2
  echo "$JSON" | jq . >&2
  exit 1
fi

COUNT="$(echo "$JSON" | jq '.data | length')"
if [[ "$COUNT" -eq 0 ]]; then
  echo "Warning: no devices found for site '$SITE'." >&2
fi

echo "Writing output to $OUTFILE (order: $SORT) ..."

{
  echo "...::: Devices :::..."
  echo
  printf "IP\t\tMAC\t\t\tModel\tDescription\n"
  echo "$JSON" | jq -r --arg sort "$SORT" --arg hide_offline "$HIDE_OFFLINE" '
    [ .data[]
      | select($hide_offline == "false" or .state == 1)
      | {ip, mac, model: (.model // ""), name}
    ]
    | (if $sort == "desc"
       then
         sort_by(.name)
       else
          # numeric IP sort: 192.168.1.11 < 192.168.1.117 < 192.168.1.200
         sort_by(.ip | split(".") | map(tonumber))
       end)
    | .[]
    | "\(.ip)\t\(.mac)\t\(.model)\t\(.name)"
  '
} > "$OUTFILE"

echo "Done. File generated: $OUTFILE"
