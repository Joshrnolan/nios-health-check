
# Infoblox NIOS Grid Health Check Script

> ### ⚠️ Important Disclaimer
>
> **This is NOT an officially supported Infoblox tool.**
>
> This script was developed as a personal project by an Infoblox Sales Engineer and is provided **as-is**, without warranty of any kind. It is not a product of Infoblox, Inc., and is **not covered by Infoblox Technical Support**.
>
> - Infoblox Support **will not** troubleshoot, debug, or provide assistance with this script.
> - Updates, fixes, and enhancements are **best-effort only** and not guaranteed.
> - Use of this script is entirely at your own discretion and risk.
> - Always review the script and test in a non-production environment before running against a production Grid.

---

## Overview

The **NIOS Grid Health Check** script is a lightweight, read-only utility that connects to an Infoblox NIOS Grid Manager and automatically collects the configuration and operational information typically gathered during a customer Health Check engagement.

Instead of clicking through the Grid Manager UI and manually copying values into a spreadsheet, this script uses the Infoblox NIOS **WAPI (Web API)** to pull the data in a single run and produce a clean, structured report you can review, share, or archive.

The script gathers information such as:

- Grid name, NIOS version, and Grid-wide licenses
- Grid member inventory (including HA pairs) with role, IP, model, and platform
- Installed licenses per physical node
- Enabled services and protocols (DNS, DHCP, NTP, TFTP, HTTP, etc.)
- DNS settings (views, nameserver groups, scavenging, query logging, DoH)
- DHCP settings (fingerprinting, lease logging, active IPv4 hosts)
- NIOS object counts, smart folders, and admin user counts
- Per-node CPU, memory, and disk utilization

## Why This Exists

Collecting Health Check data manually from a large Grid can take hours and is prone to transcription errors. This script was built as a personal side project by an Infoblox SE to **automate the data-gathering portion of the Health Check workflow**, so that engineers and customers can spend their time on analysis and recommendations instead of data entry.

It is intentionally **read-only** — it only performs `GET` calls against the WAPI and never modifies Grid configuration.

---

## Requirements

### System

- **Python**: 3.8 or newer
- **Operating system**: macOS, Linux, or Windows
- **Network access**: HTTPS (TCP/443) connectivity from the machine running the script to the Grid Manager

### NIOS / WAPI

- NIOS **8.x or 9.x** with the WAPI enabled (default)
- A Grid admin account with **read permissions** sufficient to query the WAPI
  - The built-in `admin` account works, but a dedicated read-only service account is recommended

### Python Dependencies

| Package      | Purpose                              | Required |
|--------------|--------------------------------------|----------|
| `requests`   | HTTPS calls to the WAPI              | Yes      |
| `urllib3`    | TLS warning suppression, retries     | Yes      |
| `openpyxl`   | Excel (`.xlsx`) report generation    | Optional (required only if you want Excel output) |

All other modules used (`argparse`, `csv`, `json`, `logging`, `hashlib`, `getpass`, etc.) are part of the Python standard library.

---

## Installation

### 1. Download the script

Save `nios_health_check_final.py` to a working directory on your local machine.

### 2. (Recommended) Create a Python virtual environment

```bash
python3 -m venv venv
source venv/bin/activate          # macOS / Linux
venv\Scripts\activate             # Windows (PowerShell / CMD)
```

### 3. Install the dependencies

```bash
pip install requests urllib3 openpyxl
```

If you only need CSV output, you can skip `openpyxl`:

```bash
pip install requests urllib3
```

### 4. Verify the installation

```bash
python nios_health_check_final.py --help
```

You should see a list of available command-line options.

---

## Usage

### Basic (interactive) run

Run the script with no arguments and it will prompt you for everything it needs:

```bash
python nios_health_check_final.py
```

You will be asked for:

1. Grid Manager IP or hostname
2. WAPI username
3. WAPI password (hidden input)
4. Whether to bypass TLS verification (only if your Grid uses a self-signed certificate)
5. Customer name
6. Employee count
7. Geographic region (`EMEA`, `AMS`, or `APJ`)
8. User/SE name

### Non-interactive run

Any prompt can be pre-filled via a command-line argument. This is useful for scheduled or scripted runs.

```bash
python nios_health_check_final.py \
    --grid-ip 10.10.10.10 \
    --username admin \
    --customer "Acme Corp" \
    --employees 2500 \
    --geo AMS \
    --user "Jane Doe" \
    --format both
```

> **Tip:** Omit `--password` on the command line and the script will prompt for it securely so it doesn't appear in your shell history.

### Command-line options

| Flag | Description |
|------|-------------|
| `--grid-ip` | Grid Manager IP address or hostname |
| `--username` | WAPI username |
| `--password` | WAPI password (prompted securely if omitted) |
| `--api-version` | Force a specific WAPI version (e.g., `v2.12`). Auto-detected by default |
| `--customer` | Customer name used in the report |
| `--employees` | Employee count (integer) |
| `--geo` | Region: `EMEA`, `AMS`, or `APJ` |
| `--user` | Name of the person running the Health Check |
| `--format` | Output format: `excel`, `csv`, or `both` (default) |
| `--log` | Custom log file name |
| `--insecure` | Bypass TLS certificate verification (self-signed certs) |
| `--silent-warnings` | Suppress TLS warning messages |
| `--debug` | Enable verbose debug logging |

---

## Outputs

The script creates a **timestamped output directory** in your current working directory, named like:

