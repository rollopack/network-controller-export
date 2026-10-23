#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$PROJECT_DIR/omada_export.sh"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin"

cat > "$TEST_TMP/bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
url=""
for arg in "$@"; do
  if [[ "$arg" == http* ]]; then url="$arg"; fi
done
case "$url" in
  */openapi/authorize/token\?grant_type=client_credentials)
    printf '{"errorCode":0,"result":{"accessToken":"mock-token","expiresIn":7200}}\n'
    ;;
  */openapi/v1/omada-1/sites\?*)
    printf '{"errorCode":0,"result":{"data":[{"siteId":"site-1","name":"Main Site"},{"siteId":"site-2","name":"Second Site"}]}}\n'
    ;;
  */openapi/v1/omada-1/sites/site-1/devices\?*|*/openapi/v1/omada-1/sites/site-2/devices\?*)
    cat <<'JSON'
{"errorCode":0,"result":{"data":[
  {"ip":"10.0.0.2","mac":"AA-BB-CC-00-00-01","model":"TL-SG3428","type":"switch","name":"Core Switch","status":1},
  {"ip":"10.0.0.1","mac":"AA-BB-CC-00-00-02","model":"EAP650","type":"ap","name":"AP Lobby","status":1,"uplinkDeviceName":"Core Switch","uplinkPort":8}
]}}
JSON
    ;;
  */openapi/v1/omada-1/sites/site-3/devices\?*)
    printf '{"errorCode":0,"result":{"data":[{"ip":"10.0.0.3","mac":"AA-BB-CC-00-00-03","model":"TL-SG3428","type":"switch","name":"Unlinked Switch","status":1}]}}\n'
    ;;
  */openapi/v1/omada-1/sites/site-1/clients\?*|*/openapi/v1/omada-1/sites/site-2/clients\?*)
    cat <<'JSON'
{"errorCode":0,"result":{"data":[
  {"ip":"10.0.0.20","mac":"DE-AD-BE-EF-00-01","name":"Desk","clientType":"wired","connectDevName":"Core Switch","connectDevPort":4},
  {"ip":"10.0.0.21","mac":"DE-AD-BE-EF-00-02","name":"Phone","wireless":true,"apName":"AP Lobby"}
]}}
JSON
    ;;
  */openapi/v1/omada-1/sites/site-3/clients\?*)
    printf '{"errorCode":0,"result":{"data":[{"ip":"10.0.0.30","mac":"DE-AD-BE-EF-00-03","name":"Unlinked Client"}]}}\n'
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

cat > "$TEST_TMP/omada.conf" <<'CONFIG'
OMADA_INTERFACE_ACCESS_ADDRESS=https://omada.example:8043
OMADA_ID=omada-1
OMADA_CLIENT_ID=test-client-id
OMADA_CLIENT_SECRET=mock-secret
OMADA_SITE_ID=
OMADA_INSECURE_TLS=true
CONFIG
chmod 600 "$TEST_TMP/omada.conf"

run_export() {
  (cd -- "$TEST_TMP" && printf '1\n' | EXPORT_DIR="$TEST_TMP/exports" OMADA_CONFIG_FILE="$TEST_TMP/omada.conf" PATH="$TEST_TMP/bin:$PATH" "$SCRIPT" -T both "$@" >/dev/null)
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
assert_contains "$TEST_TMP/exports/devices.tsv" 'Core Switch (port 8)'
assert_contains "$TEST_TMP/exports/Omada-clients_site-1.txt" 'Core Switch (port 4)'
assert_contains "$TEST_TMP/exports/Omada-clients_site-1.txt" 'AP Lobby'

run_export -s 2 -o second-devices.tsv
assert_contains "$TEST_TMP/exports/second-devices.tsv" '...::: Switches :::...'
assert_contains "$TEST_TMP/exports/Omada-clients_site-2.txt" 'Core Switch (port 4)'

run_export -L -o hidden-devices.tsv
if grep -Fq 'Connected to' "$TEST_TMP/exports/hidden-devices.tsv" || grep -Fq 'Connected to' "$TEST_TMP/exports/Omada-clients_site-1.txt"; then
  echo 'The -L option should hide the connection column in both exports' >&2
  exit 1
fi

run_export -s site-3 -o unlinked.tsv
if grep -Fq 'Connected to' "$TEST_TMP/exports/unlinked.tsv" || grep -Fq 'Connected to' "$TEST_TMP/exports/Omada-clients_site-3.txt"; then
  echo 'Omit the connection column when the API has no link data' >&2
  exit 1
fi

cat > "$TEST_TMP/omada-insecure.conf" <<'CONFIG'
OMADA_INTERFACE_ACCESS_ADDRESS=https://omada.example:8043
OMADA_ID=omada-1
OMADA_CLIENT_ID=test-client-id
OMADA_SITE_ID=site-1
OMADA_INSECURE_TLS=true
CONFIG
chmod 644 "$TEST_TMP/omada-insecure.conf"
(cd -- "$TEST_TMP" && printf 'mock-secret\n' | EXPORT_DIR="$TEST_TMP/warning-exports" OMADA_CONFIG_FILE="$TEST_TMP/omada-insecure.conf" PATH="$TEST_TMP/bin:$PATH" "$SCRIPT" -T clients -o clients.tsv >/dev/null 2>"$TEST_TMP/omada-warning.log")
grep -qi warning "$TEST_TMP/omada-warning.log"
assert_contains "$TEST_TMP/warning-exports/clients.tsv" 'Core Switch (port 4)'

printf 'All Omada export tests passed.\n'
