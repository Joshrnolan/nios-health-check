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

The core Health Check report gathers information such as:

- Grid name, NIOS version, and Grid-wide licenses
- Grid **UUID** (or License UID on older NIOS) for unique Grid identification
- Grid member inventory (including HA pairs) with role, model, and platform
- Optional per-member IPv4 addresses (opt-in at runtime)
- Installed licenses per physical node
- Enabled services and protocols (DNS, DHCP, NTP, TFTP, HTTP, etc.)
- DNS settings (views, nameserver groups, scavenging, query logging, DoH)
- DHCP settings (fingerprinting, lease logging, active IPv4 hosts)
- NIOS object counts, smart folders, and admin user counts
- Per-node CPU, memory, and disk utilization

On top of that core report, two **optional, opt-in add-on reports** are available — see [Optional Add-On Reports](#optional-add-on-reports) below.

## Why This Exists

Collecting Health Check data manually from a large Grid can take hours and is prone to transcription errors. This script was built as a personal side project by an Infoblox SE to **automate the data-gathering portion of the Health Check workflow**, so that engineers and customers can spend their time on analysis and recommendations instead of data entry.

It is intentionally **read-only** — it only performs `GET` calls against the WAPI, with the single exception of a `logout` call at the end of a run that simply releases the session token. No object is ever created, modified, or deleted on the Grid.

---

## Optional Add-On Reports

The script ships as a **single file** with two clearly-labeled, optional sections that reuse the same authenticated WAPI session as the core Health Check — no second login, no extra credentials, and neither one ever touches the core report's output files.

### Grid Member Capacity Report (`--capacity-report`)

Collects per-member database object counts and utilization directly from the `capacityreport` WAPI object, then writes a **separate** Excel workbook (`<run>_grid_capacity.xlsx`) with two sheets:

- **Capacity Summary** — one row per physical node, with hardware type, max capacity, total objects, percent used, and estimated DDI vs. Active-IP object counts.
- **Object Counts** — a full per-member breakdown of every WAPI object type.

This section is adapted from **nios_grid_capacity.py** by Pat Vogelsang (MIT License) — see [License & Attribution](#license--attribution).

### DNS Topology Visualization (`--topology-viz`)

Collects authoritative, delegated, forward, and stub zones, plus Name Server Groups, external name servers, and Response Policy Zones (`zone_rp`), and renders them into a **self-contained, static HTML file** (`<run>_topology.html`) showing the full primary/secondary/forwarder/delegated/stub/NSG relationship graph.

The file has no server component — open it in any browser. The only remote resource it references is the [ECharts](https://echarts.apache.org/) charting library from a public CDN (`cdn.jsdelivr.net`), loaded by the browser only when the generated HTML file is opened; the Python script itself never fetches or executes it.

This section is adapted from **ddi_collect.py / ddi_dashboard.html** (part of the NIOS DDI Dashboard tool) by Bobby Cooper (MIT License) — see [License & Attribution](#license--attribution).

Both add-ons default to **OFF** and can be triggered interactively or via CLI flags — see [Command-line options](#command-line-options).

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
| `openpyxl`   | Excel (`.xlsx`) report generation (core report **and** the optional Capacity Report) | Optional (required only if you want Excel output) |

All other modules used (`argparse`, `csv`, `json`, `logging`, `hashlib`, `getpass`, etc.) are part of the Python standard library.

---

## Installation

### 1. Download the script

Save `nios_health_check.py` to a working directory on your local machine.

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
python nios_health_check.py --help
```

You should see a list of available command-line options.

---

## Usage

### Basic (interactive) run

Run the script with no arguments and it will prompt you for everything it needs:

```bash
python nios_health_check.py
```

You will be asked for:

1. Grid Manager IP or hostname
2. WAPI username
3. WAPI password (hidden input)
4. Whether to bypass TLS verification (only if your Grid uses a self-signed certificate)
5. Whether to **include Member IP Addresses in the output**
6. Whether to include the **Grid Member Database Capacity Report**
7. Whether to include the **DNS Topology Visualization**
8. Customer name
9. Employee count
10. Geographic region (`EMEA`, `AMS`, or `APJ`)
11. User/SE name

### Member IP Address opt-in

By default the report does **not** include per-member IPv4 addresses. At runtime you'll see:

```
Include Member IP Addresses in output (y/n) [n]:
```

Answer `y` / `yes` and the script populates **column F ("Member IP")** using a **3-tier fallback**, evaluated in this order:

1. `member:dns?_return_fields=host_name,ipv4addr` — primary source, but only returns an entry for members that run the DNS service.
2. `member.vip_setting` — the member's base management IP; exists for **every** Grid member regardless of which services it runs, so it correctly fills in members that don't run DNS (e.g. Reporting appliances / IB-V5005, Network Insight / Discovery appliances / ND-V906).
3. `capacityreport._ref` — legacy fallback, retained for edge cases where the first two sources are empty.

If all three sources come back empty for a member, it's logged as a **WARNING** in the run log so the gap is visible rather than silent.

Answer `n` (or press Enter) and column F is left blank. All other columns are unaffected.

You can also skip the prompt by passing one of:

```bash
--include-ip        # force-include IPs (no prompt)
--no-include-ip     # force-exclude IPs (no prompt)
```

### Optional add-on reports

The Capacity Report and Topology Visualization each follow the same "prompt unless flagged" pattern as Member IP:

```
Include Grid Member Database Capacity report (y/n) [n]:
Include DNS Topology Visualization (y/n) [n]:
```

Skip either prompt with:

```bash
--capacity-report / --no-capacity-report
--topology-viz    / --no-topology-viz
```

### Non-interactive run

Any prompt can be pre-filled via a command-line argument. This is useful for scheduled or scripted runs.

```bash
python nios_health_check.py \
    --grid-ip 10.10.10.10 \
    --username admin \
    --customer "Acme Corp" \
    --employees 2500 \
    --geo AMS \
    --user "Jane Doe" \
    --include-ip \
    --capacity-report \
    --topology-viz \
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
| `--include-ip` | Include Member IP addresses in column F (skips the interactive IP prompt) |
| `--no-include-ip` | Exclude Member IP addresses (skips the interactive IP prompt) |
| `--capacity-report` | Generate the Grid Member Capacity Excel Report. Skips the interactive prompt. |
| `--no-capacity-report` | Skip the Grid Member Capacity Report and its interactive prompt. |
| `--topology-viz` | Generate a self-contained DNS Topology Visualization HTML file showing primary/secondary/forwarder/delegated/stub/NSG relationships. |
| `--no-topology-viz` | Skip the DNS Topology Visualization and its interactive prompt. |
| `--debug` | Enable verbose debug logging |

---

## Outputs

The script creates a **timestamped output directory** in your current working directory, named like:

```
nios_health_audit_20260429_141530/
```

Inside, you'll always find the core Health Check report:

| File | Description |
|------|-------------|
| `nios_health_audit_<timestamp>.xlsx` | Excel report with one row per physical node and 43 columns of Health Check data |
| `nios_health_audit_<timestamp>.csv`  | Same data in CSV format |
| `nios_health_audit_<timestamp>.summary.json` | Run summary: Grid name, version, Grid UUID, IP-inclusion choice, counts, customer info, SHA-256 hashes of each output file |
| `nios_health_audit_<timestamp>.log.jsonl` | Structured JSON-line log of the run |

If you enabled the optional add-ons, you'll also find:

| File | Description |
|------|-------------|
| `nios_health_audit_<timestamp>_grid_capacity.xlsx` | Only written when `--capacity-report` (or its prompt) is enabled. "Capacity Summary" and "Object Counts" sheets — see [Optional Add-On Reports](#optional-add-on-reports) |
| `nios_health_audit_<timestamp>_topology.html` | Only written when `--topology-viz` (or its prompt) is enabled. Self-contained, browser-openable DNS relationship map |

Both add-on files are written alongside the core report in the same directory and never modify it.

Each row in the core report represents a single physical node. For HA pairs, both the active and passive nodes are reported as separate rows, keyed by their hardware ID.

### Column C — `grid_uuid`

Column C is always labeled **`grid_uuid`**, but its source depends on the WAPI version detected on the Grid:

| WAPI version | NIOS version | Column C source |
|---|---|---|
| **v2.14 or newer** | **9.1.0+** | `grid.uuid` (native Grid UUID) |
| **v2.13 or older** | **≤ 9.0.8** | `grid:license_pool_container.lpc_uid` (License UID fallback — the closest stable per-Grid identifier available pre-9.1.0) |
| Lookup failed | — | `"na"` |

The version check and endpoint selection are handled automatically — no flags or manual intervention required.

---

## How It Works (High-Level)

1. **Prompt & Connect** — The script collects the Grid IP, credentials, TLS preference, the IP-inclusion choice, and the two add-on toggles (Capacity Report / Topology Visualization), plus customer context; then auto-detects the latest WAPI version supported by your Grid.
2. **Verify** — It performs a lightweight connectivity test before doing any real work.
3. **Collect** — Using a series of read-only WAPI calls, it gathers Grid identity, Grid UUID (or License UID fallback), members, licenses, DNS/DHCP settings, object counts, and per-node performance metrics. If you opted in to Member IPs, it resolves column F via the 3-tier `member:dns` → `member.vip_setting` → `capacityreport._ref` fallback. If enabled, it also collects per-member capacity data (Section 2) and zone/name-server/NSG/RPZ data (Section 3), all on the same authenticated session.
4. **Process** — For each Grid member, it walks through all associated nodes (including HA pairs), matches license records by hardware ID, and builds a structured row of data.
5. **Report** — It writes the core Excel workbook, CSV file, and JSON summary (including SHA-256 hashes of each output file for integrity), plus the standalone Capacity workbook and/or Topology HTML file if requested.
6. **Log Out** — It gracefully terminates the WAPI session.

The entire process is **read-only** — no `POST`, `PUT`, or `DELETE` calls are ever issued against your Grid (the only `POST` is the final `logout` call, which simply releases the session token).

---

## Assumptions & Limitations

- The script assumes the WAPI is reachable from the machine running it and that the supplied credentials have read access to the relevant objects.
- Auto-detection of the WAPI version requires access to `v1.0/?_schema`. If unavailable, it falls back to **v2.12**.
- Tested primarily against **NIOS 8.6+ and 9.x**. Older versions may behave differently or return 400 errors on certain fields.
- **Grid UUID** is only natively available on NIOS 9.1.0+ (WAPI v2.14+). On older Grids the script transparently falls back to the License UID (`lpc_uid`) and stores it in the same `grid_uuid` column; the column header is unchanged so downstream tooling doesn't need to branch.
- **Member IP addresses are opt-in.** By default column F is blank; it is populated only when `--include-ip` is passed or the interactive prompt is answered with `y`, via the `member:dns` → `member.vip_setting` → `capacityreport._ref` fallback chain. Members where all three sources are empty are logged as a warning rather than failing the run.
- Some fields in the 43-column report (e.g., `Member QPS`, `Member LPS Total`, `Grid Enabled Feature`) are intentionally left blank — they are placeholders for data that is not directly exposed via WAPI or that is expected to be supplied from other sources.
- The script collects data only at the moment it runs — it is a **point-in-time snapshot**, not a continuous monitor.
- Large Grids with many members may take several minutes to complete due to per-member API calls; enabling both add-on reports adds additional read-only calls on top of the core collection.
- `Member QPS` and similar real-time metrics require Reporting/Analytics and are not populated in this version.
- Offline or unreachable members default to a role of **"Member"** and an empty IP rather than failing the run.
- The Topology Visualization's HTML output loads the ECharts charting library from a public CDN when opened in a browser; review `TOPOLOGY_HTML_TEMPLATE` in the script directly if your policy requires vetting that beforehand.

---

## Security Considerations

Because this script authenticates against a Grid with a privileged account, please follow these guidelines:

- **Use a dedicated service account** with the minimum read-only permissions required, rather than the Grid `admin` account when possible.
- **Do not hard-code credentials.** Pass the password via the interactive prompt, or supply it through environment-variable-driven wrappers if automating.
- **Avoid `--password` on the command line** when possible, as it can be captured in shell history or process listings.
- **Keep `--insecure` off in production.** Only use it for test labs with self-signed certificates. When used, TLS certificate validation is skipped, which exposes the session to potential man-in-the-middle attacks.
- **Be deliberate with `--include-ip`.** Member IP addresses are topology data. Only include them when the downstream consumer of the report needs them, and handle the resulting file accordingly.
- **Protect the output directory.** The generated reports — including the optional Capacity workbook and Topology HTML file — contain Grid topology, license inventory, and operational state; treat them as sensitive and store/share them accordingly.
- **Review the log files** before sharing. Logs are JSON-formatted and include endpoint names and counts, but not credentials or record contents.
- **The Topology HTML file loads a public CDN script (ECharts) in the browser** when opened. No credentials or data leave the machine opening it beyond that one CDN request; review the network policy of the environment where you'll open it if that matters to you.
- The script **logs out of its WAPI session** at the end of each run to free up the Grid's session slot.

---

## License & Attribution

This project is licensed under the **MIT License** — see [`LICENSE.txt`](LICENSE.txt).

The optional Section 2 (Grid Member Capacity Report) and Section 3 (DNS Topology Visualization) adapt logic from two other MIT-licensed open-source projects:

| Section | Adapted from | Author |
|---|---|---|
| Grid Member Capacity Report | [nios_grid_capacity.py](https://github.com/pvogelsang67/nios_grid_capacity) | Pat Vogelsang |
| DNS Topology Visualization | [NIOS-DDI-Dashboard](https://github.com/robdcooper/NIOS-DDI-Dashboard) (`ddi_collect.py` / `ddi_dashboard.html`) | Bobby Cooper |

Per the MIT license terms, their original copyright and permission notices are reproduced in full in [`NOTICE.md`](NOTICE.md), along with what was reused from each project. If you redistribute this code, keep those notices intact.

---

## Troubleshooting

| Symptom | Likely Cause | Suggested Fix |
|--------|--------------|---------------|
| `Connectivity test failed` | Wrong credentials, network block, or TLS mismatch | Verify IP/hostname and credentials; try `--insecure` if the Grid uses a self-signed certificate |
| `TLS error on .` | Self-signed or untrusted certificate | Re-run with `--insecure` (lab/test only) or install a trusted cert on the Grid |
| `openpyxl not installed — skipping Excel output` | `openpyxl` missing | `pip install openpyxl`, or use `--format csv` |
| `Could not auto-detect WAPI version` | Older NIOS that doesn't expose `v1.0/?_schema`, or network restriction | Supply `--api-version v2.12` (or another known-good version) |
| `GET <endpoint> returned 400/401/403` | Insufficient permissions on the account | Grant the account read access to the affected object, or use a Grid admin |
| Column C shows `na` | Both `grid.uuid` and `grid:license_pool_container.lpc_uid` lookups failed (typically a permissions issue on older NIOS) | Confirm the account can read `grid:license_pool_container`, or re-run with `--debug` to inspect the WAPI response |
| Column F is blank even though you wanted IPs | `--no-include-ip` was passed, or the interactive prompt was answered with the default (`n`) | Re-run with `--include-ip`, or answer `y` at the "Include Member IP Addresses" prompt |
| Column F is blank for a Reporting or Network Insight appliance specifically | Fixed in v27 — upgrade to the latest script. Older versions relied only on `member:dns`, which those appliance types don't populate | Re-run with the current script; column F now falls back to `member.vip_setting` for non-DNS members |
| `[grid-capacity] ... capacityreport lookup failed` or the capacity workbook is missing | Member offline, or account lacks read access to `capacityreport` | Check the log for the specific member/error; the core report still completes normally regardless |
| Topology HTML file is missing or empty | `--no-topology-viz` was passed, or the interactive prompt defaulted to `n` | Re-run with `--topology-viz`, or answer `y` at the "Include DNS Topology Visualization" prompt |
| Script hangs during member processing | Offline member or slow API response | Wait — the script retries transient errors. Re-run with `--debug` for more visibility |
| Empty output directory / "No data collected" | Connectivity failed after the prompt | Check the log file (`*.log.jsonl`) in the output directory for the underlying error |

For unresolved issues, enable verbose logging with `--debug` and inspect the generated `.log.jsonl` file.

---

## Customization & Extension

The script is structured as a single file with clearly labeled sections to make adjustments straightforward:

- **`HEADER_43`** — Change column names or add new fields to the core report header.
- **`InfobloxClient`** — Add new read-only methods for additional WAPI endpoints you want to include (e.g., threat protection profiles, custom extensible attributes). `get_grid_uuid()`, `get_member_ipv4_map()`, and the v27 `get_member_vip_map()` are good templates.
- **`wapi_supports_grid_uuid()` / `parse_wapi_version()`** — Central place to gate features by WAPI version; extend this pattern as Infoblox adds new fields in future NIOS releases.
- **`gather_connection_info()`** — Add or reorder interactive prompts here; mirror any new option with a matching `argparse` flag in `build_arg_parser()`.
- **`collect_and_report()`** — Modify the orchestration logic to add or remove data collection steps.
- **`write_excel()` / `write_csv()`** — Adjust formatting, column widths, or add charts to the core Excel output. **Do not modify these for add-on data** — the Capacity and Topology sections write their own separate output files by design.
- **`ROLE_MAP`** — Extend role detection logic if your Grid uses custom role labels.
- **`generate_capacity_report()`** (Section 2) — Add fields to `CAPACITY_SUMMARY_HEADER` or adjust the DDI/Active-IP bucketing in `CAPACITY_DDI_TYPES` / `CAPACITY_ACTIVE_IP_TYPES`.
- **`build_topology()` / `generate_topology_viz()` / `TOPOLOGY_HTML_TEMPLATE`** (Section 3) — Add new relationship types to the graph, or adjust the rendered HTML/CSS/JS template.

---

## Feedback

Because this is a personal project, improvements are welcome but best-effort. If you find a bug or have an idea, feel free to share it with the author, but please **do not open an Infoblox support case** for this script.
