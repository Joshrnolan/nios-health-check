
#!/usr/bin/env python3
"""
Infoblox NIOS Grid Health Audit (Production v22)
---------------------------------------------------
"""
from __future__ import annotations

import argparse
import csv
import getpass
import hashlib
import json
import logging
import os
from logging.handlers import RotatingFileHandler
import re
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

import requests
import urllib3
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

try:
    from openpyxl import Workbook
    XLSX_AVAILABLE = True
except ImportError:
    XLSX_AVAILABLE = False

# ------------------------- Constants -------------------------
APP_NAME            = "nios_health_audit"
DEFAULT_API_VERSION = "v2.12"
REQUEST_TIMEOUT     = 30
RETRY_TOTAL         = 3
RETRY_BACKOFF       = 0.3

ROLE_MAP: Dict[str, str] = {
    "grid master":           "GM",
    "grid master candidate": "GMC",
}

HEADER_43: List[str] = [
    "Customer Name", "Employee Count", "grid_uuid", "Member Serial Number", "Member Role",
    "Member IP", "Member Host Name", "Member Model", "Member Platform", "Member ha Status",
    "Member Operational State", "Member Version", "Member Version History", "Member Protocol",
    "Member Object Count", "Member Enabled Features", "Member License ", "Log Lease Events",
    "Grid Name", "Geo Country Name", "Collected At", "grid wide license con", "Grid Enabled Feature",
    "DNS DNS Scavenging", "DNS Query Response Logging", "DNS Nameserver Groups", "DNS Anycast",
    "DNS DNS Scavenging", "DNS DNS Over HTTPs", "DNS DTC", "DHCP Finger Printing",
    "NIOS File Distribution", "User Name", "DHCP IPv4 Hosts", "DNS DNS Views", "DTC Members Pct",
    "Grid Admin Count", "NIOS Smart Folders", "Member LPS Total", "CPU Usage Ratio",
    "Disk Usage Ratio", "Memeory Usage Ratio", "Member QPS",
]


# ------------------------- Logging -------------------------
class JsonLineFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts":     datetime.utcnow().isoformat() + "Z",
            "level":  record.levelname,
            "msg":    record.getMessage(),
            "logger": record.name,
        }
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload)


def setup_logging(log_path: str, debug: bool = False) -> logging.Logger:
    logger = logging.getLogger("bloxconnect")
    logger.setLevel(logging.DEBUG if debug else logging.INFO)
    logger.handlers.clear()
    ch = logging.StreamHandler()
    ch.setLevel(logging.DEBUG if debug else logging.INFO)
    ch.setFormatter(logging.Formatter("%(levelname)s: %(message)s"))
    logger.addHandler(ch)
    fh = RotatingFileHandler(log_path, maxBytes=10 * 1024 * 1024, backupCount=3)
    fh.setLevel(logging.DEBUG if debug else logging.INFO)
    fh.setFormatter(JsonLineFormatter())
    logger.addHandler(fh)
    return logger


# ------------------------- HTTP Session -------------------------
def make_session(verify_ssl: Any, proxies: Optional[Dict[str, str]] = None) -> requests.Session:
    session = requests.Session()
    retry = Retry(
        total=RETRY_TOTAL, read=RETRY_TOTAL, connect=RETRY_TOTAL,
        backoff_factor=RETRY_BACKOFF,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=("GET",),
        raise_on_status=False,
    )
    session.mount("https://", HTTPAdapter(max_retries=retry))
    session.verify = verify_ssl
    if proxies:
        session.proxies.update(proxies)
    return session


# ------------------------- Connection Prompt -------------------------
def gather_connection_info(args: argparse.Namespace) -> Tuple[str, str, str, bool]:
    grid_ip = getattr(args, "grid_ip", "") or ""
    while not grid_ip:
        grid_ip = input("Grid Manager IP/Hostname: ").strip()
    username = getattr(args, "username", "") or ""
    while not username:
        username = input("WAPI Username: ").strip()
    password = getattr(args, "password", "") or ""
    while not password:
        password = getpass.getpass("WAPI Password: ")
    insecure = getattr(args, "insecure", False)
    if not insecure:
        ans = input("Bypass TLS Verification (y/n) [n]: ").strip().lower()
        if ans in ("y", "yes", "1", "true"):
            insecure = True
    return grid_ip, username, password, insecure


