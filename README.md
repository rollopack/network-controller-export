# UniFi Export

Export UniFi network devices (APs, switches, gateways) or active clients from a UniFi controller to a tab-separated file. Optimized for **UniFi OS** (UDM, UCG, UXG) — also works with network controllers via `-p ""`.

## Requirements

- Bash 4+
- [curl](https://curl.se/)
- [jq](https://jqlang.github.io/jq/)
- `column` (from util-linux, usually pre-installed) — optional, falls back to raw TSV if missing

## Installation

```bash
curl -LO https://raw.githubusercontent.com/rollopack/unifi-network-export/main/unifi_export.sh
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
| `-c` | `url` | Controller URL | `https://uos.unifi.net:11443` |
| `-s` | `id` | Site ID | prompt interactively if omitted |
| `-u` | `username` | UniFi admin username (not ui.com account) | `admin` |
| `-o` | `file` | Output file path | `Unifi-<type>_<site>.txt` |
| `-O` | `ip` / `desc` | Sort order | `ip` |
| `-H` | — | Hide offline devices (state != 1) — devices only | Off (export all) |
| `-L` | — | Hide the `Connected to` column in device and client exports | Show |
| `-p` | `path` | API path prefix. Default `/proxy/network` for UniFi OS. Use `-p ""` for software controller (no proxy) | `/proxy/network` |
| `-T` | `devices` / `clients` / `both` | Export type: devices, active clients, or both | `devices` |
| `-V` | — | Show version | — |
| `-h` | — | Show help | — |

Password is prompted interactively. It is never accepted as a command-line argument.

### Examples

```bash
# Interactive site selection (UniFi OS assumed by default)
./unifi_export.sh

# UniFi OS (default, proxy auto-detected)
./unifi_export.sh -s abcdef12

# Software controller (disable proxy)
./unifi_export.sh -s abcdef12 -p ""

# Full options on UniFi OS
./unifi_export.sh \
  -c https://192.168.1.1 \
  -s abcdef12 \
  -u admin \
  -o my_devices.txt \
  -O desc \
  -H

# Network controller API at custom URL
./unifi_export.sh \
  -c https://controller.local:8443 \
  -s abcdef12 \
  -p ""

# Export active clients
./unifi_export.sh -T clients

# Export both devices and clients
./unifi_export.sh -T both

# Using environment variables
export CONTROLLER=https://192.168.1.1
export SITE=abcdef12
export USER=admin
./unifi_export.sh
```

## Output

A tab-separated file, formatted with `column -t` when available for perfect alignment. The file can be opened in Excel, Google Sheets, or any spreadsheet tool (tab-delimited import).

**Devices** (`-T devices`, default): devices are listed under separate **Switches**, **Access Points**, and **Other devices** headings. Each section has IP, MAC, Model, Description, and Connected to columns; `-O` controls sorting within each section.

```
...::: Switches :::...

IP               MAC                Model  Description       Connected to
192.168.178.221  18:e8:29:45:6e:97  US8P60 Switch 1 | Rack
192.168.178.222  ac:8b:a9:ba:4c:0b  USF5P  Switch 2

...::: Access Points :::...

IP               MAC                Model  Description       Connected to
192.168.178.231  f0:9f:c2:f0:3e:6c  U7LT   AP 1              Switch 1 | Rack (port 8)
192.168.178.232  24:a4:3c:0c:8b:03  BZ2    AP 5 | Garage     Switch 2 (port 3)
```

**Clients** (`-T clients`): IP, MAC, Vendor, Hostname, Connected to

```
...::: Clients :::...

IP             MAC                Vendor                                Hostname           Connected to
192.168.1.115  c0:e7:bf:da:3e:0a  Sichuan AI-Link Technology Co., Ltd.                     Switch 1 | Rack (port 4)
192.168.1.116  d8:fb:d6:9d:e9:76  Amazon Technologies Inc.                                 Switch 2 (port 7)
192.168.1.143  7c:88:99:e6:26:99  FN-LINK TECHNOLOGY Ltd.                                  AP 1
192.168.1.154  0a:8a:f1:06:c7:14                                        ME30               Wired
192.168.1.171  30:a9:de:50:30:fa  LG Innotek                            LGwebOSTV          Wired
```

## How It Works

1. **Login** — authenticates to the controller via `POST /api/auth/login` (UniFi OS) or `POST /api/login` (software controller)
2. **Fetch sites** — retrieves the list of available sites via `GET /api/self/sites` through the proxy path (auto-detects direct path as fallback)
3. **Fetch data** — retrieves the appropriate list based on export type (devices via `GET /api/s/<site>/stat/device`; clients via `GET /api/s/<site>/stat/sta`). Client exports also use device uplink data to resolve wired clients' switch names. With `-T both`, device data is reused.
4. **Filter & sort** — optionally filters out offline devices, sorts by IP or name
5. **Write output** — writes a TSV file to disk, formatted with `column -t` when available

## Security

- Password is read via `read -s` (never echoed, never in process list)
- Cookie file is written to `mktemp` and deleted on exit
- No credentials are stored on disk
- The script does **not** support passing the password as a command-line argument (avoiding shell history leaks)

## Limitations

- Works with UniFi controllers (not cloud / ui.com)
- Tested with UniFi Network Controller v6, v7, and UniFi OS (UDM, UCG)
- Switch and port details depend on the fields returned by the controller; they may be blank (devices) or show `Wired` (clients) if unavailable.

## Tests

Run the offline export tests with mocked controller responses:

```bash
bash tests/test_export.sh
```

## License

GNU General Public License v3.0

Copyright (C) 2026 Rolland Gabriel (https://github.com/rollopack)
