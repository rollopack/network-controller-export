# UniFi Device Export

Export UniFi device inventory (APs, switches, gateways) from a UniFi controller to a tab-separated file.

## Requirements

- Bash 4+
- [curl](https://curl.se/)
- [jq](https://jqlang.github.io/jq/)

## Installation

```bash
curl -LO https://raw.githubusercontent.com/rollopack/unifi-site-devices/main/unifi_export.sh
chmod +x unifi_export.sh
```

## Usage

```bash
./unifi_export.sh [options]
```

If `-s` is omitted, the script shows an interactive list of available sites to choose from.

### Options

| Flag | Argument | Description | Default |
|------|----------|-------------|---------|
| `-c` | `url` | Controller URL (including port) | `https://controller.unifi.net:8443` |
| `-s` | `id` | Site ID | prompt interactively if omitted |
| `-u` | `username` | UniFi admin username (not ui.com account) | `admin` |
| `-o` | `file` | Output file path | `Unifi-devices_<site>.txt` |
| `-O` | `ip` / `desc` | Sort order | `ip` |
| `-H` | — | Hide offline devices (state != 1) | Off (export all) |
| `-p` | `path` | API path prefix for UniFi OS (e.g. `/proxy/network`) | none |
| `-V` | — | Show version | — |
| `-h` | — | Show help | — |

Password is prompted interactively. It is never accepted as a command-line argument.

### Examples

```bash
# Interactive site selection
./unifi_export.sh

# Specify site directly
./unifi_export.sh -s abcdef12

# Full options
./unifi_export.sh \
  -c https://controller.unifi.net:8443 \
  -s abcdef12 \
  -u admin \
  -o my_devices.txt \
  -O desc \
  -H

# UniFi OS (UDM-Pro, UXG) with proxy path
./unifi_export.sh -s abcdef12 -p /proxy/network

# Using environment variables
export CONTROLLER=https://controller.unifi.net:8443
export SITE=abcdef12
export USER=admin
./unifi_export.sh
```

## Output

A tab-separated file with IP, MAC, Model, and Description columns:

```
...::: Devices :::...

IP              MAC                Model  Description
192.168.178.221 18:e8:29:45:6e:97  US8P60 Switch 1 | Rack
192.168.178.222 ac:8b:a9:ba:4c:0b  USF5P  Switch 2
192.168.178.231 f0:9f:c2:f0:3e:6c  U7LT   AP 1 | Reception
192.168.178.232 78:45:58:1c:57:94  U7IW   AP 2 | Room 2
192.168.178.233 70:a7:41:8c:84:c2  U7IW   AP 3 | Room 4
192.168.178.234 70:a7:41:8c:82:fa  U7IW   AP 4 | Room 6
192.168.178.235 70:a7:41:8c:83:16  U7IW   AP 5 | Room 8
192.168.178.236 70:a7:41:8c:85:2f  U7IW   AP 6 | Room Elena
```

The file can be opened in Excel, Google Sheets, or any spreadsheet tool (tab-delimited).

## How It Works

1. **Login** — authenticates to the controller via `POST /api/login`
2. **Fetch sites** — retrieves the list of available sites via `GET /api/self/sites` and validates that the requested site exists (or shows an interactive picker)
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

- Works with UniFi controllers (not cloud / ui.com)
- The `-p` option for UniFi OS (UDM-Pro, UXG) proxy-based API paths is provided **but has not been tested**. The default endpoint is `/api/s/<site>/stat/device`.
- Tested with UniFi Network Controller v6 and v7

## License

GNU General Public License v3.0

Copyright (C) 2026 Rolland Gabriel (https://github.com/rollopack)