def get_latest_wapi_version(
    grid_ip: str, username: str, password: str,
    verify: Any, proxies: Optional[Dict[str, str]], logger: logging.Logger,
) -> str:
    session = make_session(verify, proxies)
    url = f"https://{grid_ip}/wapi/v1.0/?_schema"
    try:
        resp = session.get(url, auth=(username, password), timeout=REQUEST_TIMEOUT)
        resp.raise_for_status()
        versions = resp.json().get("supported_versions", [])
        if versions:
            def pv(v: str) -> List[int]:
                return [int(x) for x in str(v).lower().lstrip("v").split(".") if x.isdigit()]
            latest = sorted(versions, key=pv)[-1]
            return latest if latest.startswith("v") else f"v{latest}"
    except Exception as e:
        logger.warning(f"Could not auto-detect WAPI version (defaulting to {DEFAULT_API_VERSION}): {e}")
    return DEFAULT_API_VERSION


# ------------------------- Infoblox WAPI Client -------------------------
class InfobloxClient:

    def __init__(
        self, grid_ip: str, username: str, password: str,
        api_version: str = DEFAULT_API_VERSION, verify_ssl: Any = True,
        logger: Optional[logging.Logger] = None, timeout: int = REQUEST_TIMEOUT,
        proxies: Optional[Dict[str, str]] = None,
    ):
        self.base_url = f"https://{grid_ip}/wapi/{api_version}/"
        self.auth     = (username, password)
        self.session  = make_session(verify_ssl, proxies)
        self.timeout  = timeout
        self.logger   = logger or logging.getLogger("bloxconnect")

    def _get(self, endpoint: str, params: Optional[Dict[str, Any]] = None) -> Optional[Any]:
        url = f"{self.base_url}{endpoint}"
        try:
            resp = self.session.get(url, auth=self.auth, params=params, timeout=self.timeout)
            if not (200 <= resp.status_code < 300):
                self.logger.warning(f"GET {endpoint} returned {resp.status_code}")
            resp.raise_for_status()
            data = resp.json()
            return data["result"] if isinstance(data, dict) and "result" in data else data
        except requests.exceptions.SSLError as e:
            self.logger.error(f"TLS error on {endpoint}: {e}")
        except Exception as e:
            self.logger.error(f"GET {endpoint} failed: {e}")
        return None

    def test_connectivity(self) -> bool:
        ok = bool(self._get("grid", {"_return_fields": "name"}))
        if not ok:
            self.logger.error("Connectivity test failed. Check credentials and TLS (--insecure).")
        return ok

    def get_grid_identity(self) -> Dict[str, Any]:
        return (self._get("grid", {"_return_fields": "name"}) or [{}])[0]

    def get_software_version(self) -> str:
        data = self._get("upgradestatus", {"type": "GRID", "_return_fields": "current_version_summary"})
        if data:
            full = data[0].get("current_version_summary", "N/A")
            return full.split("-")[0] if "-" in full else full
        return "N/A"

    def get_global_licenses(self) -> str:
        data = self._get("license:gridwide", {"_return_fields": "type"}) or []
        return ", ".join(sorted(set(l.get("type", "") for l in data if l.get("type"))))

    def get_grid_members(self) -> List[Dict[str, Any]]:
        # ipv4addr excluded — causes 400 on WAPI v2.14
        return self._get("member", {"_return_fields+": "node_info,service_status,host_name,master_candidate"}) or []

    def get_member_role_and_ip(self, host_name: str) -> Tuple[str, str]:
        """
        Authoritative role detection via capacityreport 'role' field.
        Returns (role_label, member_ip).
        role field values: "Grid Master" -> "GM", "Grid Master Candidate" -> "GMC", else "Member".
        member_ip extracted from capacityreport _ref trailing segment if it's an IPv4.
        Offline/error members default to ("Member", "").
        """
        data = self._get("capacityreport", {"name": host_name, "_return_fields": "name,role"})
        if not data:
            self.logger.info(f"capacityreport '{host_name}': no data (offline?) — defaulting to Member")
            return "Member", ""
        entry    = data[0] if isinstance(data, list) else {}
        raw_role = entry.get("role", "").strip().lower()
        role_label = ROLE_MAP.get(raw_role, "Member")
        member_ip = ""
        m = re.search(r":([^/]+)$", entry.get("_ref", ""))
        if m and re.match(r"^\d{1,3}(\.\d{1,3}){3}$", m.group(1)):
            member_ip = m.group(1)
        self.logger.debug(f"capacityreport '{host_name}': role='{raw_role}' -> '{role_label}', ip='{member_ip}'")
        return role_label, member_ip

    def get_licenses_by_hwid(self) -> Dict[str, List[Dict[str, Any]]]:
        """
        Fetches ALL member:license records and groups them by hwid.

        The member:license endpoint returns the 'hwid' field directly on every
        record — no Base64 parsing or hostname correlation required.

        Returns:
            { "1B888FD244DF4119885B21BC469B524D": [
                  {"type": "GRID", "kind": "Static", "expiration_status": "NOT_EXPIRED", ...},
                  {"type": "DNS",  ...},
                  {"type": "NIOS", ...},
              ],
              "59C1CA4017AC424FB5B6F1122DF506CE": [
                  {"type": "NIOS",      ...},
                  {"type": "REPORTING", ...},
              ],
              ...
            }

        During row building, look up by node.get('hwid') to get that physical
        node's license list. Works for all member types including Reporting.
        """
        data = self._get(
            "member:license",
            {"_return_fields": "type,kind,limit,expiration_status,expiry_date,hwid"},
        ) or []
        result: Dict[str, List[Dict[str, Any]]] = {}
        for lic in data:
            hwid = lic.get("hwid")
            if hwid:
                result.setdefault(hwid, []).append(lic)
            else:
                self.logger.debug(f"member:license has no hwid: {lic.get('_ref')}")
        self.logger.info(f"get_licenses_by_hwid: licenses found for {len(result)} hwid(s)")
        return result

    def get_member_object_count(self, host: str) -> int:
        data = self._get("capacityreport", {"name": host, "_return_fields": "object_counts"})
        if not data:
            return 0
        try:
            return sum(o.get("count", 0) for o in data[0].get("object_counts", []))
        except Exception:
            return 0

    def get_active_dhcp_leases(self, ref: Optional[str]) -> int:
        if not ref:
            return 0
        try:
            res   = self._get("dhcp:statistics", {"statistics_object": ref, "_return_fields": "static_hosts,dynamic_hosts"})
            stats = res[0] if isinstance(res, list) else (res or {})
            return int(stats.get("static_hosts", 0) or 0) + int(stats.get("dynamic_hosts", 0) or 0)
        except Exception:
            return 0

    def get_global_dns_settings(self) -> Tuple[Dict[str, Any], Dict[str, Any]]:
        scav = (self._get("grid:dns", {"_return_fields": "scavenging_settings"})  or [{}])[0]
        logs = (self._get("grid:dns", {"_return_fields": "logging_categories"})   or [{}])[0]
        return scav, logs

    def get_global_dhcp_settings(self) -> Dict[str, Any]:
        props = (self._get("grid:dhcpproperties", {"_return_fields": "log_lease_events"}) or [{}])[0]
        fp    =  self._get("grid:dhcpproperties", {"_return_fields": "enable_fingerprint"})
        props["enable_fingerprint"] = fp[0].get("enable_fingerprint", False) if fp else False
        return props

    def get_dhcp_service_map(self) -> Dict[str, Dict[str, Any]]:
        data = self._get("member:dhcpproperties", {"_return_fields": "host_name,enable_dhcp"}) or []
        return {i["host_name"]: {"ref": i.get("_ref"), "enabled": i.get("enable_dhcp", False)}
                for i in data if i.get("host_name")}

    def get_dns_service_map(self) -> Dict[str, Dict[str, Any]]:
        data = self._get("member:dns", {"_return_fields": "host_name,enable_dns"}) or []
        return {i["host_name"]: {"enabled": i.get("enable_dns", False)}
                for i in data if i.get("host_name")}

    def get_grid_object_counts(self) -> Dict[str, Any]:
        return {
            "views":   len(self._get("view")                or []),
            "has_nsg": bool(self._get("nsgroup")),
            "folders": len(self._get("smartfolder:global") or []),
            "admins":  len(self._get("adminuser")          or []),
        }

    def logout(self) -> None:
        try:
            resp = self.session.post(f"{self.base_url}logout", auth=self.auth, timeout=self.timeout)
            if 200 <= resp.status_code < 300:
                self.logger.info("WAPI session logged out.")
            else:
                self.logger.warning(f"WAPI logout returned {resp.status_code}")
        except Exception as e:
            self.logger.error(f"WAPI logout failed: {e}")


