#!/usr/bin/env bash
#
# unifi_export.sh — Export UniFi device inventory to a TSV file
# https://github.com/rollopack/unifi-site-devices
#
# Copyright (C) 2026 Rolland Gabriel (https://github.com/rollopack)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#

set -euo pipefail

# Default
CONTROLLER="${CONTROLLER:-https://controller.unifi.net:8443}"
SITE="${SITE:-}"
API_PATH="${API_PATH:-}"
USER="${USER:-admin}"
SORT="ip"   # ip | desc
OUTFILE=""
HIDE_OFFLINE=false
EXPORT_TYPE="${EXPORT_TYPE:-devices}"
HAS_T=false
VERSION="1.5.0"

usage() {
  echo "Usage: $0 [-s <site_id>] [-c controller_url] [-u username] [-o output_file] [-O ip|desc] [-H] [-p api_path] [-T devices|clients|both]"
  echo "  -s <id>  : site ID (if omitted, pick interactively)"
  echo "  -c <url> : controller URL (default: $CONTROLLER)"
  echo "  -u <usr> : controller username (default: $USER)"
  echo "  -o <file>: output file (default: Unifi-<type>_<site>.txt)"
  echo "  -O ip    : order by IP (default)"
  echo "  -O desc  : order by Description (name)"
  echo "  -H       : hide offline devices (applies to devices only)"
  echo "  -p <path>: API path prefix, e.g. /proxy/network for UniFi OS (default: none)"
  echo "  -T <type>: export type: devices (default), clients, both"
  echo "  -V       : show version"
  echo
  echo "Example:"
  echo "  $0 -s abcdef12 -c https://controller.unifi.net:8443 -u admin -O desc"
  echo "  $0 -s abcdef12 -p /proxy/network        # UniFi OS (UDM)"
  echo "  $0                                       # interactive site selection"
  echo "  $0 -T clients                            # export active clients"
  exit 1
}

while getopts "c:s:u:o:O:Hp:T:Vh" opt; do
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
    T)
      HAS_T=true
      case "$OPTARG" in
        devices|clients|both) EXPORT_TYPE="$OPTARG" ;;
        *) echo "Invalid value for -T, use 'devices', 'clients' or 'both'." >&2; exit 1 ;;
      esac
      ;;
    V) echo "unifi_export.sh v$VERSION"; exit 0 ;;
    h|*) usage ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq not found. Install jq and try again." >&2
  exit 1
fi

HAS_COLUMN=false
if command -v column >/dev/null 2>&1; then
  HAS_COLUMN=true
fi

echo "unifi_export.sh v$VERSION  Copyright (C) 2026 Rolland Gabriel"
echo "This program comes with ABSOLUTELY NO WARRANTY; see LICENSE."
echo "This is free software, and you are welcome to redistribute it"
echo "under certain conditions."
echo

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
  echo
  if ! "$HAS_T"; then
    echo "What to export?"
    PS3="Choose (1-3): "
    select opt in "Devices" "Clients" "Both"; do
      case "$opt" in
        "Devices") EXPORT_TYPE="devices"; break ;;
        "Clients") EXPORT_TYPE="clients"; break ;;
        "Both")    EXPORT_TYPE="both";    break ;;
        *) echo "Invalid choice";;
      esac
    done
  fi
else
  SITE_VALID=$(echo "$SITES_JSON" | jq -r --arg site "$SITE" '.data[] | select(.name == $site) | "ok"')
  if [[ -z "$SITE_VALID" ]]; then
    echo "Error: site '$SITE' not found." >&2
    echo "Available sites:" >&2
    echo "$SITES_JSON" | jq -r '.data[] | "  \(.name)\t\(.desc)"' >&2
    exit 1
  fi
fi

case "$EXPORT_TYPE" in
  both)  TYPES=(devices clients) ;;
  *)     TYPES=("$EXPORT_TYPE") ;;
esac

for EXPORT_TYPE in "${TYPES[@]}"; do

