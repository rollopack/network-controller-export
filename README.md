# Network Controller Export

Export devices and active clients from Ubiquiti UniFi and TP-Link Omada controllers. Each controller has a standalone script and its own authentication flow.

## Common

### Requirements and installation

- Bash 4+
- [curl](https://curl.se/)
- [jq](https://jqlang.github.io/jq/)
- `column` (optional; without it, output is not aligned)

```bash
git clone https://github.com/rollopack/network-controller-export.git
cd network-controller-export
chmod +x unifi_export.sh omada_export.sh
```

### Shared options

| Flag | Argument | Description | Default |
|------|----------|-------------|---------|
| `-s` | `site` | Site ID; Omada also accepts the 1-based number in its site list | Prompt if omitted |
| `-o` | `file` | Output file; relative paths are saved under `exports/` | Controller-specific filename |
| `-O` | `ip` / `desc` | Sort by IP or description | `ip` |
| `-H` | — | Hide offline devices | Off |
| `-L` | — | Hide the `Connected to` column | Show by default |
| `-T` | `devices` / `clients` / `both` | Select export type | `devices` |
| `-V` | — | Show version | — |
| `-h` | — | Show help | — |

### Output

Both scripts write to the Git-ignored `exports/` directory by default. A relative path passed with `-o` is placed there too; an absolute path is used as given. Output is a text report with tab-separated columns, aligned with `column` when available. It can be imported into Excel, Google Sheets, or another spreadsheet application.

Device exports group rows under **Switches**, **Access Points**, and **Other devices**. Device columns are IP, MAC, Model, Description, and `Connected to`. Client exports contain IP, MAC, Vendor, Hostname, and `Connected to`. Use `-L` to omit the connection column; Omada omits it automatically when the API provides no connection details.

With `-T both`, each controller writes separate device and client reports. Here is a simplified UniFi-format example with illustrative values; Omada may omit `Connected to` when the API has no connection details.

**Devices report**

```text
...::: Switches :::...

IP           MAC                Model    Description  Connected to
192.0.2.10   02:00:00:00:00:10  USW-24   Core Switch

...::: Access Points :::...

IP           MAC                Model    Description  Connected to
192.0.2.11   02:00:00:00:00:11  U6-Lite  AP Lobby     Core Switch (port 7)
192.0.2.12   02:00:00:00:00:12  U7IW     AP Bar       Core Switch (port 8)
```

**Clients report**

```text
...::: Clients :::...

IP           MAC                Vendor          Hostname  Connected to
192.0.2.20   02:00:00:00:00:20  Example Vendor  laptop    AP Bar 
192.0.2.21   02:00:00:00:00:21  Example 2       tablet    AP Lobby
```


## UniFi

`unifi_export.sh` logs in to the controller API. It supports UniFi controllers, including UniFi OS; it does not support a cloud / ui.com account.

### Usage and options

```bash
./unifi_export.sh [options]
```

If `-s` is omitted, the script lists available sites for interactive selection. If no export type is configured or passed with `-T`, it asks whether to export devices, clients, or both.

| Flag | Argument | Description | Default |
|------|----------|-------------|---------|
| `-c` | `url` | Controller URL | `https://uos.unifi.net:11443` |
| `-u` | `username` | UniFi admin username (not a ui.com account) | `admin` |
| `-p` | `path` | API path prefix; use `-p ""` for a software controller without the proxy | `/proxy/network` |

### Configuration and examples

Copy the example to create the ignored local configuration file:

```bash
cp unifi.conf.example unifi.conf
```

It supports controller URL, site, username, API path, sorting, export type, filters, and an optional `PASSWORD`. The password is read from `unifi.conf` only when the file is owner-only (`chmod 600`). Otherwise, the script warns, ignores the configured password, and prompts interactively. A password is never accepted as a command-line argument.

```bash
# Interactive site and export selection
./unifi_export.sh

# Export devices from a UniFi OS controller
./unifi_export.sh -s abcdef12

# Software controller, clients only
./unifi_export.sh -s abcdef12 -p "" -T clients

# Export both datasets with a custom output name
./unifi_export.sh -s abcdef12 -T both -o my_export.txt
```

### UniFi details

- Login uses `POST /api/auth/login` on UniFi OS or `POST /api/login` on a software controller.
- The script fetches site, device, and client data from the controller API. With `-T both`, device data is reused for client-link resolution.
- Device and port details depend on fields returned by the controller; unavailable values may be blank or shown as `Wired` for clients.
- Tested with UniFi Network Controller v6 and v7, and UniFi OS (UDM, UCG).

## Omada

`omada_export.sh` uses the Omada Open API with Client Credentials authentication.

### Configuration and usage

Create the ignored local configuration file and restrict its permissions:

```bash
cp omada.conf.example omada.conf
chmod 600 omada.conf
```

Set the **Interface Access Address**, **Omada ID**, **Client ID**, and **Client Secret** from **Global View → Settings → Platform Integration → Open API**. `OMADA_SITE_ID` is optional. If unset, the script lists available sites; `-s` accepts either the site ID or its 1-based list number. Set `OMADA_INSECURE_TLS=true` only when the controller uses a self-signed certificate. If the filesystem cannot apply `chmod 600`, remove the secret from the file; the script warns and prompts for it.

```bash
./omada_export.sh [options]
./omada_export.sh -T both
./omada_export.sh -s <site_id_or_list_number> -T devices -O desc
```

The default files are `exports/Omada-devices_<site>.txt` and `exports/Omada-clients_<site>.txt`.

### Omada details

- The script requests an Open API access token, fetches sites and paginated device/client lists, then formats the output.
- `Connected to` is omitted when the API provides no connection details.
- API response and uplink fields vary by operation and controller release; verify them against the target controller.
- Authorization and site-list request formats follow TP-Link's [Open API access guide](https://support.omadanetworks.com/sg/document/109315/) and [Open API documentation](https://omada-northbound-docs.tplinkcloud.com/).

## Tests

Run the offline tests using mocked controller responses:

```bash
bash tests/test_export.sh
bash tests/test_omada_export.sh
```

## License

GNU General Public License v3.0

Copyright (C) 2026 Rolland Gabriel (https://github.com/rollopack)
