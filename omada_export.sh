#!/usr/bin/env bash
#
# omada_export.sh — Export Omada devices and clients to TSV
# https://github.com/rollopack/network-controller-export
#
# Copyright (C) 2026 Rolland Gabriel (https://github.com/rollopack)
# Licensed under the GNU General Public License v3.0 or later.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="${OMADA_CONFIG_FILE:-$SCRIPT_DIR/omada.conf}"
EXPORT_DIR="${EXPORT_DIR:-$SCRIPT_DIR/exports}"
CONTROLLER_URL=""
OMADA_ID=""
CLIENT_ID=""
CLIENT_SECRET=""
SITE_ID=""
INSECURE_TLS=false
SORT="ip"
EXPORT_TYPE="devices"
OUTFILE=""
HIDE_OFFLINE=false
HIDE_LINK_COLUMN=false
HAS_T=false
VERSION="1.0.0"
PAGE_SIZE=100
MAX_PAGES=100

usage() {
  cat <<USAGE
Usage: $0 [-c controller_url] [-s site_id_or_number] [-o output_file] [-O ip|desc] [-H] [-L] [-T devices|clients|both]
  -c <url>  : Omada Interface Access Address (overrides config)
  -s <id|n> : Site ID or 1-based number from the site list
  -o <file> : Output file (default: exports/Omada-<type>_<site>.txt)
  -O <sort> : Sort by IP or description (default: ip)
  -H        : Hide offline devices
  -L        : Hide the Connected to column
  -T <type> : devices (default), clients, or both
  -V        : Show version
  -h        : Show help

Credentials and controller identifiers are read from: $CONFIG_FILE
USAGE
}

CLI_CONTROLLER_URL=""
CLI_SITE_ID=""
while getopts ":c:s:o:O:HLT:Vh" opt; do
  case "$opt" in
    c) CLI_CONTROLLER_URL="$OPTARG" ;;
    s) CLI_SITE_ID="$OPTARG" ;;
    o) OUTFILE="$OPTARG" ;;
    O)
      case "$OPTARG" in
        ip|desc) SORT="$OPTARG" ;;
        *) echo "Invalid -O value; use 'ip' or 'desc'." >&2; exit 1 ;;
      esac
      ;;
    H) HIDE_OFFLINE=true ;;
    L) HIDE_LINK_COLUMN=true ;;
    T)
      HAS_T=true
      case "$OPTARG" in
        devices|clients|both) EXPORT_TYPE="$OPTARG" ;;
        *) echo "Invalid -T value; use 'devices', 'clients' or 'both'." >&2; exit 1 ;;
      esac
      ;;
    V) echo "omada_export.sh v$VERSION"; exit 0 ;;
    h) usage; exit 0 ;;
    :) echo "Option -$OPTARG requires an argument." >&2; exit 2 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage >&2; exit 2 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "Error: this script requires both curl and jq." >&2
  exit 1
fi

if [[ ! -r "$CONFIG_FILE" ]]; then
  echo "Error: configuration file not found or unreadable: $CONFIG_FILE" >&2
  echo "Copy omada.conf.example to omada.conf and fill its values." >&2
  exit 1
fi

CONFIG_MODE="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null || true)"
CONFIG_CAN_USE_SECRET=false
if [[ "$CONFIG_MODE" =~ ^[0-7]{3,4}$ ]] && (( (8#$CONFIG_MODE & 077) == 0 )); then
  CONFIG_CAN_USE_SECRET=true
else
  echo "Warning: $CONFIG_FILE is not owner-only; continuing, but any Client Secret there is ignored. Remove it and enter the secret when prompted." >&2
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
    OMADA_INTERFACE_ACCESS_ADDRESS) CONTROLLER_URL="$value" ;;
    OMADA_ID) OMADA_ID="$value" ;;
    OMADA_CLIENT_ID) CLIENT_ID="$value" ;;
    OMADA_CLIENT_SECRET)
      if "$CONFIG_CAN_USE_SECRET"; then
        CLIENT_SECRET="$value"
      fi
      ;;
    OMADA_SITE_ID) SITE_ID="$value" ;;
    OMADA_INSECURE_TLS) INSECURE_TLS="$value" ;;
    *) echo "Error: unknown key '$key' in $CONFIG_FILE." >&2; exit 1 ;;
  esac
