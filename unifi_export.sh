#!/usr/bin/env bash
#
# unifi_export.sh — Export UniFi device inventory to a TSV file
# https://github.com/rollopack/network-controller-export
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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="${UNIFI_CONFIG_FILE:-$SCRIPT_DIR/unifi.conf}"
EXPORT_DIR="${EXPORT_DIR:-$SCRIPT_DIR/exports}"

# Default
CONTROLLER="${CONTROLLER:-https://uos.unifi.net:11443}"
SITE="${SITE:-}"
API_PATH="${API_PATH:-/proxy/network}"
USER="${USER:-admin}"
SORT="ip"   # ip | desc
OUTFILE=""
HIDE_OFFLINE=false
HIDE_LINK_COLUMN=false
EXPORT_TYPE="${EXPORT_TYPE:-devices}"
PASSWORD=""
HAS_T=false
VERSION="2.2.0"
CONFIG_HAS_EXPORT_TYPE=false
CONFIG_CAN_USE_PASSWORD=false

if [[ -f "$CONFIG_FILE" ]]; then
  CONFIG_MODE="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null || true)"
  if [[ "$CONFIG_MODE" =~ ^[0-7]{3,4}$ ]] && (( (8#$CONFIG_MODE & 077) == 0 )); then
    CONFIG_CAN_USE_PASSWORD=true
  else
    echo "Warning: $CONFIG_FILE is not owner-only; continuing, but any password there is ignored and requested interactively." >&2
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" != *=* ]]; then
      echo "Error: invalid configuration line in $CONFIG_FILE." >&2
      exit 1
    fi
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      CONTROLLER) CONTROLLER="$value" ;;
      SITE) SITE="$value" ;;
      USER) USER="$value" ;;
      PASSWORD)
        if "$CONFIG_CAN_USE_PASSWORD"; then PASSWORD="$value"; fi
        ;;
      API_PATH) API_PATH="$value" ;;
      SORT)
        case "$value" in
          ip|desc) SORT="$value" ;;
          *) echo "Invalid SORT in $CONFIG_FILE; use 'ip' or 'desc'." >&2; exit 1 ;;
        esac
        ;;
      EXPORT_TYPE)
        if [[ -n "$value" ]]; then
          case "$value" in
            devices|clients|both) EXPORT_TYPE="$value"; CONFIG_HAS_EXPORT_TYPE=true ;;
            *) echo "Invalid EXPORT_TYPE in $CONFIG_FILE." >&2; exit 1 ;;
          esac
        fi
        ;;
      HIDE_OFFLINE|HIDE_LINK_COLUMN)
        if [[ "$value" != true && "$value" != false ]]; then
          echo "$key in $CONFIG_FILE must be true or false." >&2
          exit 1
        fi
        if [[ "$key" == HIDE_OFFLINE ]]; then HIDE_OFFLINE="$value"; else HIDE_LINK_COLUMN="$value"; fi
        ;;
      *) echo "Error: unknown key '$key' in $CONFIG_FILE." >&2; exit 1 ;;
    esac
  done < "$CONFIG_FILE"
fi

if "$CONFIG_HAS_EXPORT_TYPE"; then HAS_T=true; fi

usage() {
  echo "Usage: $0 [-s <site_id>] [-c controller_url] [-u username] [-o output_file] [-O ip|desc] [-H] [-L] [-p api_path] [-T devices|clients|both]"
  echo "  -s <id>  : site ID (if omitted, pick interactively)"
  echo "  -c <url> : controller URL (default: $CONTROLLER)"
  echo "  -u <usr> : controller username (default: $USER)"
  echo "  -o <file>: output file (default: exports/Unifi-<type>_<site>.txt)"
  echo "  -O ip    : order by IP (default)"
  echo "  -O desc  : order by Description (name)"
  echo "  -H       : hide offline devices (applies to devices only)"
  echo "  -L       : hide the Connected to column (devices and clients)"
  echo "  -p <path>: API path prefix (default: /proxy/network for UniFi OS)."
  echo "             Set to empty (-p \"\") for software controller (no proxy)."
  echo "  -T <type>: export type: devices (default), clients, both"
  echo "  Settings: $CONFIG_FILE (a configured password is used only with owner-only file permissions)"
  echo "  -V       : show version"
  echo
  echo "Example:"
  echo "  $0 -s abcdef12 -c https://192.168.1.1 -u admin         # UniFi OS (default)"
  echo "  $0 -s abcdef12 -c uos.unifi.net:11443 -p \"\"      # software controller"
  echo "  $0                                                    # interactive"
  echo "  $0 -T clients                                         # export clients"
  exit 1
}