```
nios_health_audit_20260429_141530/
```

Inside, you'll find:

| File | Description |
|------|-------------|
| `nios_health_audit_<timestamp>.xlsx` | Excel report with one row per physical node and 43 columns of Health Check data |
| `nios_health_audit_<timestamp>.csv`  | Same data in CSV format |
| `nios_health_audit_<timestamp>.summary.json` | Run summary: Grid name, version, counts, customer info, SHA-256 hashes of each output file |
| `nios_health_audit_<timestamp>.log.jsonl` | Structured JSON-line log of the run |

Each row in the report represents a single physical node. For HA pairs, both the active and passive nodes are reported as separate rows, keyed by their hardware ID.

---

## How It Works (High-Level)

1. **Prompt & Connect** — The script collects the Grid IP, credentials, and customer context, then auto-detects the latest WAPI version supported by your Grid.
2. **Verify** — It performs a lightweight connectivity test before doing any real work.
3. **Collect** — Using a series of read-only WAPI calls, it gathers Grid identity, members, licenses, DNS/DHCP settings, object counts, and per-node performance metrics.
4. **Process** — For each Grid member, it walks through all associated nodes (including HA pairs), matches license records by hardware ID, and builds a structured row of data.
5. **Report** — It writes an Excel workbook, a CSV file, and a JSON summary (including SHA-256 hashes of each output file for integrity).
6. **Log Out** — It gracefully terminates the WAPI session.

The entire process is **read-only** — no `POST`, `PUT`, or `DELETE` calls are ever issued against your Grid.

---

## Assumptions & Limitations

- The script assumes the WAPI is reachable from the machine running it and that the supplied credentials have read access to the relevant objects.
- Auto-detection of the WAPI version requires access to `v1.0/?_schema`. If unavailable, it falls back to **v2.12**.
- Tested primarily against **NIOS 8.6+ and 9.x**. Older versions may behave differently or return 400 errors on certain fields.
- Some fields in the 43-column report (e.g., `Member QPS`, `Member LPS Total`, `Grid Enabled Feature`) are intentionally left blank — they are placeholders for data that is not directly exposed via WAPI or that is expected to be supplied from other sources.
- The script collects data only at the moment it runs — it is a **point-in-time snapshot**, not a continuous monitor.
- Large Grids with many members may take several minutes to complete due to per-member API calls.
- `Member QPS` and similar real-time metrics require Reporting/Analytics and are not populated in this version.
- Offline or unreachable members default to a role of **"Member"** and an empty IP rather than failing the run.

---

## Security Considerations

Because this script authenticates against a Grid with a privileged account, please follow these guidelines:

- **Use a dedicated service account** with the minimum read-only permissions required, rather than the Grid `admin` account when possible.
- **Do not hard-code credentials.** Pass the password via the interactive prompt, or supply it through environment-variable-driven wrappers if automating.
- **Avoid `--password` on the command line** when possible, as it can be captured in shell history or process listings.
- **Keep `--insecure` off in production.** Only use it for test labs with self-signed certificates. When used, TLS certificate validation is skipped, which exposes the session to potential man-in-the-middle attacks.
- **Protect the output directory.** The generated reports contain Grid topology, license inventory, and operational state — treat them as sensitive and store/share them accordingly.
- **Review the log files** before sharing. Logs are JSON-formatted and include endpoint names and counts, but not credentials or record contents.
- The script **logs out of its WAPI session** at the end of each run to free up the Grid's session slot.

---

## Troubleshooting

| Symptom | Likely Cause | Suggested Fix |
|--------|--------------|---------------|
| `Connectivity test failed` | Wrong credentials, network block, or TLS mismatch | Verify IP/hostname and credentials; try `--insecure` if the Grid uses a self-signed certificate |
| `TLS error on ...` | Self-signed or untrusted certificate | Re-run with `--insecure` (lab/test only) or install a trusted cert on the Grid |
| `openpyxl not installed — skipping Excel output` | `openpyxl` missing | `pip install openpyxl`, or use `--format csv` |
| `Could not auto-detect WAPI version` | Older NIOS that doesn't expose `v1.0/?_schema`, or network restriction | Supply `--api-version v2.12` (or another known-good version) |
| `GET <endpoint> returned 400/401/403` | Insufficient permissions on the account | Grant the account read access to the affected object, or use a Grid admin |
| Script hangs during member processing | Offline member or slow API response | Wait — the script retries transient errors. Re-run with `--debug` for more visibility |
| Empty output directory / "No data collected" | Connectivity failed after the prompt | Check the log file (`*.log.jsonl`) in the output directory for the underlying error |

For unresolved issues, enable verbose logging with `--debug` and inspect the generated `.log.jsonl` file.

---

## Customization & Extension

The script is structured as a single file with clearly labeled sections to make adjustments straightforward:

- **`HEADER_43`** — Change column names or add new fields to the report header.
- **`InfobloxClient`** — Add new read-only methods for additional WAPI endpoints you want to include (e.g., threat protection profiles, custom extensible attributes).
- **`collect_and_report()`** — Modify the orchestration logic to add or remove data collection steps.
- **`write_excel()` / `write_csv()`** — Adjust formatting, column widths, or add charts to the Excel output.
- **`ROLE_MAP`** — Extend role detection logic if your Grid uses custom role labels.

---

## Feedback

Because this is a personal project, improvements are welcome but best-effort. If you find a bug or have an idea, feel free to share it with the author, but please **do not open an Infoblox support case** for this script.
