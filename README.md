# UniFi Export

Export UniFi device inventory (APs, switches, gateways) or active clients from a UniFi controller to a tab-separated file.

## Requirements

- Bash 4+
- [curl](https://curl.se/)
- [jq](https://jqlang.github.io/jq/)
- `column` (from util-linux, usually pre-installed) — optional, falls back to raw TSV if missing

## Installation

```bash
curl -LO https://raw.githubusercontent.com/rollopack/unifi-site-devices/main/unifi_export.sh
chmod +x unifi_export.sh
```

## Usage

```bash
./unifi_export.sh [options]
```

If `-s` is omitted, the script shows an interactive list of available sites to choose from. In interactive mode, after selecting the site you are also asked what to export (Devices, Clients, or Both).

### Options

| Flag | Argument | Description | Default |
|------|----------|-------------|---------|
| `-c` | `url` | Controller URL (including port) | `https://controller.unifi.net:8443` |
| `-s` | `id` | Site ID | prompt interactively if omitted |
| `-u` | `username` | UniFi admin username (not ui.com account) | `admin` |
| `-o` | `file` | Output file path | `Unifi-<type>_<site>.txt` |
| `-O` | `ip` / `desc` | Sort order | `ip` |
| `-H` | — | Hide offline devices (state != 1) — devices only | Off (export all) |
| `-p` | `path` | API path prefix for UniFi OS (e.g. `/proxy/network`) | none |
| `-T` | `devices` / `clients` / `both` | Export type: devices, active clients, or both | `devices` |
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

# Export active clients
./unifi_export.sh -T clients

# Export both devices and clients
./unifi_export.sh -T both

# Using environment variables
export CONTROLLER=https://controller.unifi.net:8443
export SITE=abcdef12
export USER=admin
./unifi_export.sh
```

## Output

A tab-separated file, formatted with `column -t` when available for perfect alignment. The file can be opened in Excel, Google Sheets, or any spreadsheet tool (tab-delimited import).

**Devices** (`-T devices`, default): IP, MAC, Model, Description

```
...::: Devices :::...

IP               MAC                Model  Description
192.168.178.221  18:e8:29:45:6e:97  US8P60 Switch 1 | Rack
192.168.178.222  ac:8b:a9:ba:4c:0b  USF5P  Switch 2
192.168.178.231  f0:9f:c2:f0:3e:6c  U7LT   AP 1 | Salone
```

**Clients** (`-T clients`): IP, MAC, Vendor, Hostname, Connected to

```
...::: Clients :::...

IP               MAC                 Fornitore                            Hostname       Connesso a
192.168.1.100    78:8a:20:80:47:d1   Apple                                iPhone-Rosa    AP 1 | Salone
192.168.1.101    ac:8b:a9:ba:4c:0b   Intel                                PC-Mario       AP 2 | Camera 2
192.168.1.102    f0:9f:c2:f0:3e:6c   Samsung                              Galaxy-S25     AP 2 | Camera 2
192.168.1.103    00:19:cb:3e:96:0b   Zyxel Communications Corporation                    Wired
```

## How It Works

1. **Login** — authenticates to the controller via `POST /api/login`
2. **Fetch sites** — retrieves the list of available sites via `GET /api/self/sites` and validates that the requested site exists (or shows an interactive picker)
3. **Fetch data** — retrieves the appropriate list based on export type (devices via `GET /api/s/<site>/stat/device`; clients via `GET /api/s/<site>/stat/sta`). With `-T both` both endpoints are queried sequentially.
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