while getopts "c:s:u:o:O:HLp:T:Vh" opt; do
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
    L) HIDE_LINK_COLUMN=true ;;
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

PASS="$PASSWORD"
if [[ -z "$PASS" ]]; then
  read -r -s -p "Password for user '$USER': " PASS
  echo
fi

umask 077
COOKIE_FILE="$(mktemp)"
LOGIN_SECRET_FILE="$(mktemp)"
LOGIN_BODY_FILE="$(mktemp)"
MFA_TOKEN_FILE="$(mktemp)"
MFA_SESSION_FILE="$(mktemp)"
MFA_COOKIE_FILE="$(mktemp)"
printf '%s' "$PASS" > "$LOGIN_SECRET_FILE"
trap 'rm -f -- "$COOKIE_FILE" "$LOGIN_SECRET_FILE" "$LOGIN_BODY_FILE" "$MFA_TOKEN_FILE" "$MFA_SESSION_FILE" "$MFA_COOKIE_FILE"' EXIT

login_try() {
  local ep="$1"
  local mfa_token="${2:-}"
  local mfa_session="${3:-}"
  local mfa_cookie="${4:-}"
  printf '%s' "$mfa_token" > "$MFA_TOKEN_FILE"
  printf '%s' "$mfa_session" > "$MFA_SESSION_FILE"
  printf '%s' "$mfa_cookie" > "$MFA_COOKIE_FILE"
  jq -n --arg username "$USER" --rawfile password "$LOGIN_SECRET_FILE" \
    --rawfile mfa_token "$MFA_TOKEN_FILE" --rawfile mfa_session "$MFA_SESSION_FILE" \
    '{username:$username,password:$password} + (if $mfa_token != "" and $mfa_session != "" then {mfaToken:$mfa_token,mfaSession:$mfa_session} elif $mfa_token != "" then {mfaToken:$mfa_token} else {} end)' \
    > "$LOGIN_BODY_FILE"
  local curl_cookie_args=()
  if [[ -n "$mfa_cookie" ]]; then curl_cookie_args=(-b "$COOKIE_FILE" -b "$MFA_COOKIE_FILE"); fi
  # Login is always at controller root (OS-level endpoint)
  if [[ -n "$mfa_cookie" ]]; then
    curl -sk -c "$COOKIE_FILE" "${curl_cookie_args[@]}" \
      -X POST "$CONTROLLER$ep" \
      -H "Content-Type: application/json" \
      --data-binary "@$LOGIN_BODY_FILE"
  else
    curl -sk -c "$COOKIE_FILE" \
      -X POST "$CONTROLLER$ep" \
      -H "Content-Type: application/json" \
      --data-binary "@$LOGIN_BODY_FILE"
  fi
}

login_ok() {
  local json="$1"
  local rc
  rc=$(echo "$json" | jq -r '.meta.rc // "error"')
  [[ "$rc" == "ok" ]] && return 0
  # UniFi OS: successful login returns user profile (has unique_id)
  echo "$json" | jq -e 'has("unique_id")' >/dev/null 2>&1 && return 0
  return 1
}

echo "Logging in to $CONTROLLER ..."
LOGIN_JSON="$(login_try "/api/auth/login")"

login_ok "$LOGIN_JSON" || {
  LOGIN_JSON="$(login_try "/api/login")"
}

login_ok "$LOGIN_JSON" || {
  MFA_CODE="$(echo "$LOGIN_JSON" | jq -r '.code // ""')"
  if [[ "$MFA_CODE" == "MFA_AUTH_REQUIRED" ]]; then
    echo "MFA token required (email OTP). Check your email for a verification code."
    read -s -p "Enter MFA code: " MFA_TOKEN
    echo
    MFA_COOKIE="$(echo "$LOGIN_JSON" | jq -r '.data.mfaCookie // ""')"
    MFA_SESSION="${MFA_COOKIE#UBIC_2FA=}"

    LOGIN_JSON="$(login_try "/api/auth/login" "$MFA_TOKEN" "$MFA_SESSION" "$MFA_COOKIE")"
    login_ok "$LOGIN_JSON" || LOGIN_JSON="$(login_try "/api/login" "$MFA_TOKEN" "$MFA_SESSION" "$MFA_COOKIE")"
  fi

  if ! login_ok "$LOGIN_JSON"; then
    echo "Error: login failed for user '$USER' on $CONTROLLER" >&2
    echo "$LOGIN_JSON" | jq . >&2
    exit 1
  fi
}

