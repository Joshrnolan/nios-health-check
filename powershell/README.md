# Infoblox NIOS Grid Health Check — PowerShell Edition

> ### ⚠️ Important Disclaimer
>
> **This is NOT an officially supported Infoblox tool.**
>
> It is a personal project provided **as-is**, without warranty of any kind. It is not a product of Infoblox, Inc., and is **not covered by Infoblox Technical Support**.
>
> - Infoblox Support **will not** troubleshoot, debug, or provide assistance with this script.
> - Updates, fixes, and enhancements are **best-effort only** and not guaranteed.
> - Use of this script is entirely at your own discretion and risk.
> - Always review the script and test in a non-production environment before running against a production Grid.

---

## Overview

`Nios-HealthCheck.ps1` is a lightweight, **read-only** utility that connects to an Infoblox NIOS Grid Manager and collects the configuration and operational data typically gathered during a Health Check engagement, using the NIOS **WAPI (Web API)**. It is a PowerShell port of [`nios_health_check.py`](https://github.com/Joshrnolan/nios-health-check) (v28, by Josh Nolan) for environments where Python is not available but Windows PowerShell is — for example, government-furnished Windows workstations.

Because it runs entirely on the machine you point it from and writes only local files, **no data has to be sent to anyone or stored outside your environment**, and no Grid backup (with its IP information) is required. You review the output files and decide what to share.

The core report gathers:

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

Three **optional, opt-in add-on reports** are also available — see [Optional Add-On Reports](#optional-add-on-reports).

### Read-only by design

Every WAPI call is an HTTP `GET`, with one exception: a single `POST` to the `logout` endpoint at the end of the run, which only releases the session token. Nothing on the Grid is ever created, modified, or deleted. The only host the script contacts is the Grid Manager you give it.

### Differences from the Python edition

| | Python edition | PowerShell edition |
|---|---|---|
| Runtime | Python 3.8+, `requests`, optional `openpyxl` | Windows PowerShell 5.1 or PowerShell 7+, nothing to install |
| Excel (`.xlsx`) output | Yes | **No** — CSV and JSON only |
| Capacity report | One workbook, two sheets | **Two CSV files** (summary + object counts) |
| WAPI paging | None | Yes — list queries are paged (`-PageSize`, default 500) |
| Logout on error | Only on normal completion | Also attempted if the run fails part-way |
| CSV / JSON encoding | Platform default | UTF-8 (with BOM on Windows PowerShell 5.1) |

The core CSV has the identical 43 columns, in the same order, with the same header text.

> **Note on Grid-Wide licenses:** the published Python v28 asks `license:gridwide` for a `kind` field that object does not have. The WAPI answers `400 Unknown argument/field: 'kind'`, so the Python edition's Grid-Wide license list comes back empty (and logs an error). This edition requests only the fields that exist, so `Kind` is blank on Grid-Wide rows.

### Testing status

Validated against a single-member lab Grid (NIOS 9.1.0, WAPI v2.14) from Windows PowerShell 5.1 in FullLanguage mode, using `-Insecure` against the Grid's self-signed certificate. On that Grid the output was compared with the Python edition's using [`tools/compare_runs.py`](tools/compare_runs.py): the core report, summary, capacity, license, and topology files matched, apart from live CPU / disk / memory readings, which differ slightly between runs.

**Not yet validated** — please test these on your own Grid before relying on them:

- Topology output on a Grid that has zones, name server groups, RPZs, or forward / stub / delegated zones (the lab Grid had none)
- WAPI paging on result sets larger than `-PageSize`
- HA pairs, multi-member Grids, and non-DNS members (Reporting, Network Insight)
- Grid-Wide licenses (the lab Grid had none)
- NIOS versions older than 9.1 (the License UID fallback for column C)
- Constrained Language Mode, and PowerShell 7

---

## Optional Add-On Reports

All three default to **OFF**, reuse the same authenticated WAPI session as the core report (no second login), and write **separate** files — they never touch the core report's output.

### Grid Member Capacity Report (`-CapacityReport`)

Collects per-member database object counts and utilization from the `capacityreport` WAPI object and writes two CSV files:

- **`..._grid_capacity_summary.csv`** — one row per physical node: hardware type, max capacity, total objects, percent used, and estimated DDI vs. Active-IP object counts.
- **`..._grid_capacity_objects.csv`** — a per-member breakdown of every WAPI object type.

### DNS Topology Visualization (`-TopologyViz`)

Collects authoritative, delegated, forward, and stub zones, Name Server Groups, external name servers, and Response Policy Zones, and renders them into a **self-contained static HTML file** (`..._topology.html`) showing the primary / secondary / forwarder / delegated / stub / NSG relationship graph. A plain `..._topology.json` file with the same nodes / links / zone-count data is written alongside it for other tooling.

The HTML file has no server component — open it in any browser. The only remote resource it references is the [ECharts](https://echarts.apache.org/) library from a public CDN (`cdn.jsdelivr.net`), loaded **by the browser** when the file is opened; the script itself never fetches or runs it. (Search for `TOPOLOGY_HTML_TEMPLATE` in the script if your policy requires vetting it first.)

### Grid License Report (`-LicenseReport`)

Writes `..._license_report.csv` and `..._license_report.json`, one row per license entry (Grid-Wide and per member), with Scope, Member Name, Member IP (only when IP collection is enabled), Hardware ID / Serial Number, License Type, Kind, Limit, Expiration Status, and Expiry Date. Expiry dates are converted from the raw WAPI epoch value into readable text (e.g. `2027-04-30 00:00:00`, in the local time zone of the machine running the script), or `Permanent` / `N/A`. This report reuses license data already collected by the core report; its only extra call is one Grid-Wide license query.

---

## Requirements

- **PowerShell**: Windows PowerShell **5.1** (built into Windows 10/11 and Server 2016+) or PowerShell 7+ on Windows, Linux, or macOS
- **Network**: HTTPS (TCP/443) from the machine running the script to the Grid Manager
- **NIOS**: 8.x or 9.x with the WAPI enabled (default)
- **Account**: a Grid admin account with **read** permission sufficient to query the WAPI. A dedicated read-only service account is recommended over the built-in `admin`.

No modules, no Python, no administrator rights, and no internet access are needed on the machine running the script.

---

## Installation

1. Save `Nios-HealthCheck.ps1` to a working directory.
2. If the file was downloaded or copied from another system, remove the "Mark of the Web" so Windows doesn't block it:

   ```powershell
   Unblock-File .\Nios-HealthCheck.ps1
   ```

3. Check your execution policy (`Get-ExecutionPolicy`). If scripts are blocked, either run it for this one session only:

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\Nios-HealthCheck.ps1
   ```

   or, if your organization enforces `AllSigned`, sign the script with your organization's code-signing certificate before running it. Follow your local policy — do not weaken it system-wide for this tool.

4. Confirm it loads and view the built-in help:

   ```powershell
   Get-Help .\Nios-HealthCheck.ps1 -Full
   ```

---

## Usage

### Interactive run

```powershell
.\Nios-HealthCheck.ps1
```

You will be prompted for:

1. Grid Manager IP or hostname
2. WAPI username
3. WAPI password (hidden input)
4. Whether to bypass TLS verification (only for self-signed certificates)
5. Whether to include Member IP addresses in the output
6. Whether to include the Grid Member Database Capacity report
7. Whether to include the DNS Topology Visualization
8. Whether to include the Grid License Report
9. Customer name
10. Employee count
11. Geographic region (`EMEA`, `AMS`, or `APJ`)
12. User/SE name

Any value you supply as a parameter is not prompted for.

### Non-interactive run

```powershell
$pw = Read-Host "WAPI password" -AsSecureString

.\Nios-HealthCheck.ps1 `
    -GridIp 10.10.10.10 `
    -Username svc-healthcheck `
    -Password $pw `
    -Customer "Acme Corp" `
    -Employees 2500 `
    -Geo AMS `
    -User "Jane Doe" `
    -NoIncludeIp `
    -NoCapacityReport `
    -TopologyViz `
    -LicenseReport
```

> **Tip:** Omit `-Password` and the script prompts for it securely. Passing it as a `SecureString` (as above) keeps it out of shell history; avoid typing a plain-text password on the command line.

### Member IP address opt-in

By default the report does **not** include per-member IPv4 addresses. Pass `-IncludeIp` (or answer `y` at the prompt) to populate **column F ("Member IP")** using a 3-tier fallback, evaluated in order:

1. `member:dns` (`host_name`, `ipv4addr`) — only members running the DNS service
2. `member` → `vip_setting.address` — the base management IP; exists for **every** member (including Reporting and Network Insight appliances that don't run DNS)
3. `capacityreport._ref` — legacy last resort

If all three are empty for a member, a **WARNING** is written to the run log so the gap is visible. Pass `-NoIncludeIp` (or press Enter at the prompt) to leave column F blank.

### Parameters

| Parameter | Description |
|---|---|
| `-GridIp` | Grid Manager IP address or hostname |
| `-Username` | WAPI username |
| `-Password` | WAPI password — a `SecureString` (recommended) or plain string. Prompted securely if omitted |
| `-ApiVersion` | Force a WAPI version (e.g. `v2.12`). Auto-detected by default; falls back to `v2.12` |
| `-Customer` | Customer name used in the report |
| `-Employees` | Employee count (integer) |
| `-Geo` | Region: `EMEA`, `AMS`, or `APJ` |
| `-User` | Name of the person running the Health Check |
| `-Log` | Custom log file name (created inside the output folder) |
| `-Insecure` | Bypass TLS certificate verification (self-signed certs; lab use) |
| `-IncludeIp` / `-NoIncludeIp` | Include / exclude Member IP addresses (skips the prompt) |
| `-CapacityReport` / `-NoCapacityReport` | Generate / skip the Capacity report (skips the prompt) |
| `-TopologyViz` / `-NoTopologyViz` | Generate / skip the DNS Topology Visualization (skips the prompt) |
| `-LicenseReport` / `-NoLicenseReport` | Generate / skip the Grid License Report (skips the prompt) |
| `-PageSize` | Objects per WAPI page for list queries (1–1000, default 500). Lower it if you see timeouts on very large Grids |
| `-DebugMode` | Verbose debug logging |

---

## Outputs

The script creates a **timestamped folder** in the current directory, e.g. `nios_health_audit_20261013_141530`, containing:

| File | Description |
|---|---|
| `nios_health_audit_<ts>.csv` | Core report — one row per physical node, 43 columns |
| `nios_health_audit_<ts>.summary.json` | Run summary: Grid name, version, Grid UUID, option choices, counts, customer info, SHA-256 of the core CSV |
| `nios_health_audit_<ts>.log.jsonl` | Structured JSON-lines log of the run |

With the optional add-ons enabled:

| File | Written when |
|---|---|
| `..._grid_capacity_summary.csv`, `..._grid_capacity_objects.csv` | `-CapacityReport` |
| `..._topology.html`, `..._topology.json` | `-TopologyViz` |
| `..._license_report.csv`, `..._license_report.json` | `-LicenseReport` |

For HA pairs, the active and passive nodes are separate rows keyed by hardware ID.

**Encoding note:** on Windows PowerShell 5.1, CSV and JSON files are UTF-8 **with a byte-order mark**. Most tools handle this; in Python use `encoding="utf-8-sig"`.

### Column C — `grid_uuid`

Always labeled `grid_uuid`; the source depends on the detected WAPI version:

| WAPI version | NIOS version | Source |
|---|---|---|
| v2.14 or newer | 9.1.0+ | `grid.uuid` |
| v2.13 or older | ≤ 9.0.8 | `grid:license_pool_container.lpc_uid` (License UID) |
| Lookup failed | — | `na` |

---

## How It Works

1. **Prompt & connect** — collects the Grid address, credentials, TLS preference, option toggles, and customer context; auto-detects the newest WAPI version the Grid supports.
2. **Verify** — a lightweight connectivity test runs before any real work.
3. **Collect** — read-only WAPI calls gather Grid identity, UUID, members, licenses, DNS/DHCP settings, object counts, and per-node performance. List queries are paged.
4. **Process** — for each member, walks every node (including HA pairs), matches licenses by hardware ID, and builds a row.
5. **Report** — writes the CSV and `summary.json` (with SHA-256 hashes), then any requested add-on files.
6. **Log out** — releases the WAPI session, even if the run fails part-way.

---

## Assumptions & Limitations

- This port mirrors the Python edition's WAPI calls and output formats. As with any tool that reads a production Grid, validate its output on your own environment before relying on it.
- WAPI version auto-detection needs access to `v1.0/?_schema`; if unavailable it falls back to **v2.12**.
- **Grid UUID** is only native on NIOS 9.1.0+ (WAPI v2.14+); older Grids use the License UID in the same column.
- **Member IPs are opt-in**; members with no discoverable IP are logged, not failed.
- Some columns (`Member QPS`, `Member LPS Total`, `Grid Enabled Feature`, etc.) are intentionally blank placeholders, as in the Python edition.
- The data is a **point-in-time snapshot**, not continuous monitoring.
- Offline or unreachable members default to role **Member** and an empty IP rather than failing the run.
- Large Grids take longer; each member needs several calls, and the add-ons add more.
- In the topology graph, names that differ only by letter case are merged into one node.
- **Constrained Language Mode** (common on locked-down government workstations): the script avoids inline C#, `Add-Type`, COM, and external modules. A few .NET calls it relies on may still be restricted by your policy; if so, the error is logged. See Troubleshooting.

---

## Security Considerations

- **Use a dedicated read-only service account**, not the Grid `admin` account, where possible.
- **Never hard-code credentials.** Use the interactive prompt or a `SecureString`. Credentials are held in memory only for the run and are never written to disk or the log.
- **Avoid a plain-text `-Password` on the command line** — it can end up in shell history and process listings.
- **Keep `-Insecure` off in production.** It disables certificate validation for the PowerShell process (on Windows PowerShell 5.1 it is process-wide), exposing the session to man-in-the-middle attacks. On 5.1 in FullLanguage mode it compiles a six-line certificate callback with `Add-Type` (search for `NiosTrustAllCerts`); nothing else in the script uses `Add-Type`. Prefer installing the Grid certificate or its CA in the Windows certificate store.
- **Be deliberate with `-IncludeIp`** — member addresses are topology data.
- **Protect the output folder.** Reports contain Grid topology, license inventory, and operational state; handle and share them accordingly.
- **Review the log before sharing.** It contains endpoint names, counts, and error messages — not credentials or record contents.
- **The topology HTML loads ECharts from a public CDN** when opened in a browser; no credentials or Grid data are sent beyond that one library request.
- The script **logs out of its WAPI session** at the end of each run.

---

## Troubleshooting

| Symptom | Likely cause | Suggested fix |
|---|---|---|
| `File ... cannot be loaded because running scripts is disabled` | Execution policy | See [Installation](#installation) step 3 |
| `File ... is not digitally signed` | `AllSigned` policy | Sign the script with your organization's code-signing certificate |
| `Connectivity test failed` | Wrong credentials, network block, or TLS mismatch | Verify address and credentials; use `-Insecure` for a self-signed lab Grid |
| `TLS error on <endpoint>` / "Could not establish trust relationship" | Untrusted or self-signed Grid certificate | Install the cert/CA in the Windows store, or `-Insecure` (lab only) |
| `The underlying connection was closed: An unexpected error occurred on a send` | TLS handshake failed (the log line now includes the inner reason after ` | `). Often the `-Insecure` callback or a protocol mismatch | Update to the current script; if it persists, install the Grid certificate in the Windows store and run without `-Insecure`, and check the inner message |
| `Could not bypass TLS verification in this session` | Constrained Language Mode blocks the bypass | Install the Grid certificate (or its CA) in the Windows certificate store and re-run without `-Insecure` |
| TLS/SSL errors even with a trusted cert on an older Windows build | TLS 1.2 not negotiated | Use a current Windows PowerShell 5.1 / .NET Framework 4.7+ build, or PowerShell 7 |
| `Could not auto-detect WAPI version` | Older NIOS without `v1.0/?_schema`, or a network restriction | Supply `-ApiVersion v2.12` (or another known-good version) |
| `GET <endpoint> returned 400/401/403` | Insufficient permissions on the account | Grant read access to the affected object, or use a Grid admin |
| Column C shows `na` | Both `grid.uuid` and `lpc_uid` lookups failed | Confirm the account can read `grid:license_pool_container`; re-run with `-DebugMode` |
| Column F blank although IPs were wanted | `-NoIncludeIp` passed, or the prompt defaulted to `n` | Re-run with `-IncludeIp` |
| Column F blank for one member only | No IP from any of the three sources | Check the log for the WARNING naming that member |
| Capacity files missing or `capacityreport lookup failed` | Member offline, or no read access to `capacityreport` | Check the log; the core report still completes |
| Topology files missing | `-NoTopologyViz` passed or prompt defaulted to `n` | Re-run with `-TopologyViz` |
| Slow, or timeouts on a very large Grid | Large result sets | Lower `-PageSize` (e.g. `200`) |
| Script seems to hang on a member | Offline member or slow API response | Wait — transient errors are retried; re-run with `-DebugMode` |
| Empty folder / `No data collected` | Connectivity failed after the prompts | Check `*.log.jsonl` in the output folder |
| Garbled first header when reading CSV in another tool | UTF-8 BOM on Windows PowerShell 5.1 | Read as UTF-8 with BOM (`utf-8-sig`) |

For anything unresolved, re-run with `-DebugMode` and inspect the `.log.jsonl` file.

---

## Customization & Extension

The script is a single file with clearly labeled sections:

- **`$script:HEADER_43`** — the exact 43-column header. Do not change it if you upload to the Health Check portal.
- **`Invoke-WapiGet` / `Invoke-WapiHttp`** — the one place WAPI queries are built, paged, and retried. Add new read-only calls as small `Get-Nios...` functions modeled on `Get-NiosGridUuid` or `Get-NiosMemberVipMap`.
- **`Test-WapiSupportsGridUuid`** — gate features by WAPI version here.
- **`Invoke-NiosHealthCheck`** — the orchestration: prompts, collection, per-member processing, and output.
- **`Write-CsvFile`** — CSV writer (quoting matches the Python edition's output).
- **`New-CapacityReport`** (Section 2), **`Build-Topology` / `New-TopologyViz` / `$script:TOPOLOGY_HTML_TEMPLATE`** (Section 3), **`New-LicenseReport`** (Section 4) — each add-on writes its own files by design; don't route add-on data through the core writer.

---

## Verifying against the Python edition

`tools/compare_runs.py` compares the output folders of the two editions (needs Python and `openpyxl`). Run both against the same Grid back to back, then:

```
python tools/compare_runs.py <python_run_folder> <powershell_run_folder>
```

Pass the Python folder first: the tool reads the Python edition's capacity workbook and compares it with this edition's capacity CSV pair. It ignores timestamps, log paths, and hashes. Live CPU / disk / memory ratios can differ slightly between runs and are not a bug.

---

## License & Attribution

Licensed under the **MIT License** — see [`LICENSE.txt`](LICENSE.txt). This PowerShell edition is a port of `nios_health_check.py` by Josh Nolan (MIT License).

The optional Section 2 (Capacity Report) and Section 3 (DNS Topology Visualization) adapt logic from two other MIT-licensed open-source projects, via the Python edition:

| Section | Adapted from | Author |
|---|---|---|
| Grid Member Capacity Report | [nios_grid_capacity.py](https://github.com/pvogelsang67/nios_grid_capacity) | Pat Vogelsang |
| DNS Topology Visualization | [NIOS-DDI-Dashboard](https://github.com/robdcooper/NIOS-DDI-Dashboard) (`ddi_collect.py` / `ddi_dashboard.html`) | Bobby Cooper |

Their original copyright and permission notices are reproduced in full in [`NOTICE.md`](NOTICE.md) and must stay intact if you redistribute this code.

---

## Feedback

This is a personal project; improvements are welcome but best-effort. Please **do not open an Infoblox support case** for this script.
