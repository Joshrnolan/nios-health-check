# Changelog

All notable changes to the **Infoblox NIOS Grid Health Check** script are documented here.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions correspond to the `Production vXX` tag in the script header.

---

## [v28] — 2026-09-03

### Added
- **New Section 4 — Grid License Report (`--license-report` / `--no-license-report`)**. Collects Grid-Wide license entries (`license:gridwide`) and per-member license entries (`member:license`, already fetched by the core report — no additional WAPI calls), and writes separate `<run>_license_report.xlsx`, `.csv`, and `.json` files, one row per license entry, with:
  - `Scope` (`Grid Wide` or `Member`), `Member Name`, `Member IP` (populated only when Member IP collection is enabled, otherwise blank), `Hardware ID` / `Serial Number` (the WAPI `hwid` for that license, blank for Grid-Wide entries), `License Type`, `Kind`, `Limit`, `Expiration Status`, `Expiry Date`.
  - Every `Expiry Date` is converted from the raw WAPI epoch value into a human-readable text string (or `"Permanent"` / `"N/A"`) via new `_format_expiry_date()` / `_format_license_entry()` helpers, instead of being left as a raw epoch integer.
  - The `.xlsx` file is skipped (with a warning) if `openpyxl` is not installed; the `.csv` and `.json` files are always written.
  - New `InfobloxClient.get_global_licenses_detailed()` for the full Grid-Wide license record set.
  - Same "prompt unless flagged" interactive/CLI pattern as the other add-ons: `--license-report` / `--no-license-report`.
- **Section 3 (`--topology-viz`) now also writes a plain `<run>_topology.json` file** alongside the existing `<run>_topology.html` page, containing the same `nodes`/`links`/`zone_counts` topology database used to render the HTML graph, so other/3rd-party tooling can consume the DNS topology data directly without parsing HTML. `generate_topology_viz()` now returns a `(html_path, json_path)` tuple.

### Changed
- `gather_connection_info()` now also returns the License Report toggle; `collect_and_report()`'s `summary.json` gains a `license_report` field alongside the existing `capacity_report` / `topology_viz` fields.
- `generate_license_report()` now returns a list of written file paths instead of a single path.


---

## [v27] — 2026-09-02

### Fixed
- **Member IP (column F) was blank for grid members that do not run the DNS service** (e.g. Reporting appliances / IB-V5005, Network Insight / Discovery appliances / ND-V906). Root cause: the IP lookup relied solely on the `member:dns` WAPI object, which only returns an entry for members with the DNS service present; the intended fallback (parsing an IP out of `capacityreport._ref`) never worked because that `_ref` ends in the member's host name, not an IP address.

### Added
- New `InfobloxClient.get_member_vip_map()`, sourced from `member.vip_setting`, which is universal across every grid member type regardless of which services (DNS/DHCP) it runs. Column F now resolves via a 3-tier fallback: `member:dns` → `member.vip_setting` → `capacityreport._ref` (legacy).
- Any member for which all three sources come back empty is now logged as a **WARNING** (previously silent) so gaps are visible in the run log.

---

## [v26] — 2026-08-XX

### Added
- Name Server Groups, external name servers, and Response Policy Zones (`zone_rp`) to the Section 3 DNS topology visualization.

---

## [v25] — 2026-07-XX

### Changed
- **Combined what previously shipped as three files** (`nios_health_check.py`, `nios_grid_capacity_module.py`, `nios_topology_viz.py`) into this single file, so it can be reviewed and approved as one script.
- `HEADER_43`, `write_excel()`, `write_csv()`, and the `summary.json` schema are unchanged, so the existing health check portal upload workflow keeps working exactly as before.

### Added
- New, additive-only CLI flags, both default **OFF**:
  - `--capacity-report` — Section 2: separate Grid Member Capacity workbook.
  - `--topology-viz` — Section 3: separate DNS topology HTML page.

---

## [v24] — 2026-04-30

### Fixed
- **Interactive "Include Member IP Addresses" prompt now actually fires.** In v23, `--include-ip` was declared with `action="store_true"` only, which caused argparse to default the attribute to `False` (not `None`). The prompt guard `if include_ip is None` therefore never ran and the value silently stayed `False`. Fixed by setting `default=None` on `--include-ip` and adding a matching `--no-include-ip` to flip it off non-interactively.

### Changed
- **Member IP source swapped to `member:dns`.** When the user opts in, per-member IPv4 addresses are now pulled from `member:dns?_return_fields=host_name,ipv4addr` and mapped by `host_name` into column F. The previous `capacityreport._ref` extraction is retained only as a last-resort fallback for hosts missing from the map.
- When IPs are **not** included, column F is left blank for every row (previously carried the capacityreport-derived IP regardless of user choice).

### Added
- New CLI flag `--no-include-ip` for scripted runs that want to guarantee IPs are excluded without triggering the interactive prompt.
- New `InfobloxClient.get_member_ipv4_map()` helper returning `{host_name: ipv4addr}` for all Grid members.

---

## [v23] — 2026-04-29

### Added
- **Column C (`grid_uuid`) is now populated automatically** based on the detected WAPI version:
  - WAPI **v2.14+ / NIOS 9.1.0+** → native `grid.uuid`.
  - WAPI **v2.13 and older** → `grid:license_pool_container.lpc_uid` fallback (header remains `grid_uuid` so downstream tooling doesn't need to branch).
  - Both lookups failing → `"na"` (safe default, matches prior behavior).
- New `InfobloxClient.get_grid_uuid(api_ver)` method encapsulating the version-aware logic.
- New helpers `parse_wapi_version()` and `wapi_supports_grid_uuid()` for centralized version gating.
- Interactive prompt to opt in/out of including Member IP addresses in the output, with matching `--include-ip` CLI flag.
  - ⚠️ **Prompt did not actually fire in v23 due to an argparse default bug — fixed in v24.**
- `summary.json` now records `grid_uuid` and the `include_ip` choice for traceability.

---

## [v22] — Baseline

### Summary
- Read-only Infoblox NIOS Grid Health audit script.
- Auto-detects latest WAPI version (falls back to `v2.12`).
- Collects Grid identity, members (including HA pairs), licenses (keyed by hwid), DNS/DHCP settings, object counts, and per-node CPU/memory/disk utilization.
- Emits `.xlsx`, `.csv`, `.summary.json`, and `.log.jsonl` artifacts into a timestamped output directory, with SHA-256 integrity hashes.
- Column C (`grid_uuid`) hard-coded to `"na"` (addressed in v23).
- Member IP always populated from `capacityreport._ref` with no user opt-out (addressed in v23/v24).