echo "Fetching available sites ..."
SITES_JSON="$(curl -sk -b "$COOKIE_FILE" "$CONTROLLER${API_PATH}/api/self/sites" 2>/dev/null || true)"
SITES_RC="$(echo "$SITES_JSON" | jq -r '.meta.rc // ""' 2>/dev/null || true)"

# Fallback: try direct path (software controller behind reverse proxy)
if [[ "$SITES_RC" != "ok" ]]; then
  SITES_JSON="$(curl -sk -b "$COOKIE_FILE" "$CONTROLLER/api/self/sites" 2>/dev/null || true)"
  SITES_RC="$(echo "$SITES_JSON" | jq -r '.meta.rc // ""' 2>/dev/null || true)"
  if [[ "$SITES_RC" == "ok" ]]; then
    echo "Direct API path detected, clearing proxy prefix."
    API_PATH=""
  fi
fi

if [[ "$SITES_RC" != "ok" ]]; then
  echo "Error: failed to fetch sites from $CONTROLLER${API_PATH}/api/self/sites" >&2
  echo "Response:" >&2
  echo "$SITES_JSON" | head -c 500 >&2
  echo >&2
  echo "If you are using a software controller, try -p \"\" to disable the proxy prefix." >&2
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

DEVICE_JSON=""