if [[ -z "$OUTFILE" ]]; then
  OUTFILE="Unifi-${EXPORT_TYPE}_${SITE}.txt"
fi

case "$EXPORT_TYPE" in
  devices)
    ENDPOINT="stat/device"
    LABEL="device"
    LABEL_PLURAL="devices"
    ;;
  clients)
    ENDPOINT="stat/sta"
    LABEL="client"
    LABEL_PLURAL="clients"
    ;;
esac

echo "Fetching $LABEL_PLURAL list for site '$SITE' ..."
JSON="$(curl -sk -b "$COOKIE_FILE" \
  "$CONTROLLER${API_PATH}/api/s/$SITE/$ENDPOINT")" || {
  echo "Error: failed to fetch $LABEL_PLURAL from $CONTROLLER${API_PATH}/api/s/$SITE/$ENDPOINT" >&2
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
  echo "Warning: no $LABEL_PLURAL found for site '$SITE'." >&2
fi

echo "Writing output to $OUTFILE (order: $SORT) ..."

if [[ "$EXPORT_TYPE" == "devices" ]]; then
  if "$HAS_COLUMN"; then
    {
      echo "...::: Devices :::..."
      echo
      {
        printf "IP\tMAC\tModel\tDescription\n"
        echo "$JSON" | jq -r --arg sort "$SORT" --arg hide_offline "$HIDE_OFFLINE" '
          [ .data[]
            | select($hide_offline == "false" or .state == 1)
            | {ip, mac, model: (.model // ""), name}
          ]
          | (if $sort == "desc"
             then
               sort_by(.name)
             else
               sort_by((.ip // "") | split(".") | map(tonumber))
             end)
          | .[]
          | "\(.ip)\t\(.mac)\t\(.model)\t\(.name)"
        '
      } | column -t -s $'\t'
    } > "$OUTFILE"
  else
    {
      echo "...::: Devices :::..."
      echo
      printf "IP\tMAC\tModel\tDescription\n"
      echo "$JSON" | jq -r --arg sort "$SORT" --arg hide_offline "$HIDE_OFFLINE" '
        [ .data[]
          | select($hide_offline == "false" or .state == 1)
          | {ip, mac, model: (.model // ""), name}
        ]
        | (if $sort == "desc"
           then
             sort_by(.name)
           else
             sort_by((.ip // "") | split(".") | map(tonumber))
           end)
        | .[]
        | "\(.ip)\t\(.mac)\t\(.model)\t\(.name)"
      '
    } > "$OUTFILE"
  fi
else
  if "$HAS_COLUMN"; then
    {
      echo "...::: Clients :::..."
      echo
      {
        printf "IP\tMAC\tFornitore\tHostname\tConnesso a\n"
        echo "$JSON" | jq -r --arg sort "$SORT" '
          [ .data[]
            | {ip, mac, vendor: (.oui // ""), hostname: (.hostname // ""), ap: (.ap_name // "Wired")}
          ]
          | (if $sort == "desc"
             then
               sort_by(.hostname)
             else
               sort_by((.ip // "") | split(".") | map(tonumber))
             end)
          | .[]
          | "\(.ip)\t\(.mac)\t\(.vendor)\t\(.hostname)\t\(.ap)"
        '
      } | column -t -s $'\t'
    } > "$OUTFILE"
  else
    {
      echo "...::: Clients :::..."
      echo
      printf "IP\tMAC\tFornitore\tHostname\tConnesso a\n"
      echo "$JSON" | jq -r --arg sort "$SORT" '
        [ .data[]
          | {ip, mac, vendor: (.oui // ""), hostname: (.hostname // ""), ap: (.ap_name // "Wired")}
        ]
        | (if $sort == "desc"
           then
             sort_by(.hostname)
           else
             sort_by((.ip // "") | split(".") | map(tonumber))
           end)
        | .[]
        | "\(.ip)\t\(.mac)\t\(.vendor)\t\(.hostname)\t\(.ap)"
      '
    } > "$OUTFILE"
  fi
fi

echo "Done. File generated: $OUTFILE"
OUTFILE=""

done
