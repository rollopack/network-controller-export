#!/usr/bin/env bash
#
# unifi_export.sh — Export UniFi device inventory to a TSV file
# https://github.com/rollopack/unifi-site-devices
# Version 1.1.0

set -euo pipefail

# Default
CONTROLLER="${CONTROLLER:-https://controller.unifi.net:8443}"
SITE="${SITE:-}"
USER="${USER:-admin}"
SORT="ip"   # ip | desc
OUTFILE=""
HIDE_OFFLINE=false

usage() {
  echo "Usage: $0 -s <site_id> [-c controller_url] [-u username] [-o output_file] [-O ip|desc] [-H]"
  echo "  -s <id>  : site ID (required)"
  echo "  -O ip    : order by IP (default)"
  echo "  -O desc  : order by Description (name)"
  echo "  -H       : hide offline devices"
  echo
  echo "Example:"
  echo "  $0 -s abcdef12 -c https://controller.unifi.net:8443 -u admin -O desc -o devices.txt"
  exit 1
}

while getopts "c:s:u:o:O:Hh" opt; do
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
    h|*) usage ;;
  esac
done

if [[ -z "$SITE" ]]; then
  echo "Error: site ID is required (-s <site_id>)." >&2
  exit 1
fi

if [[ -z "$OUTFILE" ]]; then
  OUTFILE="Unifi-devices_${SITE}.txt"
fi

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
  -X POST "$CONTROLLER/api/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$USER\",\"password\":\"$PASS\"}" >/dev/null

echo "Fetching available sites ..."
SITES_JSON="$(curl -sk -b "$COOKIE_FILE" "$CONTROLLER/api/self/sites")"
SITES_RC="$(echo "$SITES_JSON" | jq -r '.meta.rc')"
if [[ "$SITES_RC" != "ok" ]]; then
  echo "Error fetching sites: meta.rc=$SITES_RC" >&2
  exit 1
fi

SITE_VALID=$(echo "$SITES_JSON" | jq -r --arg site "$SITE" '.data[] | select(.name == $site) | "ok"')
if [[ -z "$SITE_VALID" ]]; then
  echo "Error: site '$SITE' not found." >&2
  echo "Available sites:" >&2
  echo "$SITES_JSON" | jq -r '.data[] | "  \(.name)\t\(.desc)"' >&2
  exit 1
fi

echo "Fetching device list for site '$SITE' ..."
JSON="$(curl -sk -b "$COOKIE_FILE" \
  "$CONTROLLER/api/s/$SITE/stat/device")"

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
  printf "IP\t\tMAC\t\t\tDescription\n"
  echo "$JSON" | jq -r --arg sort "$SORT" --arg hide_offline "$HIDE_OFFLINE" '
    [ .data[]
      | select($hide_offline == "false" or .state == 1)
      | {ip, mac, name}
    ]
    | (if $sort == "desc"
       then
         sort_by(.name)
       else
          # numeric IP sort: 192.168.1.11 < 192.168.1.117 < 192.168.1.200
         sort_by(.ip | split(".") | map(tonumber))
       end)
    | .[]
    | "\(.ip)\t\(.mac)\t\(.name)"
  '
} > "$OUTFILE"

echo "Done. File generated: $OUTFILE"
