#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/unifi_export.sh"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin"

cat > "$TEST_TMP/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
url=""
body=""
for arg in "$@"; do
  if [[ "$arg" == http* ]]; then
    url="$arg"
  fi
done
for ((arg_index = 1; arg_index < $#+1; arg_index++)); do
  arg="${!arg_index}"
  if [[ "$arg" == -d || "$arg" == --data || "$arg" == --data-binary ]]; then
    next_index=$((arg_index + 1))
    body="${!next_index}"
    break
  fi
done
case "$url" in
  */api/auth/login|*/api/login)
    if [[ -n "${EXPECT_PASSWORD:-}" ]]; then
      if [[ "$body" == @- ]]; then
        body="$(cat)"
      elif [[ "$body" == @* ]]; then
        body="$(cat "${body#@}")"
      fi
      jq -e --arg expected "$EXPECT_PASSWORD" '.password == $expected' <<< "$body" >/dev/null || {
        echo 'The password configured for the test was not used.' >&2
        exit 1
      }
    fi
    printf '{"meta":{"rc":"ok"}}\n'
    ;;
  */api/self/sites)
    printf '{"meta":{"rc":"ok"},"data":[{"name":"site1","desc":"Test"}]}\n'
    ;;
  */api/s/site1/stat/device)
    printf '{"meta":{"rc":"ok"},"data":[\n'
    printf '{"ip":"10.0.0.2","mac":"aa:bb:cc:dd:ee:01","model":"USW","type":"usw","name":"Core Switch","state":1,"padding":"'
    head -c 140000 /dev/zero | tr '\0' 'x'
    printf '"},\n'
    printf '{"ip":"10.0.0.1","mac":"aa:bb:cc:dd:ee:02","model":"U6","type":"uap","name":"AP Lobby","state":1,"uplink":{"uplink_mac":"aa:bb:cc:dd:ee:01","uplink_remote_port":7}}\n]}'
    ;;
  */api/s/site1/stat/sta)
    cat <<'JSON'
{"meta":{"rc":"ok"},"data":[
  {"ip":"10.0.0.20","mac":"de:ad:be:ef:00:01","oui":"Example","hostname":"Desk",
   "wired":true,"sw_mac":"aa:bb:cc:dd:ee:01","sw_port":4},
  {"ip":"10.0.0.21","mac":"de:ad:be:ef:00:02","oui":"Example","hostname":"Phone",
   "ap_name":"AP Lobby"}
]}
JSON
    ;;
  *)
    printf 'Unexpected URL: %s\n' "$url" >&2
    exit 1
    ;;
esac
MOCK_CURL
cat > "$TEST_TMP/bin/column" <<'MOCK_COLUMN'
#!/usr/bin/env bash
cat
MOCK_COLUMN
chmod +x "$TEST_TMP/bin/curl" "$TEST_TMP/bin/column"

run_export() {
  (cd -- "$TEST_TMP" && printf 'x\n' | USER=admin UNIFI_CONFIG_FILE="$TEST_TMP/missing-unifi.conf" EXPORT_DIR="$TEST_TMP/exports" PATH="$TEST_TMP/bin:$PATH" "$SCRIPT" -s site1 -T both "$@" >/dev/null)
}

assert_contains() {
  if ! grep -Fq -- "$2" "$1"; then
    printf 'Expected to find %q in %s; actual contents:\n' "$2" "$1" >&2
    cat "$1" >&2
    exit 1
  fi
}

run_export -o devices.tsv
assert_contains "$TEST_TMP/exports/devices.tsv" '...::: Switches :::...'
assert_contains "$TEST_TMP/exports/devices.tsv" '...::: Access Points :::...'
assert_contains "$TEST_TMP/exports/devices.tsv" $'IP\tMAC\tModel\tDescription\tConnected to'
if grep -Fq $'IP\tMAC\tModel\tType\t' "$TEST_TMP/exports/devices.tsv"; then
  echo 'Device type should be shown as section headings, not a column' >&2
  exit 1