# ------------------------- Output Writers -------------------------
def write_excel(rows: List[Dict[str, Any]], path: str, logger: logging.Logger) -> None:
    if not XLSX_AVAILABLE:
        logger.warning("openpyxl not installed — skipping Excel output.")
        return
    wb = Workbook()
    ws = wb.active
    ws.title = "Health Audit"
    for ci, h in enumerate(HEADER_43, 1):
        ws.cell(row=1, column=ci, value=h)
    for ri, data in enumerate(rows, 2):
        for ci, h in enumerate(HEADER_43, 1):
            val  = data.get("DNS DNS Scavenging_2") if ci == 28 else data.get(h, "")
            cell = ws.cell(row=ri, column=ci, value=val)
            if ci in (40, 41, 42):
                cell.number_format = "0%"
    wb.save(path)


def write_csv(rows: List[Dict[str, Any]], path: str) -> None:
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(HEADER_43)
        for data in rows:
            w.writerow([
                data.get("DNS DNS Scavenging_2") if i == 28 else data.get(h, "")
                for i, h in enumerate(HEADER_43, 1)
            ])


# ------------------------- Helpers -------------------------
def pct_to_ratio(s: str) -> float:
    try:
        return float(s.replace("%", "").strip()) / 100.0
    except Exception:
        return 0.0


