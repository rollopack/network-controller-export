# UniFi Device Export

Export UniFi device inventory (APs, switches, gateways) from a local UniFi controller to a tab-separated file.

## Requirements

- Bash 4+
- [curl](https://curl.se/)
- [jq](https://jqlang.github.io/jq/)

## Installation

```bash
curl -LO https://raw.githubusercontent.com/<user>/unifi-site-devices/main/unifi_export.sh
chmod +x unifi_export.sh
```

## Usage

```bash
./unifi_export.sh -c <controller_url> -s <site_id> -u <username> [options]
```

### Options

| Flag | Argument | Description | Default |
|------|----------|-------------|---------|
| `-c` | `url` | Controller URL (including port) | `https://controller.local:8443` |
| `-s` | `id` | Site ID (from UniFi URL after `/manage/`) | `default` |
| `-u` | `username` | Local UniFi admin username (not ui.com account) | `admin` |
| `-o` | `file` | Output file path | `Unifi-devices_<site>.txt` |
| `-O` | `ip` / `desc` | Sort order | `ip` |
| `-H` | — | Hide offline devices (state != 1) | Off (export all) |
| `-h` | — | Show help | — |

Password is prompted interactively. It is never accepted as a command-line argument.

### Examples

```bash
# Minimal — uses all defaults except site
./unifi_export.sh -s default

# Full options
./unifi_export.sh \
  -c https://192.168.1.1:8443 \
  -s abcdef12 \
  -u admin \
  -o my_devices.txt \
  -O desc \
  -H

# Using environment variables
export CONTROLLER=https://192.168.1.1:8443
export SITE=abcdef12
export USER=admin
./unifi_export.sh
```

## Output

A tab-separated file with the following columns:

```
...::: Devices :::...

IP              MAC                 Description
192.168.1.100   78:8a:20:80:47:d1   AP Camere
192.168.1.101   78:8a:20:b3:f1:cf   AP Mesh Esterno
```

The file can be opened in Excel, Google Sheets, or any spreadsheet tool (tab-delimited).

## How It Works

1. **Login** — authenticates to the controller via `POST /api/login`
2. **Fetch sites** — retrieves the list of available sites via `GET /api/self/sites` and validates that the requested site exists
3. **Fetch devices** — retrieves device list for the validated site via `GET /api/s/<site>/stat/device`
4. **Filter & sort** — optionally filters out offline devices, sorts by IP or name
5. **Write output** — writes a TSV file to disk

The session cookie is stored in a temporary file and cleaned up on exit via `trap`.

## Security

- Password is read via `read -s` (never echoed, never in process list)
- Cookie file is written to `mktemp` and deleted on exit
- No credentials are stored on disk
- The script does **not** support passing the password as a command-line argument (avoiding shell history leaks)

## Limitations

- Works with **local** UniFi controllers (not cloud / ui.com)
- Does **not** support UniFi OS (UDM-Pro, UXG) proxy-based API paths — the endpoint is `/api/s/<site>/stat/device`
- Tested with UniFi Network Controller v6 and v7

## License

MIT