fi
assert_contains "$TEST_TMP/exports/devices.tsv" 'Core Switch (port 7)'
switch_title_line="$(grep -nF '...::: Switches :::...' "$TEST_TMP/exports/devices.tsv" | cut -d: -f1)"
ap_title_line="$(grep -nF '...::: Access Points :::...' "$TEST_TMP/exports/devices.tsv" | cut -d: -f1)"
((switch_title_line < ap_title_line))
assert_contains "$TEST_TMP/exports/Unifi-clients_site1.txt" 'Core Switch (port 4)'
assert_contains "$TEST_TMP/exports/Unifi-clients_site1.txt" 'AP Lobby'

run_export -T clients -o clients-only.tsv
assert_contains "$TEST_TMP/exports/clients-only.tsv" 'Core Switch (port 4)'

run_export -L -o hidden-devices.tsv
if grep -Fq 'Connected to' "$TEST_TMP/exports/hidden-devices.tsv" || grep -Fq 'Connected to' "$TEST_TMP/exports/Unifi-clients_site1.txt"; then
  echo 'The -L option should hide the connection column in both exports' >&2
  exit 1
fi

cat > "$TEST_TMP/unifi.conf" <<'CONFIG'
CONTROLLER=https://controller.example
SITE=site1
USER=admin
API_PATH=/proxy/network
EXPORT_TYPE=both
SORT=ip
HIDE_OFFLINE=false
HIDE_LINK_COLUMN=false
CONFIG
chmod 644 "$TEST_TMP/unifi.conf"
(cd -- "$TEST_TMP" && printf 'x\n' | USER=admin EXPORT_DIR="$TEST_TMP/config-exports" UNIFI_CONFIG_FILE="$TEST_TMP/unifi.conf" PATH="$TEST_TMP/bin:$PATH" "$SCRIPT" >/dev/null 2>"$TEST_TMP/unifi-config-warning.log")
grep -qi warning "$TEST_TMP/unifi-config-warning.log"
assert_contains "$TEST_TMP/config-exports/Unifi-devices_site1.txt" '...::: Switches :::...'
assert_contains "$TEST_TMP/config-exports/Unifi-clients_site1.txt" 'Core Switch (port 4)'

cat > "$TEST_TMP/unifi-secure.conf" <<'CONFIG'
CONTROLLER=https://controller.example
SITE=site1
USER=admin
API_PATH=/proxy/network
EXPORT_TYPE=both
PASSWORD=config-test-value
CONFIG
chmod 600 "$TEST_TMP/unifi-secure.conf"
(cd -- "$TEST_TMP" && EXPECT_PASSWORD=config-test-value USER=admin UNIFI_CONFIG_FILE="$TEST_TMP/unifi-secure.conf" EXPORT_DIR="$TEST_TMP/secure-exports" PATH="$TEST_TMP/bin:$PATH" "$SCRIPT" >/dev/null)
assert_contains "$TEST_TMP/secure-exports/Unifi-devices_site1.txt" '...::: Switches :::...'

cat > "$TEST_TMP/unifi-insecure-password.conf" <<'CONFIG'
CONTROLLER=https://controller.example
SITE=site1
USER=admin
API_PATH=/proxy/network
EXPORT_TYPE=devices
PASSWORD=ignored-config-value
CONFIG
chmod 644 "$TEST_TMP/unifi-insecure-password.conf"
(cd -- "$TEST_TMP" && printf 'interactive-test-value\n' | EXPECT_PASSWORD=interactive-test-value USER=admin UNIFI_CONFIG_FILE="$TEST_TMP/unifi-insecure-password.conf" EXPORT_DIR="$TEST_TMP/insecure-exports" PATH="$TEST_TMP/bin:$PATH" "$SCRIPT" >/dev/null 2>"$TEST_TMP/unifi-insecure-warning.log")
grep -qi warning "$TEST_TMP/unifi-insecure-warning.log"
assert_contains "$TEST_TMP/insecure-exports/Unifi-devices_site1.txt" '...::: Switches :::...'

printf 'All export tests passed.\n'