def validate_geo(value: Optional[str]) -> str:
    v = (value or "AMS").strip().upper()
    return v if v in {"EMEA", "AMS", "APJ"} else "AMS"


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


# ------------------------- Main Orchestration -------------------------
def collect_and_report(args: argparse.Namespace) -> None:
    ts      = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_dir = f"{APP_NAME}_{ts}"
    os.makedirs(out_dir, exist_ok=True)

    log_path = os.path.join(out_dir, args.log or f"{APP_NAME}_{ts}.log.jsonl")
    logger   = setup_logging(log_path, debug=args.debug)

    print("""
============================================================
INFOBLOX HEALTH CHECK DATA COLLECTION
============================================================
Please provide the following information:
------------------------------------------------------------""")

    grid_ip, username, password, insecure = gather_connection_info(args)
    verify_ssl = not insecure

    customer  = args.customer or input("Customer Name: ").strip() or "General"
    employees = str(args.employees) if args.employees is not None else (input("Employee Count [100]: ").strip() or "100")
    geo       = validate_geo(args.geo) if args.geo else validate_geo(input("Geo Country Name (EMEA, AMS, or APJ) [AMS]: ").strip())
    user_name = args.user or input("User/SE Name: ").strip() or "SE"
    print("------------------------------------------------------------\n")

    if not verify_ssl or args.silent_warnings:
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    provided_ver = getattr(args, "api_version", "") or ""
    if provided_ver:
        api_ver = provided_ver
        logger.info(f"Using provided API version: {api_ver}")
    else:
        logger.info(f"Connecting to {grid_ip} to auto-detect latest WAPI version.")
        api_ver = get_latest_wapi_version(grid_ip, username, password, verify_ssl, None, logger)
        logger.info(f"Auto-detected WAPI version: {api_ver}")

    print(f"Connecting to Infoblox Grid at {grid_ip} (API {api_ver}).")
    client = InfobloxClient(grid_ip=grid_ip, username=username, password=password,
                            api_version=api_ver, verify_ssl=verify_ssl, logger=logger)
    if not client.test_connectivity():
        return

    print("\n================================================================================")
    print("DATA COLLECTION PHASE")
    print("================================================================================\n")

    grid_name = client.get_grid_identity().get("name", "N/A")
    print(f"Grid Name: {grid_name}")

    ver = client.get_software_version()
    print(f"Grid Version: {ver}")

    grid_lics = client.get_global_licenses()

    members = client.get_grid_members()
    print(f"Found {len(members)} member(s)")

    # ----------------------------------------------------------------
    # LICENSE DATA — single API call, keyed by hwid
    # member:license returns 'hwid' directly; no Base64 parsing needed.
    # ----------------------------------------------------------------
    licenses_by_hwid = client.get_licenses_by_hwid()
    print(f"Found licenses for {len(licenses_by_hwid)} unique serial number(s)")

    dns_scav, _  = client.get_global_dns_settings()
    _, dns_log   = client.get_global_dns_settings()
    dhcp_global  = client.get_global_dhcp_settings()
    dhcp_map     = client.get_dhcp_service_map()
    grid_counts  = client.get_grid_object_counts()
    dns_map      = client.get_dns_service_map()

    print(f"Found {grid_counts['views']} DNS view(s)")
    print(f"Nameserver Groups configured: {grid_counts['has_nsg']}")
    print(f"Found {grid_counts['folders']} smart folder(s)")
    print(f"Found {grid_counts['admins']} admin user(s)")

    print("\n================================================================================")
    print("PROCESSING MEMBER DATA")
    print("================================================================================\n")

    results: List[Dict[str, Any]] = []

    for idx, member in enumerate(members, 1):
        h_name = member.get("host_name", "N/A")
        print(f"[{idx}/{len(members)}] Processing member: {h_name}")

        # --- Role + IP (authoritative via capacityreport 'role' field) ---
        role_label, member_ip = client.get_member_role_and_ip(h_name)
        print(f"  - Role: {role_label} | IP: {member_ip or '(not available)'}")

        obj_count = client.get_member_object_count(h_name)
        print(f"  - Object count: {obj_count}")

        base_protocols: set = set()
        if dns_map.get(h_name, {}).get("enabled"):
            base_protocols.add("dns")
        if dhcp_map.get(h_name, {}).get("enabled"):
            base_protocols.add("dhcp")

        dhcp_hosts = client.get_active_dhcp_leases(dhcp_map.get(h_name, {}).get("ref"))

        # --- HA Pair: iterate ALL node_info entries ---
        node_info_data = member.get("node_info", [])
        if not isinstance(node_info_data, list) or not node_info_data:
            node_info_data = [{}]
        is_ha = len(node_info_data) == 2
        if is_ha:
            print(f"  - HA Pair detected: processing Active and Passive nodes.")

        for node_idx, node in enumerate(node_info_data):
            node_hwid = node.get("hwid", "")

            if is_ha:
                print(f"    - Node {node_idx+1}: ha_status={node.get('ha_status','N/A').upper()}, hwid={node_hwid or 'N/A'}")

            # ----------------------------------------------------------------
            # LICENSE LOOKUP — keyed by this node's hwid
            # Each physical node has its own hwid and its own license records.
            # ----------------------------------------------------------------
            node_lics   = licenses_by_hwid.get(node_hwid, [])
            lic_types   = [l.get("type", "").lower() for l in node_lics]
            features: set = set(lic_types)
            if any("response policy" in x or "rpz" in x for x in lic_types):
                features.add("rpz")
            if any("threat" in x or "analytics" in x for x in lic_types):
                features.add("threat insight")
            license_str = ", ".join(sorted(set(l.get("type", "") for l in node_lics if l.get("type"))))

            # --- Per-node performance metrics from service_status ---
            perf: Dict[str, Any] = {"cpu": "0%", "disk": "0%", "mem": "0%", "doh": False}
            node_protocols = set(base_protocols)
            for svc in node.get("service_status", []):
                s_name = svc.get("service")
                desc   = svc.get("description", "")
                status = svc.get("status")
                try:
                    if s_name == "CPU_USAGE":
                        perf["cpu"]  = desc.split(":")[-1].strip()
                    elif s_name == "DISK_USAGE":
                        perf["disk"] = desc.split("%")[0].strip() + "%"
                    elif s_name == "MEMORY":
                        perf["mem"]  = desc.split("%")[0].strip() + "%"
                    elif s_name == "DOT_DOH":
                        perf["doh"]  = (status == "WORKING")
                    if status in ("WORKING", "Running") and s_name in ("NTP", "TFTP", "HTTP", "FTP", "SNMP"):
                        node_protocols.add(s_name.lower())
                except Exception:
                    pass

            results.append({
                "Customer Name":              customer,
                "Employee Count":             employees,
                "grid_uuid":                  "na",
                "Member Serial Number":       node_hwid or "N/A",
                "Member Role":                role_label,
                "Member IP":                  member_ip,
                "Member Host Name":           h_name,
                "Member Model":               node.get("hwtype", "N/A"),
                "Member Platform":            (node.get("host_platform") or node.get("hwplatform") or node.get("hypervisor") or "N/A"),
                "Member ha Status":           node.get("ha_status", "Not Configured").replace("_", " ").title(),
                "Member Operational State":   "Running",
                "Member Version":             ver,
                "Member Version History":     "",
                "Member Protocol":            ", ".join(sorted(node_protocols)),
                "Member Object Count":        obj_count,
                "Member Enabled Features":    ", ".join(sorted(features)),
                "Member License ":            license_str,
                "Log Lease Events":           dhcp_global.get("log_lease_events", False),
                "Grid Name":                  grid_name,
                "Geo Country Name":           geo,
                "Collected At":               datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                "grid wide license con":      grid_lics,
                "Grid Enabled Feature":       "",
                "DNS DNS Scavenging":         dns_scav.get("scavenging_settings", {}).get("enable_scavenging", False),
                "DNS Query Response Logging": dns_log.get("logging_categories", {}).get("log_responses", False),
                "DNS Nameserver Groups":      grid_counts["has_nsg"],
                "DNS Anycast":                False,
                "DNS DNS Scavenging_2":       dns_scav.get("scavenging_settings", {}).get("enable_scavenging", False),
                "DNS DNS Over HTTPs":         perf["doh"],
                "DNS DTC":                    False,
                "DHCP Finger Printing":       dhcp_global.get("enable_fingerprint", False),
                "NIOS File Distribution":     False,
                "User Name":                  user_name,
                "DHCP IPv4 Hosts":            dhcp_hosts,
                "DNS DNS Views":              grid_counts["views"],
                "DTC Members Pct":            "Not used",
                "Grid Admin Count":           grid_counts["admins"],
                "NIOS Smart Folders":         grid_counts["folders"],
                "Member LPS Total":           "",
                "CPU Usage Ratio":            pct_to_ratio(perf["cpu"]),
                "Disk Usage Ratio":           pct_to_ratio(perf["disk"]),
                "Memeory Usage Ratio":        pct_to_ratio(perf["mem"]),
                "Member QPS":                 "",
            })

    if not results:
        logger.error("No data collected; skipping output.")
        return

    print("\n================================================================================")
    print("GENERATING OUTPUT FILES")
    print("================================================================================\n")

    base_name     = f"{APP_NAME}_{ts}"
    hashes: Dict[str, str] = {}
    created_files: List[str] = []

    if args.format in ("excel", "both") and XLSX_AVAILABLE:
        ep = os.path.join(out_dir, base_name + ".xlsx")
        write_excel(results, ep, logger)
        hashes[base_name + ".xlsx"] = sha256_file(ep)
        created_files.append(ep)
        print(f"Created: {ep}")

    if args.format in ("csv", "both"):
        cp = os.path.join(out_dir, base_name + ".csv")
        write_csv(results, cp)
        hashes[base_name + ".csv"] = sha256_file(cp)
        created_files.append(cp)
        print(f"Created: {cp}")

    summary = {
        "grid_ip": grid_ip, "api_version": api_ver, "grid_name": grid_name,
        "member_count": len(members), "row_count": len(results),
        "views": grid_counts["views"], "admins": grid_counts["admins"],
        "folders": grid_counts["folders"], "has_nsg": grid_counts["has_nsg"],
        "collected_at": datetime.now().isoformat(), "customer": customer,
        "geo": geo, "user": user_name, "format": args.format,
        "log_file": log_path, "hashes": hashes,
    }
    sp = os.path.join(out_dir, base_name + ".summary.json")
    with open(sp, "w") as sf:
        json.dump(summary, sf, indent=2)

    print(f"\nTotal logical members : {len(members)}")
    print(f"Total physical rows   : {len(results)}")
    print(f"Output directory      : {os.path.abspath(out_dir)}")
    print("\nLogging out of WAPI session.")
    client.logout()


# ------------------------- CLI -------------------------
def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Infoblox NIOS Health Audit (v22)")
    p.add_argument("--grid-ip")
    p.add_argument("--customer")
    p.add_argument("--employees",       type=int)
    p.add_argument("--geo",             choices=["EMEA", "AMS", "APJ"])
    p.add_argument("--user")
    p.add_argument("--format",          choices=["excel", "csv", "both"], default="both")
    p.add_argument("--log")
    p.add_argument("--insecure",        action="store_true")
    p.add_argument("--silent-warnings", action="store_true")
    p.add_argument("--username")
    p.add_argument("--password")
    p.add_argument("--api-version")
    p.add_argument("--debug",           action="store_true")
    return p


if __name__ == "__main__":
    collect_and_report(build_arg_parser().parse_args())
