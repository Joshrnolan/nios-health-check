# Changelog

All notable changes to the PowerShell edition of the **Infoblox NIOS Grid Health Check** are documented here. It tracks the Python edition's `Production vXX` numbering.

---

## [ps-v28.2] — 2026-10-14

### Added
- Version tag (`.NOTES`, `$script:VERSION`, shown in the debug log).
- `tools/compare_runs.py` to diff this edition's output against the Python edition's.
- README "Testing status" section and `.gitignore` (keeps run output out of the repo).

### Fixed
- License Report: the Grid-Wide license query asked `license:gridwide` for a `kind` field it does not have, so the WAPI answered 400 and the report silently contained no Grid-Wide rows. The query now requests only `type,expiration_status,expiry_date,limit` (with a default-fields retry); `Kind` is blank for Grid-Wide rows. The Python edition's `get_global_licenses_detailed()` has the same request.

---

## [ps-v28.1] — 2026-10-14

### Fixed
- `-Insecure` on Windows PowerShell 5.1 could fail every call with "The underlying connection was closed: An unexpected error occurred on a send". The certificate bypass now uses a small compiled callback in FullLanguage mode (scriptblock fallback only where `Add-Type` is blocked), and the script offers TLS 1.2/1.3 explicitly.
- HTTP errors now include the inner exception chain, which carries the real TLS reason.

---

## [ps-v28.0] — 2026-10-13

### Added
- Initial PowerShell port (`Nios-HealthCheck.ps1`) of `nios_health_check.py` **v28**, targeting Windows PowerShell 5.1 (also runs on PowerShell 7+). No modules or other dependencies.
- All four sections: core 43-column report, Capacity Report, DNS Topology Visualization, License Report, with the same interactive prompts and switch pairs (`-IncludeIp` / `-NoIncludeIp`, etc.).
- WAPI paging for list queries, with a `-PageSize` parameter (default 500).
- `-DebugMode` verbose logging; structured JSON-lines log, SHA-256 hashes in `summary.json`.

### Changed (relative to the Python edition)
- No Excel output. The core report is CSV; the Capacity report is two CSV files (summary + object counts) instead of one workbook; `summary.json` records `"format": "csv"`.
- The WAPI session is logged out even if the run fails part-way.
- CSV/JSON files are UTF-8 (with a BOM on Windows PowerShell 5.1).
- Topology node ids that differ only by letter case are merged into one node.
- TLS-verification bypass (`-Insecure`) on Windows PowerShell 5.1 uses a process-wide validation callback instead of `--insecure`'s per-session setting, and reports clearly when Constrained Language Mode prevents it.