done < "$CONFIG_FILE"

[[ -n "$CLI_CONTROLLER_URL" ]] && CONTROLLER_URL="$CLI_CONTROLLER_URL"
[[ -n "$CLI_SITE_ID" ]] && SITE_ID="$CLI_SITE_ID"
CONTROLLER_URL="${CONTROLLER_URL%/}"

if [[ -z "$CONTROLLER_URL" || -z "$OMADA_ID" || -z "$CLIENT_ID" ]]; then
  echo "Error: set Interface Access Address, Omada ID and Client ID in $CONFIG_FILE." >&2
  exit 1
fi
if [[ "$CONTROLLER_URL" != https://* && "$CONTROLLER_URL" != http://* ]]; then
  echo "Error: the Interface Access Address must start with http:// or https://." >&2
  exit 1
fi
if [[ "$INSECURE_TLS" != true && "$INSECURE_TLS" != false ]]; then
  echo "Error: OMADA_INSECURE_TLS must be true or false." >&2
  exit 1
fi
if [[ -z "$CLIENT_SECRET" ]]; then
  read -r -s -p "Omada Client Secret: " CLIENT_SECRET
  echo
fi
if [[ -z "$CLIENT_SECRET" ]]; then
  echo "Error: no Omada Client Secret was provided." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
chmod 700 "$TMP_DIR"
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT
umask 077
SECRET_FILE="$TMP_DIR/client-secret"
TOKEN_BODY_FILE="$TMP_DIR/token-request.json"
TOKEN_RESPONSE_FILE="$TMP_DIR/token-response.json"
AUTH_HEADER_FILE="$TMP_DIR/auth-header"
printf '%s' "$CLIENT_SECRET" > "$SECRET_FILE"
jq -n --arg omadac_id "$OMADA_ID" --arg client_id "$CLIENT_ID" \
  --rawfile client_secret "$SECRET_FILE" \
  '{omadacId:$omadac_id, client_id:$client_id, client_secret:$client_secret}' > "$TOKEN_BODY_FILE"

CURL_OPTS=(-sS --connect-timeout 15)
if [[ "$INSECURE_TLS" == true ]]; then CURL_OPTS+=(-k); fi

echo "Requesting Omada Open API access token ..."
if ! curl "${CURL_OPTS[@]}" -H "Content-Type: application/json" \
  --data-binary "@$TOKEN_BODY_FILE" \
  "$CONTROLLER_URL/openapi/authorize/token?grant_type=client_credentials" \
  > "$TOKEN_RESPONSE_FILE"; then
  echo "Error: could not reach the Omada token endpoint." >&2
  exit 1
fi
TOKEN_ERROR="$(jq -r '.errorCode // "unknown"' "$TOKEN_RESPONSE_FILE")"
if [[ "$TOKEN_ERROR" != 0 ]]; then
  TOKEN_MESSAGE="$(jq -r '.msg // "no message returned"' "$TOKEN_RESPONSE_FILE")"
  echo "Error: Omada token request failed (errorCode=$TOKEN_ERROR): $TOKEN_MESSAGE" >&2
  exit 1
fi
ACCESS_TOKEN="$(jq -r '.result.accessToken // empty' "$TOKEN_RESPONSE_FILE")"
if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "Error: Omada token response did not contain an accessToken." >&2
  exit 1
fi
printf 'Authorization: AccessToken=%s\n' "$ACCESS_TOKEN" > "$AUTH_HEADER_FILE"

HAS_COLUMN=false
if command -v column >/dev/null 2>&1; then HAS_COLUMN=true; fi
TYPES=("$EXPORT_TYPE")
if [[ "$EXPORT_TYPE" == both ]]; then TYPES=(devices clients); fi

api_get_to_file() {
  local url="$1"
  local destination="$2"
  if ! curl "${CURL_OPTS[@]}" -H "@$AUTH_HEADER_FILE" "$url" > "$destination"; then
    echo "Error: request to Omada Open API failed." >&2
    return 1
  fi
  local error_code
  error_code="$(jq -r '.errorCode // "unknown"' "$destination")"
  if [[ "$error_code" != 0 ]]; then
    local message
    message="$(jq -r '.msg // "no message returned"' "$destination")"
    echo "Error: Omada API request failed (errorCode=$error_code): $message" >&2
    return 1
  fi
}

fetch_pages() {
  local endpoint="$1"
  local destination="$2"
  local page=1
  local response_file="$TMP_DIR/page.json"
  local page_items_file="$TMP_DIR/page-items.json"
  local combined_file="$TMP_DIR/combined.json"
  printf '[]\n' > "$destination"

  while (( page <= MAX_PAGES )); do
    api_get_to_file "$CONTROLLER_URL/openapi/v1/$OMADA_ID/$endpoint?page=$page&pageSize=$PAGE_SIZE" "$response_file"
    if ! jq -e '.result.data | type == "array"' "$response_file" >/dev/null; then
      echo "Error: unexpected data format from Omada endpoint $endpoint." >&2
      return 1
    fi
    jq -c '.result.data' "$response_file" > "$page_items_file"
    local row_count
    row_count="$(jq 'length' "$page_items_file")"
    jq -s --slurpfile previous "$destination" '$previous[0] + .[0]' \
      "$page_items_file" > "$combined_file"
    mv -- "$combined_file" "$destination"
    (( row_count < PAGE_SIZE )) && break
    ((page++))
  done
  if (( page > MAX_PAGES )); then
    echo "Warning: reached the $MAX_PAGES-page limit for $endpoint." >&2
  fi
}

render_device_groups() {
  local devices_file="$1"
  local category title group_rows
  local groups_written=false

  for category in switch ap other; do
    case "$category" in
      switch) title="Switches" ;;
      ap) title="Access Points" ;;
      other) title="Other devices" ;;
    esac
    group_rows="$(jq -r --arg category "$category" --arg sort "$SORT" \
      --arg hide_offline "$HIDE_OFFLINE" --arg hide_link "$HIDE_LINK_COLUMN" '
        def device_category:
          (.type // .deviceType // "" | tostring | ascii_downcase) as $type
          | (.model // "" | tostring | ascii_upcase) as $model
          | if ($type | test("switch|usw")) or ($model | test("^(TL-SG|SG[0-9]|T2600|T2700|T3700)")) then "switch"
            elif ($type | test("(^|[^a-z])(ap|eap)([^a-z]|$)|access.?point")) or ($model | test("^EAP")) then "ap"
            else "other" end;
        def ip_order:
          (.ip // "") as $ip
          | if ($ip | test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$"))
            then ($ip | split(".") | map(tonumber)) else [999,999,999,999] end;
        def connection_port:
          (.uplinkPortName // .uplinkPort // .connectDevPort // .port // .uplink.port // "");
        def connection_name($names):
          (.uplinkDeviceName // .uplinkName // .connectDevName // .connectedDeviceName // .uplink.name // "") as $direct
          | if $direct != "" then $direct
            else ($names[((.uplinkDeviceMac // .uplinkMac // .connectDevMac // .uplink.mac // "") | ascii_downcase)] // "")
            end;
        . as $devices
        | (reduce $devices[] as $device ({};
            .[($device.mac // $device.deviceMac // "" | ascii_downcase)] = ($device.name // $device.deviceName // "")
          )) as $names
        | [$devices[]
           | select($hide_offline == "false" or .status == 1 or .status == "1")
           | . + {category: device_category}
           | . + {connected: connection_name($names), port: connection_port}
           | select(.category == $category)
          ]
        | (if $sort == "desc" then sort_by(.name // .deviceName // "") else sort_by(ip_order) end)
        | .[]
        | ([.ip // .ipAddress // "", .mac // .deviceMac // "", .model // .compoundModel // "", .name // .deviceName // ""] +
           (if $hide_link == "true" then [] else [
             (if .connected == "" then ""
              elif .port == "" then .connected
              else "\(.connected) (port \(.port))" end)
           ] end)) | @tsv
      ' "$devices_file")"

    [[ -n "$group_rows" ]] || continue
    local include_link=false
    if ! "$HIDE_LINK_COLUMN"; then
      local linked_rows
      linked_rows="$(printf '%s\n' "$group_rows" | awk -F '\t' 'NF >= 5 && $NF != "" { count++ } END { print count + 0 }')"
      if (( linked_rows > 0 )); then
        include_link=true
      else
        group_rows="$(printf '%s\n' "$group_rows" | cut -f1-4)"
      fi
    fi
    groups_written=true
    printf '...::: %s :::...\n\n' "$title"
    {
      printf "IP\tMAC\tModel\tDescription"
      if "$include_link"; then printf "\tConnected to"; fi
      printf "\n%s\n" "$group_rows"
    } | if "$HAS_COLUMN"; then column -t -s $'\t'; else cat; fi
    printf '\n'
  done

  if ! "$groups_written"; then
    printf '...::: Devices :::...\n\nIP\tMAC\tModel\tDescription\n'
  fi
}

render_clients() {
  local clients_file="$1"
  local devices_file="$2"
  local rows

  rows="$(jq -r --slurpfile devices "$devices_file" --arg sort "$SORT" \
    --arg hide_link "$HIDE_LINK_COLUMN" '
      def ip_order:
        (.ip // .ipAddress // "") as $ip
        | if ($ip | test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$"))
          then ($ip | split(".") | map(tonumber)) else [999,999,999,999] end;
      (reduce $devices[0][] as $device ({};
        .[($device.mac // $device.deviceMac // "" | ascii_downcase)] = ($device.name // $device.deviceName // "")
      )) as $device_names
      | [ .[]
          | (.apName // .ap_name // "") as $ap
          | (.connectDevName // .connectDeviceName // .connectedDeviceName // .switchName // .deviceName // "") as $direct
          | ($device_names[((.connectDevMac // .connectDeviceMac // .connectedDeviceMac // .switchMac // "") | ascii_downcase)] // "") as $mapped
          | (.connectDevPort // .connectDevicePort // .switchPort // .port // "") as $port
          | {ip: (.ip // .ipAddress // ""), mac: (.mac // .clientMac // ""),
             vendor: (.vendor // .oui // ""), hostname: (.hostname // .name // .clientName // ""),
              connected: (if $ap != "" then $ap
                elif $direct != "" then $direct
                elif $mapped != "" then $mapped
                else "" end), port: $port}
        ]
      | (if $sort == "desc" then sort_by(.hostname) else sort_by(ip_order) end)
      | .[]
      | ([.ip, .mac, .vendor, .hostname] +
         (if $hide_link == "true" then [] else [
           (if .connected == "" then ""
            elif .port == "" then .connected
            else "\(.connected) (port \(.port))" end)
         ] end)) | @tsv
    ' "$clients_file")"

  local include_link=false
  if ! "$HIDE_LINK_COLUMN"; then
    local linked_rows
    linked_rows="$(printf '%s\n' "$rows" | awk -F '\t' 'NF >= 5 && $NF != "" { count++ } END { print count + 0 }')"
    if (( linked_rows > 0 )); then
      include_link=true
    else
      rows="$(printf '%s\n' "$rows" | cut -f1-4)"
    fi
  fi
  {
    printf "IP\tMAC\tVendor\tHostname"
    if "$include_link"; then printf "\tConnected to"; fi
    printf '\n%s\n' "$rows"
  } | if "$HAS_COLUMN"; then column -t -s $'\t'; else cat; fi
}

SITE_FILE="$TMP_DIR/sites.json"
if [[ -z "$SITE_ID" || "$SITE_ID" =~ ^[0-9]+$ ]]; then
  echo "Fetching Omada sites ..."
  fetch_pages sites "$SITE_FILE"
  SITE_COUNT="$(jq 'length' "$SITE_FILE")"
  if (( SITE_COUNT == 0 )); then
    echo "Error: no Omada sites are available to this API client." >&2
    exit 1
  fi
  if [[ -z "$SITE_ID" ]]; then
    echo "Available Omada sites:"
    jq -r 'to_entries[] | "\(.key + 1)  \(.value.name // "(unnamed)")"' "$SITE_FILE"
    read -r -p "Select site (number): " SITE_SELECTION
  else
    SITE_SELECTION="$SITE_ID"
    EXACT_SITE_COUNT="$(jq --arg requested "$SITE_ID" '[.[] | select((.siteId // .id // .site_id // "" | tostring) == $requested)] | length' "$SITE_FILE")"
    if (( EXACT_SITE_COUNT == 0 )); then
      echo "No site has ID '$SITE_ID'; treating it as a 1-based site-list number."
    fi
  fi

  if [[ ! "$SITE_SELECTION" =~ ^[0-9]+$ ]]; then
    echo "Error: site selection must be a number." >&2
    exit 1
  fi

  EXACT_SITE_COUNT="$(jq --arg requested "$SITE_SELECTION" '[.[] | select((.siteId // .id // .site_id // "" | tostring) == $requested)] | length' "$SITE_FILE")"
  if (( EXACT_SITE_COUNT > 0 )); then
    SITE_NAME="$(jq -r --arg requested "$SITE_SELECTION" '[.[] | select((.siteId // .id // .site_id // "" | tostring) == $requested)][0].name // ""' "$SITE_FILE")"
    SITE_ID="$SITE_SELECTION"
  else
    if (( SITE_SELECTION < 1 || SITE_SELECTION > SITE_COUNT )); then
      echo "Error: '$SITE_SELECTION' is neither a site ID nor a valid list number." >&2
      exit 1
    fi
    SITE_ID="$(jq -r --argjson index "$SITE_SELECTION" '(.[$index - 1].siteId // .[$index - 1].id // .[$index - 1].site_id // empty)' "$SITE_FILE")"
    SITE_NAME="$(jq -r --argjson index "$SITE_SELECTION" '.[$index - 1].name // ""' "$SITE_FILE")"
    if [[ -z "$SITE_ID" ]]; then
      echo "Error: selected Omada site did not include a siteId." >&2
      exit 1
    fi
  fi
  echo "Selected Omada site: ${SITE_NAME:-$SITE_ID} ($SITE_ID)"
fi

SAFE_SITE="${SITE_ID//[^[:alnum:]_.-]/_}"
DEVICE_DATA_FILE="$TMP_DIR/devices.json"
CLIENT_DATA_FILE="$TMP_DIR/clients.json"
mkdir -p -- "$EXPORT_DIR"

for export_type in "${TYPES[@]}"; do
  if [[ -z "$OUTFILE" ]]; then
    OUTFILE="$EXPORT_DIR/Omada-${export_type}_${SAFE_SITE}.txt"
  elif [[ "$OUTFILE" != /* ]]; then
    OUTFILE="$EXPORT_DIR/$OUTFILE"
  fi
  mkdir -p -- "$(dirname -- "$OUTFILE")"
  echo "Fetching Omada $export_type for site '$SITE_ID' ..."
  if [[ "$export_type" == devices ]]; then
    fetch_pages "sites/$SITE_ID/devices" "$DEVICE_DATA_FILE"
    render_device_groups "$DEVICE_DATA_FILE" > "$OUTFILE"
  else
    if [[ ! -s "$DEVICE_DATA_FILE" ]]; then
      fetch_pages "sites/$SITE_ID/devices" "$DEVICE_DATA_FILE"
    fi
    fetch_pages "sites/$SITE_ID/clients" "$CLIENT_DATA_FILE"
    render_clients "$CLIENT_DATA_FILE" "$DEVICE_DATA_FILE" > "$OUTFILE"
  fi
  echo "Done. File generated: $OUTFILE"
  OUTFILE=""
done
