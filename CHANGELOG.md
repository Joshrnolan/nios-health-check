
# Changelog

All notable changes to the **Infoblox NIOS Grid Health Check** script are documented here.

The format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions correspond to the `Production vXX` tag in the script header.

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