render_device_group() {
  local category="$1"
  local title="$2"
  local group_rows

  group_rows="$(jq -r --arg category "$category" --arg sort "$SORT" \
    --arg hide_offline "$HIDE_OFFLINE" --arg hide_link "$HIDE_LINK_COLUMN" '
      def device_category:
        (.type // .device_type // "" | ascii_downcase) as $device_type
        | (.model // "" | ascii_upcase) as $model
        | if ($device_type | test("usw|switch")) or ($model | test("^(USW|USL|US[0-9]|USF)")) then "Switch"
          elif ($device_type | test("uap|access.?point")) or ($model | test("^(UAP|U[0-9]|BZ)")) then "AP"
          else "Other" end;
      def category_order:
        if .category == "Switch" then 0
        elif .category == "AP" then 1
        else 2 end;
      [.data[]] as $all_devices
      | (reduce $all_devices[] as $device ({};
          .[($device.mac // "" | ascii_downcase)] = ($device.name // "")
        )) as $names
      | [$all_devices[]
         | select($hide_offline == "false" or .state == 1)
         | . + {category: device_category}
         | . + {
             connected: (
               (.uplink.uplink_device_name // .uplink_device_name // "") as $direct
               | if $direct != "" then $direct
                 else ($names[((.uplink.uplink_mac // .uplink_mac // "") | ascii_downcase)] // "")
                 end
             ),
             port: (.uplink.uplink_remote_port_name // .uplink.uplink_remote_port // .uplink.remote_port // "")
           }
         | select(.category == $category)
        ]
      | (if $sort == "desc"
         then sort_by([category_order, (.name // "")])
         else sort_by([category_order, ((.ip // "") | split(".") | map(tonumber))])
         end)
      | .[]
      | ([.ip // "", .mac // "", .model // "", .name // ""] +
         (if $hide_link == "true" then [] else [
           (if .connected == "" then ""
            elif .port == "" then .connected
            else "\(.connected) (port \(.port))"
            end)
         ] end)) | @tsv
    ' <<< "$JSON")"

  [[ -n "$group_rows" ]] || return 0

  DEVICE_GROUPS_WRITTEN=true
  printf '...::: %s :::...\n\n' "$title"
  {
    printf "IP\tMAC\tModel\tDescription"
    if ! "$HIDE_LINK_COLUMN"; then printf "\tConnected to"; fi
    printf "\n%s\n" "$group_rows"
  } | if "$HAS_COLUMN"; then column -t -s $'\t'; else cat; fi
  printf '\n'
}

for EXPORT_TYPE in "${TYPES[@]}"; do

if [[ -z "$OUTFILE" ]]; then
  OUTFILE="$EXPORT_DIR/Unifi-${EXPORT_TYPE}_${SITE}.txt"
elif [[ "$OUTFILE" != /* ]]; then
  OUTFILE="$EXPORT_DIR/$OUTFILE"
fi
mkdir -p -- "$(dirname -- "$OUTFILE")"

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

if [[ "$EXPORT_TYPE" == "devices" ]]; then
  DEVICE_JSON="$JSON"
fi

COUNT="$(echo "$JSON" | jq '.data | length')"
if [[ "$COUNT" -eq 0 ]]; then
  echo "Warning: no $LABEL_PLURAL found for site '$SITE'." >&2
fi

echo "Writing output to $OUTFILE (order: $SORT) ..."

if [[ "$EXPORT_TYPE" == "devices" ]]; then
  DEVICE_GROUPS_WRITTEN=false
  {
    render_device_group "Switch" "Switches"
    render_device_group "AP" "Access Points"
    render_device_group "Other" "Other devices"
    if ! "$DEVICE_GROUPS_WRITTEN"; then
      printf '...::: Devices :::...\n\n'
      {
        printf "IP\tMAC\tModel\tDescription"
        if ! "$HIDE_LINK_COLUMN"; then printf "\tConnected to"; fi
        printf "\n"
      } | if "$HAS_COLUMN"; then column -t -s $'\t'; else cat; fi
    fi
  } > "$OUTFILE"
else
  CLIENT_DEVICE_JSON='{"data":[]}'
  if ! "$HIDE_LINK_COLUMN"; then
    if [[ -z "$DEVICE_JSON" ]]; then
      echo "Fetching device uplinks for client mapping ..."
      DEVICE_JSON="$(curl -sk -b "$COOKIE_FILE" \
        "$CONTROLLER${API_PATH}/api/s/$SITE/stat/device")" || {
        echo "Error: failed to fetch device uplinks from $CONTROLLER${API_PATH}/api/s/$SITE/stat/device" >&2
        exit 1
      }
      DEVICE_RC="$(echo "$DEVICE_JSON" | jq -r '.meta.rc')"
      if [[ "$DEVICE_RC" != "ok" ]]; then
        echo "API error while fetching device uplinks: meta.rc=$DEVICE_RC" >&2
        echo "$DEVICE_JSON" | jq . >&2
        exit 1
      fi
    fi
    CLIENT_DEVICE_JSON="$DEVICE_JSON"
  fi

  {
    echo "...::: Clients :::..."
    echo
    {
      printf "IP\tMAC\tVendor\tHostname"
      if ! "$HIDE_LINK_COLUMN"; then printf "\tConnected to"; fi
      printf "\n"
      printf '%s\n%s\n' "$JSON" "$CLIENT_DEVICE_JSON" | jq -sr --arg sort "$SORT" --arg hide_link "$HIDE_LINK_COLUMN" '
        .[0] as $clients
        | (reduce (.[1].data // [])[] as $device ({};
          .[($device.mac // "" | ascii_downcase)] = ($device.name // "")
        )) as $switches
        |
        [$clients.data[]
          | (.ap_name // "") as $ap_name
          | ((.sw_mac // "") | ascii_downcase) as $switch_mac
          | ($switches[$switch_mac] // "") as $switch_name
          | (.sw_port // "") as $switch_port
          | {ip, mac, vendor: (.oui // ""), hostname: (.hostname // ""),
             connected: (if $ap_name != "" then $ap_name
               elif $switch_name != "" and ($switch_port | tostring) != "" then "\($switch_name) (port \($switch_port))"
               elif $switch_name != "" then $switch_name
               else "Wired" end)}
        ]
        | (if $sort == "desc"
           then sort_by(.hostname)
           else sort_by((.ip // "") | split(".") | map(tonumber))
           end)
        | .[]
        | ([.ip // "", .mac // "", .vendor // "", .hostname // ""] +
           (if $hide_link == "true" then [] else [.connected] end)) | @tsv
      '
    } | if "$HAS_COLUMN"; then column -t -s $'\t'; else cat; fi
  } > "$OUTFILE"
fi

echo "Done. File generated: $OUTFILE"
OUTFILE=""

done
