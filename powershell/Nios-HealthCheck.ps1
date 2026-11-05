<#
.SYNOPSIS
    Infoblox NIOS Grid Health Check - PowerShell port (single-file edition).

.DESCRIPTION
    Read-only collection of the data typically gathered for an Infoblox NIOS
    Grid Health Check, via the NIOS WAPI. This is a PowerShell port of
    nios_health_check.py (Production v28). It is intended for environments
    (e.g. government-furnished Windows machines) where Python is not
    available but Windows PowerShell 5.1 is.

    Every WAPI call is an HTTP GET. The ONLY exception is one HTTP POST to
    the WAPI "logout" endpoint at the end of a run, which just releases the
    session token. Nothing on the Grid is ever created, modified or deleted.
    The only host this script talks to is the Grid Manager you point it at.
    Credentials are held in memory only and are never written to disk or
    to the log.

    OUTPUT (written to a timestamped folder under the current directory):
      nios_health_audit_<ts>.csv              core 43-column report
      nios_health_audit_<ts>.summary.json     run summary (+ SHA-256 of outputs)
      nios_health_audit_<ts>.log.jsonl        structured run log
    Optional add-ons (default OFF, each prompts unless a switch is given):
      -CapacityReport  ..._grid_capacity_summary.csv, ..._grid_capacity_objects.csv
      -TopologyViz     ..._topology.html (self-contained) and ..._topology.json
      -LicenseReport   ..._license_report.csv and ..._license_report.json

    There is no Excel output in this port (no external modules are needed).
    CSV files are UTF-8; on Windows PowerShell 5.1 they carry a BOM.

    COMPATIBILITY / DESIGN NOTES
      * Targets Windows PowerShell 5.1 (also runs on PowerShell 7+).
      * Avoids Invoke-Expression, COM and external modules. The only
        Add-Type use is a 6-line certificate callback compiled when
        -Insecure is used on Windows PowerShell 5.1 in FullLanguage mode;
        it is skipped entirely otherwise, so the script stays as friendly
        as possible to Constrained Language Mode and to security review. A few .NET calls may still be
        restricted by local policy; see Troubleshooting in the README.

.PARAMETER GridIp
    Grid Manager IP address or hostname.
.PARAMETER Username
    WAPI username.
.PARAMETER Password
    WAPI password, as a SecureString (recommended) or plain string. If
    omitted you are prompted securely.
.PARAMETER ApiVersion
    Force a WAPI version (e.g. v2.12). Auto-detected by default.
.PARAMETER Customer
    Customer name used in the report.
.PARAMETER Employees
    Employee count.
.PARAMETER Geo
    Region: EMEA, AMS or APJ.
.PARAMETER User
    Name of the person running the Health Check.
.PARAMETER Log
    Custom log file name (created inside the output folder).
.PARAMETER Insecure
    Bypass TLS certificate verification (lab / self-signed certs only).
.PARAMETER IncludeIp
    Include Member IP addresses in column F (skips the prompt).
.PARAMETER NoIncludeIp
    Exclude Member IP addresses (skips the prompt).
.PARAMETER CapacityReport
    Generate the Grid Member Capacity report (skips the prompt).
.PARAMETER NoCapacityReport
    Skip the Grid Member Capacity report (skips the prompt).
.PARAMETER TopologyViz
    Generate the DNS Topology Visualization (skips the prompt).
.PARAMETER NoTopologyViz
    Skip the DNS Topology Visualization (skips the prompt).
.PARAMETER LicenseReport
    Generate the Grid License Report (skips the prompt).
.PARAMETER NoLicenseReport
    Skip the Grid License Report (skips the prompt).
.PARAMETER PageSize
    WAPI page size for list queries (default 500). Set this to a small
    number (e.g. 2) on a small test Grid to exercise the paging code.
.PARAMETER DebugMode
    Verbose debug logging.

.EXAMPLE
    .\Nios-HealthCheck.ps1

.EXAMPLE
    .\Nios-HealthCheck.ps1 -GridIp 10.10.10.10 -Username admin `
        -Customer "Acme Corp" -Employees 2500 -Geo AMS -User "Jane Doe" `
        -NoIncludeIp -NoCapacityReport -TopologyViz -LicenseReport

.NOTES
    Version: ps-v28.2 (tracks nios_health_check.py v28)
    Based on nios_health_check.py by Josh Nolan (MIT License).
    Not an officially supported Infoblox tool; see README.md.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$GridIp,
    [string]$Username,
    [object]$Password,
    [string]$ApiVersion,
    [string]$Customer,
    [int]$Employees,
    [ValidateSet('EMEA', 'AMS', 'APJ')]
    [string]$Geo,
    [string]$User,
    [string]$Log,
    [switch]$Insecure,
    [switch]$IncludeIp,
    [switch]$NoIncludeIp,
    [switch]$CapacityReport,
    [switch]$NoCapacityReport,
    [switch]$TopologyViz,
    [switch]$NoTopologyViz,
    [switch]$LicenseReport,
    [switch]$NoLicenseReport,
    [ValidateRange(1, 1000)]
    [int]$PageSize = 500,
    [switch]$DebugMode
)

# =============================================================================
# SECTION 1 - CORE HEALTH CHECK
# =============================================================================

# ------------------------- Constants -------------------------
$script:BoundParams = $PSBoundParameters
$script:VERSION = 'ps-v28.2'
$script:APP_NAME            = 'nios_health_audit'
$script:DEFAULT_API_VERSION = 'v2.12'
$script:REQUEST_TIMEOUT     = 30
$script:RETRY_TOTAL         = 3
$script:RETRY_BACKOFF       = 0.3

# DO NOT MODIFY: exact 43-column format required by the health check portal.
# (Note the intentional duplicate "DNS DNS Scavenging", the trailing space in
# "Member License " and the "Memeory" spelling - they match the Python tool.)
$script:HEADER_43 = @(
    'Customer Name', 'Employee Count', 'grid_uuid', 'Member Serial Number', 'Member Role',
    'Member IP', 'Member Host Name', 'Member Model', 'Member Platform', 'Member ha Status',
    'Member Operational State', 'Member Version', 'Member Version History', 'Member Protocol',
    'Member Object Count', 'Member Enabled Features', 'Member License ', 'Log Lease Events',
    'Grid Name', 'Geo Country Name', 'Collected At', 'grid wide license con', 'Grid Enabled Feature',
    'DNS DNS Scavenging', 'DNS Query Response Logging', 'DNS Nameserver Groups', 'DNS Anycast',
    'DNS DNS Scavenging', 'DNS DNS Over HTTPs', 'DNS DTC', 'DHCP Finger Printing',
    'NIOS File Distribution', 'User Name', 'DHCP IPv4 Hosts', 'DNS DNS Views', 'DTC Members Pct',
    'Grid Admin Count', 'NIOS Smart Folders', 'Member LPS Total', 'CPU Usage Ratio',
    'Disk Usage Ratio', 'Memeory Usage Ratio', 'Member QPS'
)

# Run state (set in Invoke-NiosHealthCheck)
$script:LogPath        = ''
$script:DebugEnabled   = [bool]$DebugMode
$script:Credential     = $null
$script:WebSession     = $null
$script:SkipCertCheck  = $false
$script:BaseUrl        = ''
$script:GridHost       = ''
# NOTE: parameters live in script scope, so $script:PageSize IS the -PageSize
# parameter; run-state variables must therefore never reuse a parameter name.

# ------------------------- Logging -------------------------
function Write-Log {
    param([string]$Level, [string]$Message)
    if ($Level -eq 'DEBUG' -and -not $script:DebugEnabled) { return }
    $color = 'Gray'
    if ($Level -eq 'ERROR') { $color = 'Red' }
    elseif ($Level -eq 'WARNING') { $color = 'Yellow' }
    elseif ($Level -eq 'DEBUG') { $color = 'DarkGray' }
    Write-Host ('{0}: {1}' -f $Level, $Message) -ForegroundColor $color
    if ($script:LogPath) {
        $rec = [ordered]@{
            ts     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.ffffff') + '+00:00'
            level  = $Level
            msg    = $Message
            logger = 'bloxconnect'
        }
        try {
            Add-Content -Path $script:LogPath -Value (ConvertTo-Json -InputObject $rec -Compress) -Encoding UTF8
        } catch { }
    }
}

# ------------------------- Small helpers -------------------------
# Always returns a real array (never $null, never unrolled) when called as
#   $x = ConvertTo-Array $value
function ConvertTo-Array {
    param($Value)
    if ($null -eq $Value) { return , @() }
    if ($Value -is [System.Array]) { return , $Value }
    return , @($Value)
}

# $null -> default (mirrors dict.get(key, default) for our purposes)
function Nz {
    param($Value, $Default)
    if ($null -eq $Value) { return $Default }
    return $Value
}

# Python-style truthiness (used where the original relies on `x or y`).
function Test-Truthy {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return ($Value.Length -gt 0) }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [System.Array]) { return ($Value.Count -gt 0) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return ($Value -ne 0)
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        return (@($Value.PSObject.Properties).Count -gt 0)
    }
    return $true
}

# Ordinal (code-point) sort + exact de-duplication, matching Python's
# sorted(set(...)). Sort-Object is culture-aware and case-insensitive, which
# would change the order of license / protocol strings.
function Get-OrdinalSortedUnique {
    param($Items)
    $list = @()
    foreach ($i in (ConvertTo-Array $Items)) {
        if ($null -ne $i) { $list += [string]$i }
    }
    $n = $list.Count
    for ($i = 1; $i -lt $n; $i++) {
        $key = $list[$i]
        $j = $i - 1
        while ($j -ge 0 -and [string]::CompareOrdinal($list[$j], $key) -gt 0) {
            $list[$j + 1] = $list[$j]
            $j--
        }
        $list[$j + 1] = $key
    }
    $out = @()
    for ($i = 0; $i -lt $n; $i++) {
        if ($i -eq 0 -or $list[$i] -cne $list[$i - 1]) { $out += $list[$i] }
    }
    return , $out
}

# Python str.title() for ASCII text: "NOT_CONFIGURED" -> "Not Configured".
function ConvertTo-TitleCase {
    param([string]$Text)
    $res = ''
    $prevLetter = $false
    foreach ($ch in $Text.ToCharArray()) {
        $c = [string]$ch
        if ($c -match '^[A-Za-z]$') {
            if ($prevLetter) { $res += $c.ToLowerInvariant() } else { $res += $c.ToUpperInvariant() }
            $prevLetter = $true
        } else {
            $res += $c
            $prevLetter = $false
        }
    }
    return $res
}

function ConvertTo-PctRatio {
    param([string]$Text)
    try {
        $t = ($Text -replace '%', '').Trim()
        return ([double]$t / 100.0)
    } catch {
        return [double]0
    }
}

function Resolve-GeoValue {
    param([string]$Value)
    $v = ([string]$Value).Trim().ToUpperInvariant()
    if (@('EMEA', 'AMS', 'APJ') -contains $v) { return $v }
    return 'AMS'
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
}

function ConvertTo-UrlPart {
    param([string]$Text)
    return [System.Uri]::EscapeDataString($Text)
}

# ------------------------- Version helpers -------------------------
# 'v2.14' / '2.14.1' -> @(2,14). Returns @(0,0) on failure.
function ConvertTo-WapiVersionParts {
    param([string]$Version)
    try {
        $parts = @()
        foreach ($p in ($Version.ToLowerInvariant().TrimStart('v') -split '\.')) {
            if ($p -match '^\d+$') { $parts += [int]$p }
        }
        $major = 0; $minor = 0
        if ($parts.Count -ge 1) { $major = $parts[0] }
        if ($parts.Count -ge 2) { $minor = $parts[1] }
        return , @($major, $minor)
    } catch {
        return , @(0, 0)
    }
}

# grid.uuid is exposed starting at WAPI v2.14 (NIOS 9.1.0).
function Test-WapiSupportsGridUuid {
    param([string]$ApiVer)
    $p = ConvertTo-WapiVersionParts $ApiVer
    if ($p[0] -gt 2) { return $true }
    if ($p[0] -eq 2 -and $p[1] -ge 14) { return $true }
    return $false
}

# ------------------------- TLS / session setup -------------------------
function Initialize-Tls {
    param([bool]$BypassVerification)
    $script:SkipCertCheck = $false
    $major = $PSVersionTable.PSVersion.Major
    if ($major -lt 6) {
        # Windows PowerShell 5.1: offer TLS 1.2 (and 1.3 where this .NET build knows it).
        try {
            $proto = [System.Net.SecurityProtocolType]::Tls12
            try { $proto = [System.Net.SecurityProtocolType]'Tls12,Tls13' } catch { }
            [System.Net.ServicePointManager]::SecurityProtocol = $proto
        } catch {
            Write-Log 'DEBUG' ('Could not set TLS protocols explicitly: ' + $_.Exception.Message)
        }
        Write-Log 'DEBUG' ('SecurityProtocol = ' + [string][System.Net.ServicePointManager]::SecurityProtocol)
    }
    if ($BypassVerification) {
        if ($major -ge 6) {
            $script:SkipCertCheck = $true
            return
        }
        $done = $false
        # A PowerShell scriptblock used as the certificate callback is unreliable on
        # 5.1 (the handshake runs on a thread with no runspace and fails with
        # "An unexpected error occurred on a send"). In FullLanguage mode a tiny
        # compiled callback is used instead. Constrained Language Mode blocks
        # Add-Type, so there it falls back to the scriptblock (best effort).
        if ($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage') {
            try {
                if (-not ('NiosTrustAllCerts' -as [type])) {
                    Add-Type -TypeDefinition @'
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class NiosTrustAllCerts {
    public static bool Accept(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) { return true; }
    public static RemoteCertificateValidationCallback Callback { get { return Accept; } }
}
'@
                }
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = [NiosTrustAllCerts]::Callback
                $done = $true
                Write-Log 'DEBUG' 'TLS certificate verification bypassed (compiled callback).'
            } catch {
                Write-Log 'DEBUG' ('Compiled TLS callback unavailable: ' + $_.Exception.Message)
            }
        }
        if (-not $done) {
            try {
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
                Write-Log 'WARNING' 'Using a scriptblock TLS callback (best effort); if connections fail with "unexpected error occurred on a send", install the Grid certificate (or its CA) in the Windows certificate store and re-run without -Insecure.'
            } catch {
                Write-Log 'ERROR' ('Could not bypass TLS verification in this session (' + $_.Exception.Message + '). ' +
                    'This is expected in Constrained Language Mode. Install the Grid certificate (or its CA) in the ' +
                    'Windows certificate store instead and re-run without -Insecure.')
            }
        }
    }
}

# ------------------------- HTTP / WAPI -------------------------
# Single HTTP call with retries on connection errors and 429/5xx (GET only),
# mirroring the urllib3 Retry configuration of the Python tool.
function Invoke-WapiHttp {
    param([string]$Uri, [string]$Method = 'GET')
    $maxRetries = 0
    if ($Method -eq 'GET') { $maxRetries = $script:RETRY_TOTAL }
    $attempt = 0
    while ($true) {
        $splat = @{
            Uri             = $Uri
            Method          = $Method
            UseBasicParsing = $true
            TimeoutSec      = $script:REQUEST_TIMEOUT
            Credential      = $script:Credential
            Headers         = @{ Accept = 'application/json' }
            ErrorAction     = 'Stop'
        }
        if ($script:SkipCertCheck) { $splat['SkipCertificateCheck'] = $true }
        if ($null -ne $script:WebSession) {
            $splat['WebSession'] = $script:WebSession
        } else {
            $splat['SessionVariable'] = 'wapiSession'
        }
        try {
            $resp = Invoke-WebRequest @splat
            if ($null -eq $script:WebSession -and $null -ne $wapiSession) { $script:WebSession = $wapiSession }
            return [pscustomobject]@{ Ok = $true; Status = [int]$resp.StatusCode; Content = [string]$resp.Content; Error = ''; Tls = $false }
        } catch {
            $ex = $_.Exception
            $status = 0
            if ($null -ne $ex.Response) {
                try { $status = [int]$ex.Response.StatusCode } catch { $status = 0 }
            }
            $msg = [string]$ex.Message
            $inner = $ex.InnerException
            while ($null -ne $inner) { $msg += ' | ' + [string]$inner.Message; $inner = $inner.InnerException }
            $isTls = ($status -eq 0) -and ($msg -match 'SSL|TLS|trust relationship|certificate|secure channel')
            $retryable = (-not $isTls) -and (($status -eq 0) -or (@(429, 500, 502, 503, 504) -contains $status))
            if ($retryable -and $attempt -lt $maxRetries) {
                $attempt++
                Start-Sleep -Milliseconds ([int](1000 * $script:RETRY_BACKOFF * (1 -shl ($attempt - 1))))
                continue
            }
            return [pscustomobject]@{ Ok = $false; Status = $status; Content = ''; Error = $msg; Tls = $isTls }
        }
    }
}

# GET a WAPI object type. Always returns an ARRAY of result objects (empty on
# failure or no match) when called as:  $x = Invoke-WapiGet 'member' @{...}
# $script:LastGetFailed is set so callers can tell failure from "no objects".
# -Paged uses WAPI paging (_paging/_max_results/_page_id) so large Grids do not
# hit the WAPI result-size limit.
function Invoke-WapiGet {
    param([string]$Endpoint, [hashtable]$Query, [switch]$Paged)
    $items = New-Object System.Collections.ArrayList
    $script:LastGetFailed = $false
    $pageId = $null
    do {
        $q = [ordered]@{}
        if ($Query) { foreach ($k in $Query.Keys) { $q[[string]$k] = [string]$Query[$k] } }
        if ($Paged) {
            $q['_paging'] = '1'
            $q['_return_as_object'] = '1'
            $q['_max_results'] = [string]$script:PageSize
            if ($pageId) { $q['_page_id'] = [string]$pageId }
        }
        $url = $script:BaseUrl + $Endpoint
        if ($q.Count -gt 0) {
            $pairs = @()
            foreach ($k in $q.Keys) { $pairs += ((ConvertTo-UrlPart $k) + '=' + (ConvertTo-UrlPart $q[$k])) }
            $url = $url + '?' + ($pairs -join '&')
        }
        $pageId = $null
        $r = Invoke-WapiHttp -Uri $url
        if (-not $r.Ok) {
            $script:LastGetFailed = $true
            if ($r.Tls) {
                Write-Log 'ERROR' ('TLS error on {0}: {1}' -f $Endpoint, $r.Error)
            } else {
                if ($r.Status -gt 0) { Write-Log 'WARNING' ('GET {0} returned {1}' -f $Endpoint, $r.Status) }
                Write-Log 'ERROR' ('GET {0} failed: {1}' -f $Endpoint, $r.Error)
            }
            break
        }
        $parsed = $null
        if ($r.Content -and $r.Content.Trim().Length -gt 0) {
            try {
                $parsed = $r.Content | ConvertFrom-Json
            } catch {
                $script:LastGetFailed = $true
                Write-Log 'ERROR' ('GET {0} failed: invalid JSON in response ({1})' -f $Endpoint, $_.Exception.Message)
                break
            }
        }
        if ($null -eq $parsed) {
            # nothing returned
        } elseif ($parsed -is [System.Array]) {
            foreach ($i in $parsed) { [void]$items.Add($i) }
        } elseif ($null -ne $parsed.PSObject.Properties['result']) {
            $res = $parsed.result
            if ($res -is [System.Array]) {
                foreach ($i in $res) { [void]$items.Add($i) }
            } elseif ($null -ne $res) {
                [void]$items.Add($res)
            }
            if ($Paged -and $null -ne $parsed.PSObject.Properties['next_page_id'] -and $parsed.next_page_id) {
                $pageId = [string]$parsed.next_page_id
            }
        } else {
            [void]$items.Add($parsed)
        }
    } while ($pageId)
    return , $items.ToArray()
}

# Latest WAPI version advertised by the Grid (falls back to v2.12).
function Get-LatestWapiVersion {
    param([string]$Ip)
    $url = 'https://{0}/wapi/v1.0/?_schema' -f $Ip
    $r = Invoke-WapiHttp -Uri $url
    if ($r.Ok) {
        try {
            $schema = $r.Content | ConvertFrom-Json
            $versions = ConvertTo-Array $schema.supported_versions
            $best = ''
            $bestKey = -1
            foreach ($v in $versions) {
                $s = [string]$v
                $p = @()
                foreach ($x in ($s.ToLowerInvariant().TrimStart('v') -split '\.')) {
                    if ($x -match '^\d+$') { $p += [int]$x }
                }
                if ($p.Count -eq 0) { continue }
                $a = $p[0]; $b = 0; $c = 0
                if ($p.Count -ge 2) { $b = $p[1] }
                if ($p.Count -ge 3) { $c = $p[2] }
                $key = ($a * 1000000) + ($b * 1000) + $c
                if ($key -gt $bestKey) { $bestKey = $key; $best = $s }
            }
            if ($best) {
                if ($best.StartsWith('v')) { return $best }
                return ('v' + $best)
            }
        } catch {
            Write-Log 'WARNING' ('Could not auto-detect WAPI version (defaulting to {0}): {1}' -f $script:DEFAULT_API_VERSION, $_.Exception.Message)
            return $script:DEFAULT_API_VERSION
        }
    }
    Write-Log 'WARNING' ('Could not auto-detect WAPI version (defaulting to {0}): {1}' -f $script:DEFAULT_API_VERSION, $r.Error)
    return $script:DEFAULT_API_VERSION
}

# ------------------------- WAPI client functions (all GET) -------------------------
function Test-NiosConnectivity {
    $d = Invoke-WapiGet 'grid' @{ '_return_fields' = 'name' }
    $ok = ($d.Count -gt 0)
    if (-not $ok) { Write-Log 'ERROR' 'Connectivity test failed. Check credentials and TLS (-Insecure).' }
    return $ok
}

function Get-NiosGridName {
    $d = Invoke-WapiGet 'grid' @{ '_return_fields' = 'name' }
    if ($d.Count -gt 0 -and $d[0].name) { return [string]$d[0].name }
    return 'N/A'
}

# grid.uuid on WAPI >= v2.14 (NIOS 9.1.0+); otherwise lpc_uid; otherwise 'na'.
function Get-NiosGridUuid {
    param([string]$ApiVer)
    try {
        if (Test-WapiSupportsGridUuid $ApiVer) {
            $d = Invoke-WapiGet 'grid' @{ '_return_fields' = 'uuid' }
            if ($d.Count -gt 0 -and $d[0].uuid) {
                Write-Log 'INFO' ('grid_uuid (uuid) retrieved via WAPI {0}' -f $ApiVer)
                return [string]$d[0].uuid
            }
            Write-Log 'WARNING' 'grid.uuid not returned; falling back to lpc_uid lookup'
        }
        $d = Invoke-WapiGet 'grid:license_pool_container' @{ '_return_fields' = 'lpc_uid' }
        if ($d.Count -gt 0 -and $d[0].lpc_uid) {
            Write-Log 'INFO' 'grid_uuid (lpc_uid fallback) retrieved'
            return [string]$d[0].lpc_uid
        }
    } catch {
        Write-Log 'ERROR' ('get_grid_uuid failed: {0}' -f $_.Exception.Message)
    }
    return 'na'
}

# { host_name = ipv4addr } from member:dns (only members running DNS).
function Get-NiosMemberIpv4Map {
    $map = @{}
    try {
        $d = Invoke-WapiGet 'member:dns' @{ '_return_fields' = 'host_name,ipv4addr' } -Paged
        foreach ($item in $d) {
            if ($item.host_name) { $map[[string]$item.host_name] = [string](Nz $item.ipv4addr '') }
        }
        Write-Log 'INFO' ('get_member_ipv4_map: {0} host(s) with IP' -f $map.Count)
    } catch {
        Write-Log 'ERROR' ('get_member_ipv4_map failed: {0}' -f $_.Exception.Message)
        return @{}
    }
    return $map
}

# { host_name = vip_setting.address } - universal for every member type.
function Get-NiosMemberVipMap {
    $map = @{}
    try {
        $d = Invoke-WapiGet 'member' @{ '_return_fields' = 'host_name,vip_setting' } -Paged
        foreach ($item in $d) {
            $addr = ''
            if ($null -ne $item.vip_setting -and $item.vip_setting.address) { $addr = [string]$item.vip_setting.address }
            if ($item.host_name -and $addr) { $map[[string]$item.host_name] = $addr }
        }
        Write-Log 'INFO' ('get_member_vip_map: {0} host(s) with IP (universal fallback)' -f $map.Count)
    } catch {
        Write-Log 'ERROR' ('get_member_vip_map failed: {0}' -f $_.Exception.Message)
        return @{}
    }
    return $map
}

function Get-NiosSoftwareVersion {
    $d = Invoke-WapiGet 'upgradestatus' @{ 'type' = 'GRID'; '_return_fields' = 'current_version_summary' }
    if ($d.Count -gt 0) {
        $full = [string](Nz $d[0].current_version_summary 'N/A')
        if ($full.Contains('-')) { return ($full -split '-')[0] }
        return $full
    }
    return 'N/A'
}

function Get-NiosGlobalLicenseTypes {
    $d = Invoke-WapiGet 'license:gridwide' @{ '_return_fields' = 'type' } -Paged
    $types = @()
    foreach ($l in $d) { if ($l.type) { $types += [string]$l.type } }
    return (Get-OrdinalSortedUnique $types) -join ', '
}

# Full Grid-Wide license records for the license report.
function Get-NiosGlobalLicensesDetailed {
    # license:gridwide does not have a "kind" field (member:license does); asking for it
    # makes the WAPI answer 400, so only the grid-wide fields are requested. If that
    # still fails, fall back to the object's default field set.
    $d = Invoke-WapiGet 'license:gridwide' @{ '_return_fields' = 'type,expiration_status,expiry_date,limit' } -Paged
    if ($script:LastGetFailed) {
        Write-Log 'WARNING' 'license:gridwide: retrying with the default field set.'
        $d = Invoke-WapiGet 'license:gridwide' @{} -Paged
    }
    Write-Log 'INFO' ('get_global_licenses_detailed: {0} grid-wide license(s) found' -f $d.Count)
    return , $d
}

function Get-NiosMembers {
    # ipv4addr excluded on member - causes 400 on WAPI v2.14; member:dns is used instead.
    $d = Invoke-WapiGet 'member' @{ '_return_fields+' = 'node_info,service_status,host_name,master_candidate' } -Paged
    return , $d
}

# Role from capacityreport + legacy IP parse. Returns @{ Role; Ip }.
function Get-NiosMemberRoleAndIp {
    param([string]$HostName)
    $d = Invoke-WapiGet 'capacityreport' @{ 'name' = $HostName; '_return_fields' = 'name,role' }
    if ($d.Count -eq 0) {
        Write-Log 'INFO' ("capacityreport '{0}': no data (offline?) - defaulting to Member" -f $HostName)
        return @{ Role = 'Member'; Ip = '' }
    }
    $entry = $d[0]
    $raw = ([string]$entry.role).Trim().ToLowerInvariant()
    $label = 'Member'
    if ($raw -eq 'grid master') { $label = 'GM' }
    elseif ($raw -eq 'grid master candidate') { $label = 'GMC' }
    $ip = ''
    $ref = [string]$entry._ref
    if ($ref -match ':([^/]+)$') {
        $cand = $Matches[1]
        if ($cand -match '^\d{1,3}(\.\d{1,3}){3}$') { $ip = $cand }
    }
    Write-Log 'DEBUG' ("capacityreport '{0}': role='{1}' -> '{2}', ip='{3}'" -f $HostName, $raw, $label, $ip)
    return @{ Role = $label; Ip = $ip }
}

# { hwid = @(license records) } from member:license.
function Get-NiosLicensesByHwid {
    $d = Invoke-WapiGet 'member:license' @{ '_return_fields' = 'type,kind,limit,expiration_status,expiry_date,hwid' } -Paged
    $result = [ordered]@{}
    foreach ($lic in $d) {
        $hwid = [string]$lic.hwid
        if ($hwid) {
            if ($result.Contains($hwid)) { $result[$hwid] = @($result[$hwid]) + @($lic) }
            else { $result[$hwid] = @($lic) }
        } else {
            Write-Log 'DEBUG' ('member:license has no hwid: {0}' -f $lic._ref)
        }
    }
    Write-Log 'INFO' ('get_licenses_by_hwid: licenses found for {0} hwid(s)' -f $result.Count)
    return $result
}

function Get-NiosMemberObjectCount {
    param([string]$HostName)
    $d = Invoke-WapiGet 'capacityreport' @{ 'name' = $HostName; '_return_fields' = 'object_counts' }
    if ($d.Count -eq 0) { return 0 }
    try {
        $total = [long]0
        foreach ($o in (ConvertTo-Array $d[0].object_counts)) {
            if ($null -ne $o.count) { $total += [long]$o.count }
        }
        return $total
    } catch {
        return 0
    }
}

function Get-NiosActiveDhcpLeases {
    param([string]$Ref)
    if (-not $Ref) { return 0 }
    try {
        $d = Invoke-WapiGet 'dhcp:statistics' @{ 'statistics_object' = $Ref; '_return_fields' = 'static_hosts,dynamic_hosts' }
        if ($d.Count -eq 0) { return 0 }
        $a = [long]0; $b = [long]0
        if ($d[0].static_hosts) { $a = [long]$d[0].static_hosts }
        if ($d[0].dynamic_hosts) { $b = [long]$d[0].dynamic_hosts }
        return ($a + $b)
    } catch {
        return 0
    }
}

# Returns @{ Scavenging = <scavenging_settings obj or $null>; Logging = <logging_categories obj or $null> }
function Get-NiosGlobalDnsSettings {
    $s = Invoke-WapiGet 'grid:dns' @{ '_return_fields' = 'scavenging_settings' }
    $l = Invoke-WapiGet 'grid:dns' @{ '_return_fields' = 'logging_categories' }
    $scav = $null; $logs = $null
    if ($s.Count -gt 0) { $scav = $s[0].scavenging_settings }
    if ($l.Count -gt 0) { $logs = $l[0].logging_categories }
    return @{ Scavenging = $scav; Logging = $logs }
}

# Returns @{ LogLeaseEvents = <bool>; EnableFingerprint = <bool> }
function Get-NiosGlobalDhcpSettings {
    $p = Invoke-WapiGet 'grid:dhcpproperties' @{ '_return_fields' = 'log_lease_events' }
    $f = Invoke-WapiGet 'grid:dhcpproperties' @{ '_return_fields' = 'enable_fingerprint' }
    $lle = $false; $fp = $false
    if ($p.Count -gt 0 -and $null -ne $p[0].log_lease_events) { $lle = $p[0].log_lease_events }
    if ($f.Count -gt 0 -and $null -ne $f[0].enable_fingerprint) { $fp = $f[0].enable_fingerprint }
    return @{ LogLeaseEvents = $lle; EnableFingerprint = $fp }
}

function Get-NiosDhcpServiceMap {
    $map = @{}
    $d = Invoke-WapiGet 'member:dhcpproperties' @{ '_return_fields' = 'host_name,enable_dhcp' } -Paged
    foreach ($i in $d) {
        if ($i.host_name) { $map[[string]$i.host_name] = @{ Ref = $i._ref; Enabled = (Nz $i.enable_dhcp $false) } }
    }
    return $map
}

function Get-NiosDnsServiceMap {
    $map = @{}
    $d = Invoke-WapiGet 'member:dns' @{ '_return_fields' = 'host_name,enable_dns' } -Paged
    foreach ($i in $d) {
        if ($i.host_name) { $map[[string]$i.host_name] = @{ Enabled = (Nz $i.enable_dns $false) } }
    }
    return $map
}

function Get-NiosGridObjectCounts {
    $v = Invoke-WapiGet 'view' @{} -Paged
    $n = Invoke-WapiGet 'nsgroup' @{} -Paged
    $f = Invoke-WapiGet 'smartfolder:global' @{} -Paged
    $a = Invoke-WapiGet 'adminuser' @{} -Paged
    return @{ Views = $v.Count; HasNsg = ($n.Count -gt 0); Folders = $f.Count; Admins = $a.Count }
}

# Releases the WAPI session token (the one and only POST).
function Invoke-NiosLogout {
    $r = Invoke-WapiHttp -Uri ($script:BaseUrl + 'logout') -Method 'POST'
    if ($r.Ok) {
        Write-Log 'INFO' 'WAPI session logged out.'
    } elseif ($r.Status -gt 0) {
        Write-Log 'WARNING' ('WAPI logout returned {0}' -f $r.Status)
    } else {
        Write-Log 'ERROR' ('WAPI logout failed: {0}' -f $r.Error)
    }
}

# ------------------------- Output writers -------------------------
# CSV quoting matches Python's csv.writer (QUOTE_MINIMAL, CRLF line ends).
function ConvertTo-CsvField {
    param($Value)
    if ($null -eq $Value) { return '' }
    $s = ''
    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        $s = [string]$Value
        if ($s -notmatch '[.eE]') { $s = $s + '.0' }
    } elseif ($Value -is [bool]) {
        if ($Value) { $s = 'True' } else { $s = 'False' }
    } else {
        $s = [string]$Value
    }
    if ($s -match '[",\r\n]') { $s = '"' + $s.Replace('"', '""') + '"' }
    return $s
}

function Write-CsvFile {
    param([string]$Path, $Header, $Rows)
    $lines = @()
    $h = @()
    foreach ($c in (ConvertTo-Array $Header)) { $h += (ConvertTo-CsvField $c) }
    $lines += ($h -join ',')
    foreach ($r in $Rows) {
        $f = @()
        foreach ($v in $r) { $f += (ConvertTo-CsvField $v) }
        $lines += ($f -join ',')
    }
    $text = ($lines -join "`r`n") + "`r`n"
    Set-Content -Path $Path -Value $text -Encoding UTF8 -NoNewline
}

function Write-JsonFile {
    param([string]$Path, $Object, [int]$Depth = 10)
    $json = ConvertTo-Json -InputObject $Object -Depth $Depth
    Set-Content -Path $Path -Value $json -Encoding UTF8
}

# 'now' as local 'yyyy-MM-dd HH:mm:ss'
function Get-NowText {
    return (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
}

# =============================================================================
# END SECTION 1 (helpers) - the member-processing orchestration is further down
# =============================================================================

# Capacity object-type -> bucket (lifted verbatim from the Python tool; these
# names are matched case-sensitively with -ccontains).
$script:CAPACITY_DDI_TYPES = @(
    'A Record/Substitute (A Record) Rule/Substitute (IPv4 Address) Rule',
    'Access Control Item',
    'CNAME Record/Substitute Domain Name/Block/Passthru Rule',
    'DHCP Custom Option',
    'DHCP Range',
    'DNS Traffic Control HTTP Monitor',
    'DNS Traffic Control ICMP Monitor',
    'DNS Traffic Control PDP Monitor',
    'DNS Traffic Control SIP Monitor',
    'DNS Traffic Control SNMP Monitor',
    'Host Alias',
    'Network',
    'Network Container',
    'PTR Record/Substitute (PTR Record) Rule',
    'Router',
    'SVCB Record/Substitute (SVCB Record) Rule',
    'TXT Record/Substitute (TXT Record) Rule',
    'View',
    'Zone',
    'Zone SOA'
)
$script:CAPACITY_ACTIVE_IP_TYPES = @(
    'Fixed Address',
    'Host',
    'Host Address'
)

# =============================================================================
# SECTION 2 - OPTIONAL: GRID MEMBER CAPACITY REPORT  (-CapacityReport)
# Adapted (via the Python tool) from nios_grid_capacity.py by Pat Vogelsang
# (MIT License; see NOTICE.md in the original repository).
# Network footprint: one extra read-only GET per member against `capacityreport`.
# Output: two CSV files (the Python tool writes one two-sheet workbook).
# =============================================================================
$script:CAPACITY_SUMMARY_HEADER = @(
    'Member Host Name', 'Node HWID', 'Node HA Status', 'Node Platform',
    'Capacity Role', 'Hardware Type', 'Max Capacity', 'Total Objects',
    'Percent Used', 'Estimated DDI Objects', 'Estimated Active IP Objects',
    'Estimated Total UDDI Objects', 'Report Found'
)

function Get-CapacityEstimates {
    param($ObjectCounts)
    $ddi = [long]0
    $active = [long]0
    foreach ($e in (ConvertTo-Array $ObjectCounts)) {
        if ($null -eq $e) { continue }
        $type = [string]$e.type_name
        $count = [long]0
        try { if ($e.count) { $count = [long]$e.count } } catch { $count = [long]0 }
        if ($script:CAPACITY_DDI_TYPES -ccontains $type) { $ddi += $count }
        elseif ($script:CAPACITY_ACTIVE_IP_TYPES -ccontains $type) { $active += $count }
    }
    return @{ Ddi = $ddi; Active = $active; Total = ($ddi + $active) }
}

function Get-CapacityReportData {
    param([string]$HostName)
    try {
        $d = Invoke-WapiGet 'capacityreport' @{
            'name'           = $HostName
            '_return_fields' = 'object_counts,total_objects,hardware_type,max_capacity,name,role,percent_used'
        }
        if ($d.Count -gt 0) { return $d[0] }
    } catch {
        Write-Log 'WARNING' ('[grid-capacity] capacityreport lookup failed for {0}: {1}' -f $HostName, $_.Exception.Message)
    }
    return $null
}

function New-CapacityReport {
    param($Members, [string]$OutDir, [string]$BaseName)
    $summaryRows = New-Object System.Collections.ArrayList
    $objectRows = New-Object System.Collections.ArrayList
    $typeCols = @()
    $seen = @{}

    foreach ($m in $Members) {
        $hostName = [string](Nz $m.host_name 'N/A')
        $nodes = ConvertTo-Array $m.node_info
        if ($nodes.Count -eq 0) { $nodes = @([pscustomobject]@{}) }
        $cap = Get-CapacityReportData $hostName
        $found = ($null -ne $cap)
        $role = ''; $hwType = ''; $maxCap = ''; $totalObj = ''; $pctUsed = ''
        $objectCounts = @()
        if ($found) {
            $role = Nz $cap.role ''
            $hwType = Nz $cap.hardware_type ''
            $maxCap = Nz $cap.max_capacity ''
            $totalObj = Nz $cap.total_objects ''
            $pctUsed = Nz $cap.percent_used ''
            $objectCounts = ConvertTo-Array $cap.object_counts
        }
        $est = Get-CapacityEstimates $objectCounts

        foreach ($node in $nodes) {
            if ($null -ne $node.PSObject.Properties['host_platform']) { $platform = $node.host_platform }
            else { $platform = Nz $node.hwtype '' }
            $ha = ConvertTo-TitleCase (([string]$node.ha_status).Replace('_', ' '))
            [void]$summaryRows.Add(@(
                $hostName, (Nz $node.hwid ''), $ha, $platform,
                $role, $hwType, $maxCap, $totalObj, $pctUsed,
                $est.Ddi, $est.Active, $est.Total, $found
            ))
        }

        $counts = @{}
        foreach ($e in $objectCounts) {
            if ($null -eq $e) { continue }
            $type = [string]$e.type_name
            if (-not $type) { continue }
            $counts[$type] = Nz $e.count ''
            if (-not $seen.ContainsKey($type)) {
                $seen[$type] = $true
                $typeCols += $type
            }
        }
        [void]$objectRows.Add(@{ Host = $hostName; Counts = $counts })
        $roleText = 'n/a'; if (Test-Truthy $role) { $roleText = [string]$role }
        $pctText = 'n/a'; if (Test-Truthy $pctUsed) { $pctText = [string]$pctUsed }
        Write-Log 'INFO' ('[grid-capacity] {0}: role={1} percent_used={2} report_found={3}' -f $hostName, $roleText, $pctText, $found)
    }

    $summaryPath = Join-Path $OutDir ($BaseName + '_grid_capacity_summary.csv')
    Write-CsvFile -Path $summaryPath -Header $script:CAPACITY_SUMMARY_HEADER -Rows $summaryRows

    $sortedTypes = Get-OrdinalSortedUnique $typeCols
    $objHeader = @('Member Host Name') + $sortedTypes
    $objRows = New-Object System.Collections.ArrayList
    foreach ($r in $objectRows) {
        $line = @($r.Host)
        foreach ($t in $sortedTypes) {
            if ($r.Counts.ContainsKey($t)) { $line += $r.Counts[$t] } else { $line += '' }
        }
        [void]$objRows.Add($line)
    }
    $objectsPath = Join-Path $OutDir ($BaseName + '_grid_capacity_objects.csv')
    Write-CsvFile -Path $objectsPath -Header $objHeader -Rows $objRows

    Write-Log 'INFO' ('[grid-capacity] wrote {0} node row(s) to {1} and {2}' -f $summaryRows.Count, $summaryPath, $objectsPath)
    return @($summaryPath, $objectsPath)
}

# =============================================================================
# SECTION 3 - OPTIONAL: DNS TOPOLOGY VISUALIZATION  (-TopologyViz)
# Adapted (via the Python tool) from ddi_collect.py / ddi_dashboard.html, part of
# the NIOS DDI Dashboard by Bobby Cooper (MIT License; see NOTICE.md in the
# original repository).
# Network footprint: six read-only GETs (zone_auth, zone_delegated, zone_forward,
# zone_stub, nsgroup, zone_rp). The generated HTML is static; the only external
# resource it references is the ECharts library from cdn.jsdelivr.net, loaded by
# the BROWSER that later opens the file - never by this script.
# NOTE: node ids are matched case-insensitively here (PowerShell hashtables), so
# two names that differ only by letter case merge into one node.
# =============================================================================
function Get-NsName {
    param($Entry)
    if ($null -eq $Entry) { return 'unknown' }
    if ($Entry.name) { return [string]$Entry.name }
    if ($Entry.address) { return [string]$Entry.address }
    return 'unknown'
}

function New-TopoState {
    return @{
        Nodes  = [ordered]@{}
        Links  = (New-Object System.Collections.ArrayList)
        Degree = @{}
    }
}

function Add-TopoNode {
    param($State, [string]$NodeId, [string]$Name, [string]$Category, [string]$Kind = '')
    if (-not $State.Nodes.Contains($NodeId)) {
        $k = $Kind
        if (-not $k) { $k = $Category }
        $State.Nodes[$NodeId] = [ordered]@{ id = $NodeId; name = $Name; category = $Category; kind = $k }
    }
    return $NodeId
}

function Add-TopoLink {
    param($State, [string]$Src, [string]$Dst, [string]$Rel)
    [void]$State.Links.Add([ordered]@{ source = $Src; target = $Dst; rel = $Rel })
    $State.Degree[$Src] = 1 + [int]$State.Degree[$Src]
    $State.Degree[$Dst] = 1 + [int]$State.Degree[$Dst]
}

# Links a zone_auth-shaped record (auth zone or RPZ) to its name servers.
function Add-ZoneNsLinks {
    param($State, [string]$ZoneId, $Zone, $NsgByName)
    $nsGroupName = [string]$Zone.ns_group
    if ($nsGroupName -and $NsgByName.Contains($nsGroupName)) {
        $gid = Add-TopoNode $State ('nsg:' + $nsGroupName) $nsGroupName 'Name Server Group'
        Add-TopoLink $State $gid $ZoneId 'primary'
    } else {
        foreach ($m in (ConvertTo-Array $Zone.grid_primary)) {
            $name = Get-NsName $m
            Add-TopoLink $State (Add-TopoNode $State ('ns:' + $name) $name 'Name Server') $ZoneId 'primary'
        }
        foreach ($m in (ConvertTo-Array $Zone.grid_secondaries)) {
            $name = Get-NsName $m
            Add-TopoLink $State (Add-TopoNode $State ('ns:' + $name) $name 'Name Server') $ZoneId 'secondary'
        }
    }
    foreach ($m in (ConvertTo-Array $Zone.external_primaries)) {
        $name = Get-NsName $m
        Add-TopoLink $State (Add-TopoNode $State ('ext:' + $name) $name 'External Primary') $ZoneId 'primary'
    }
    foreach ($m in (ConvertTo-Array $Zone.external_secondaries)) {
        $name = Get-NsName $m
        Add-TopoLink $State (Add-TopoNode $State ('extsec:' + $name) $name 'External Secondary') $ZoneId 'secondary'
    }
    $cinfo = $Zone.cloud_info
    if ($null -ne $cinfo -and (Test-Truthy $cinfo.delegated_member)) {
        $name = Get-NsName $cinfo.delegated_member
        Add-TopoLink $State (Add-TopoNode $State ('ns:' + $name) $name 'Name Server') $ZoneId 'primary'
    }
}

function Build-Topology {
    param($Auth, $Delegated, $Forward, $Stub, $NsGroups, $Rpz)
    $Auth = ConvertTo-Array $Auth
    $Delegated = ConvertTo-Array $Delegated
    $Forward = ConvertTo-Array $Forward
    $Stub = ConvertTo-Array $Stub
    $NsGroups = ConvertTo-Array $NsGroups
    $Rpz = ConvertTo-Array $Rpz

    $state = New-TopoState
    $sep = [string][char]31

    $nsgByName = [ordered]@{}
    foreach ($g in $NsGroups) { if ($g.name) { $nsgByName[[string]$g.name] = $g } }

    # (fqdn, view, kind) for every zone, in the same order as the Python tool.
    $allZones = New-Object System.Collections.ArrayList
    foreach ($z in $Auth) {
        $kind = 'Authoritative-Primary'
        if (Test-Truthy $z.external_primaries) { $kind = 'Authoritative-Secondary' }
        [void]$allZones.Add(@([string]$z.fqdn, [string](Nz $z.view 'default'), $kind))
    }
    foreach ($z in $Delegated) { [void]$allZones.Add(@([string]$z.fqdn, [string](Nz $z.view 'default'), 'Delegated')) }
    foreach ($z in $Forward) { [void]$allZones.Add(@([string]$z.fqdn, [string](Nz $z.view 'default'), 'Forward')) }
    foreach ($z in $Stub) { [void]$allZones.Add(@([string]$z.fqdn, [string](Nz $z.view 'default'), 'Stub')) }
    foreach ($z in $Rpz) {
        $rpzType = ([string]$z.rpz_type).Trim()
        $kind = 'RPZ'
        if ($rpzType) { $kind = 'RPZ (' + $rpzType + ')' }
        [void]$allZones.Add(@([string]$z.fqdn, [string](Nz $z.view 'default'), $kind))
    }

    # zone index: key (view+fqdn) -> @{ view; fqdn; id }
    $zoneIndex = [ordered]@{}
    foreach ($zt in $allZones) {
        $fqdn = $zt[0]; $view = $zt[1]; $kind = $zt[2]
        if (-not $fqdn) { continue }
        $nodeId = 'zone:{0}:{1}' -f $view, $fqdn
        [void](Add-TopoNode $state $nodeId $fqdn 'Zone' $kind)
        $zoneIndex[$view + $sep + $fqdn] = @{ view = $view; fqdn = $fqdn; id = $nodeId }
    }

    # Hierarchy: subzone -> parent zone (longest matching suffix) within a view.
    $byView = [ordered]@{}
    foreach ($e in $zoneIndex.Values) {
        if (-not $byView.Contains($e.view)) { $byView[$e.view] = New-Object System.Collections.ArrayList }
        [void]$byView[$e.view].Add($e.fqdn)
    }
    foreach ($view in $byView.Keys) {
        $fqdns = $byView[$view]
        $fqdnSet = @{}
        foreach ($f in $fqdns) { $fqdnSet[$f] = $true }
        foreach ($fqdn in $fqdns) {
            $parts = $fqdn.Split('.')
            for ($i = 1; $i -lt $parts.Count; $i++) {
                $parent = ($parts[$i..($parts.Count - 1)]) -join '.'
                if ($fqdnSet.ContainsKey($parent)) {
                    $childId = $zoneIndex[$view + $sep + $fqdn].id
                    $parentId = $zoneIndex[$view + $sep + $parent].id
                    Add-TopoLink $state $childId $parentId 'hierarchy'
                    break
                }
            }
        }
    }

    # Name Server Groups: one node per group plus its member servers, independent
    # of whether any zone references the group.
    foreach ($gname in $nsgByName.Keys) {
        $g = $nsgByName[$gname]
        $gid = Add-TopoNode $state ('nsg:' + $gname) $gname 'Name Server Group'
        foreach ($m in (ConvertTo-Array $g.grid_primary)) {
            $name = Get-NsName $m
            Add-TopoLink $state (Add-TopoNode $state ('ns:' + $name) $name 'Name Server') $gid 'nsg-primary'
        }
        foreach ($m in (ConvertTo-Array $g.grid_secondaries)) {
            $name = Get-NsName $m
            Add-TopoLink $state (Add-TopoNode $state ('ns:' + $name) $name 'Name Server') $gid 'nsg-secondary'
        }
        foreach ($m in (ConvertTo-Array $g.external_primaries)) {
            $name = Get-NsName $m
            Add-TopoLink $state (Add-TopoNode $state ('ext:' + $name) $name 'External Primary') $gid 'nsg-primary'
        }
        foreach ($m in (ConvertTo-Array $g.external_secondaries)) {
            $name = Get-NsName $m
            Add-TopoLink $state (Add-TopoNode $state ('extsec:' + $name) $name 'External Secondary') $gid 'nsg-secondary'
        }
    }

    foreach ($z in $Auth) {
        $key = [string](Nz $z.view 'default') + $sep + [string]$z.fqdn
        if (-not $zoneIndex.Contains($key)) { continue }
        Add-ZoneNsLinks $state $zoneIndex[$key].id $z $nsgByName
    }
    foreach ($z in $Rpz) {
        $key = [string](Nz $z.view 'default') + $sep + [string]$z.fqdn
        if (-not $zoneIndex.Contains($key)) { continue }
        Add-ZoneNsLinks $state $zoneIndex[$key].id $z $nsgByName
    }
    foreach ($z in $Forward) {
        $key = [string](Nz $z.view 'default') + $sep + [string]$z.fqdn
        if (-not $zoneIndex.Contains($key)) { continue }
        $zid = $zoneIndex[$key].id
        foreach ($m in (ConvertTo-Array $z.forward_to)) {
            $name = Get-NsName $m
            Add-TopoLink $state $zid (Add-TopoNode $state ('fwd:' + $name) $name 'Forward Target') 'forwards'
        }
        foreach ($m in (ConvertTo-Array $z.forwarding_servers)) {
            $name = Get-NsName $m
            Add-TopoLink $state $zid (Add-TopoNode $state ('ns:' + $name) $name 'Name Server') 'forwards'
        }
    }
    foreach ($z in $Delegated) {
        $key = [string](Nz $z.view 'default') + $sep + [string]$z.fqdn
        if (-not $zoneIndex.Contains($key)) { continue }
        $zid = $zoneIndex[$key].id
        foreach ($m in (ConvertTo-Array $z.delegate_to)) {
            $name = Get-NsName $m
            Add-TopoLink $state $zid (Add-TopoNode $state ('ns:' + $name) $name 'Name Server') 'delegated'
        }
    }
    foreach ($z in $Stub) {
        $key = [string](Nz $z.view 'default') + $sep + [string]$z.fqdn
        if (-not $zoneIndex.Contains($key)) { continue }
        $zid = $zoneIndex[$key].id
        foreach ($m in (ConvertTo-Array $z.stub_from)) {
            $name = Get-NsName $m
            Add-TopoLink $state $zid (Add-TopoNode $state ('ns:' + $name) $name 'Name Server') 'stub'
        }
    }

    foreach ($e in $zoneIndex.Values) { $state.Nodes[$e.id]['view'] = $e.view }
    foreach ($nodeId in @($state.Nodes.Keys)) {
        $state.Nodes[$nodeId]['value'] = [int]$state.Degree[$nodeId]
    }

    $nodeArr = New-Object System.Collections.ArrayList
    foreach ($n in $state.Nodes.Values) { [void]$nodeArr.Add($n) }
    return [ordered]@{ nodes = $nodeArr.ToArray(); links = $state.Links.ToArray() }
}

# Read-only GETs of the zone objects used to build the graph.
function Get-TopologyZoneData {
    $fields = 'fqdn,view,cloud_info,grid_primary,grid_secondaries,external_primaries,external_secondaries,ns_group'
    $auth = Invoke-WapiGet 'zone_auth' @{ '_return_fields' = $fields } -Paged
    $del = Invoke-WapiGet 'zone_delegated' @{ '_return_fields' = 'fqdn,view,delegate_to' } -Paged
    $fwd = Invoke-WapiGet 'zone_forward' @{ '_return_fields' = 'fqdn,view,forward_to,forwarding_servers' } -Paged
    $stub = Invoke-WapiGet 'zone_stub' @{ '_return_fields' = 'fqdn,view,stub_from' } -Paged
    $nsg = Invoke-WapiGet 'nsgroup' @{ '_return_fields' = 'name,grid_primary,grid_secondaries,external_primaries,external_secondaries' } -Paged
    $rpz = Invoke-WapiGet 'zone_rp' @{ '_return_fields' = ('fqdn,view,rpz_type,' + 'grid_primary,grid_secondaries,external_primaries,external_secondaries,ns_group') } -Paged
    return @{ auth = $auth; delegated = $del; forward = $fwd; stub = $stub; nsgroups = $nsg; rpz = $rpz }
}

# TOPOLOGY_HTML_TEMPLATE is the ENTIRE contents of the generated HTML file. It
# is plain HTML/CSS/JavaScript that only ever runs later, in a browser, when a
# user opens that file - it is NOT executed by this script. The one external
# reference is a <script src="https://cdn.jsdelivr.net/..."> tag for ECharts,
# fetched by the browser. The literal "__TOPOLOGY_JSON__" is replaced with the
# zone/name-server JSON collected from this Grid (no credentials).
# (Embedded verbatim from the Python tool.)

$script:TOPOLOGY_HTML_TEMPLATE = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>NIOS DNS Topology</title>
<script src="https://cdn.jsdelivr.net/npm/echarts@5.5.0/dist/echarts.min.js"></script>
<style>
:root {
  --bg: #ffffff; --bg-light: #f6f6f6; --bg-mid: #f0f0f0;
  --border: #e5e5e5; --text-pri: #1b1b1b; --text-sec: #727272;
  --primary: #1b1b1b; --primary-hover: #404040; --selected: #e8e8e8;
  --card-shadow: 0 1px 2px rgba(0,0,0,0.06), 0 4px 12px rgba(0,0,0,0.04);
  --n-zone: #6b7280; --n-ns: #2ec27e; --n-ext: #cda515; --n-extsec: #b45309; --n-fwd: #ef601b; --n-view: #9333ea; --n-nsg: #0891b2;
  --e-hierarchy: #8a8f98; --e-primary: #2ec27e; --e-secondary: #343ced;
  --e-forwards: #ef601b; --e-delegated: #dd2ca5; --e-stub: #0891b2;
  --e-nsg-primary: #0891b2; --e-nsg-secondary: #7c9eb2;
  --graph-canvas: #f6f6f6;
}
* { box-sizing: border-box; }
body { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; margin: 0;
  padding: 22px 24px 44px; background: var(--bg); color: var(--text-pri); -webkit-font-smoothing: antialiased; }
h1 { font-weight: 600; font-size: 1.55rem; margin: 0; letter-spacing: -0.01em; }
.shell { max-width: 1200px; margin: 0 auto; }
.subtitle { color: var(--text-sec); font-size: 0.9rem; margin: 4px 0 16px; }
.meta-badges { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 16px; }
.badge { font-size: 0.74rem; padding: 5px 10px; border-radius: 999px; background: var(--bg-light);
  color: var(--text-sec); border: 1px solid var(--border); white-space: nowrap; }
.badge strong { color: var(--text-pri); font-weight: 600; }

.topo-toolbar { display: flex; flex-wrap: wrap; gap: 10px 18px; align-items: center;
  padding: 12px 14px; margin-bottom: 12px; background: var(--bg-light);
  border: 1px solid var(--border); border-radius: 12px; }
.seg { display: inline-flex; border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }
.seg button { border: 0; background: transparent; color: var(--text-sec); padding: 7px 14px;
  font-size: 0.85rem; cursor: pointer; transition: background .15s, color .15s; }
.seg button.active { background: var(--primary); color: var(--bg); }
.seg button:not(.active):hover { background: var(--selected); color: var(--text-pri); }
.spacing { display: inline-flex; align-items: center; gap: 9px; }
.spacing label { font-size: 0.78rem; color: var(--text-sec); white-space: nowrap; }
.spacing input[type=range] { width: 128px; height: 4px; cursor: pointer; accent-color: var(--primary); }
.search { flex: 1; min-width: 150px; }
.search input { width: 100%; padding: 8px 11px; font-size: 0.85rem; border: 1px solid var(--border);
  border-radius: 8px; background: var(--bg); color: var(--text-pri); }
.filters { display: flex; flex-wrap: wrap; gap: 6px; }
.chip { display: inline-flex; align-items: center; gap: 6px; padding: 5px 11px; font-size: 0.78rem;
  border-radius: 999px; cursor: pointer; user-select: none; border: 1px solid var(--border);
  background: var(--bg); color: var(--text-sec); transition: opacity .15s; }
.chip .dash { width: 14px; height: 3px; border-radius: 2px; }
.chip .dot { width: 9px; height: 9px; border-radius: 50%; }
.chip.off { opacity: 0.4; } .chip.active { color: var(--text-pri); }
.legend { display: flex; flex-wrap: wrap; gap: 14px; margin: 0 0 12px; padding-left: 2px; }
.legend span { display: inline-flex; align-items: center; gap: 6px; font-size: 0.78rem; color: var(--text-sec); }
.legend .dot { width: 10px; height: 10px; border-radius: 50%; }
.canvas-wrap { background: var(--graph-canvas); border: 1px solid var(--border);
  border-radius: 12px; box-shadow: var(--card-shadow); overflow: hidden; }
#graph, #tree { width: 100%; height: 640px; } #tree { display: none; }
.footnote { font-size: 0.78rem; color: var(--text-sec); margin-top: 14px; }
.hint-inline { font-size: 0.78rem; color: var(--text-sec); }
.empty { padding: 60px 20px; text-align: center; color: var(--text-sec); }
</style>
</head>
<body>
<div class="shell">
  <h1>NIOS DNS Topology</h1>
  <p class="subtitle">Primary / secondary / forwarder / delegated / stub relationships, collected via WAPI alongside the health check run</p>
  <div class="meta-badges" id="metaBadges"></div>

  <div class="topo-toolbar">
    <div class="seg" id="viewToggle">
      <button data-view="graph" class="active">Relationship Graph</button>
      <button data-view="tree">Zone Hierarchy</button>
    </div>
    <div class="filters" id="viewFilters"></div>
    <div class="filters" id="edgeFilters"></div>
    <div class="spacing" id="spacingCtl">
      <label for="spacing">Node spacing</label>
      <input id="spacing" type="range" min="40" max="240" value="100" aria-label="Adjust spacing between nodes">
    </div>
    <div class="search"><input id="search" type="text" placeholder="Search zone or server&hellip;" autocomplete="off"></div>
  </div>
  <div class="legend" id="legend"></div>
  <div class="canvas-wrap"><div id="graph"></div><div id="tree"></div></div>
  <p class="footnote" id="footnote"></p>
</div>

<script>
var DDI_DATA = __TOPOLOGY_JSON__;

(function () {
  var textPri = '#1b1b1b', textSec = '#727272', border = '#e5e5e5';
  function chart(id, renderer) { var d = document.getElementById(id); return echarts.getInstanceByDom(d) || echarts.init(d, null, { renderer: renderer || 'svg' }); }
  var baseTip = { backgroundColor: '#f6f6f6', borderColor: border, textStyle: { color: textPri, fontSize: 12 } };

  var meta = DDI_DATA.meta || {}, counts = DDI_DATA.zone_counts || {};
  document.getElementById('metaBadges').innerHTML =
    '<span class="badge">Grid: <strong>' + (meta.grid_master || 'n/a') + '</strong></span>' +
    '<span class="badge">Authoritative: <strong>' + (counts.Authoritative || 0) + '</strong></span>' +
    '<span class="badge">Delegated: <strong>' + (counts.Delegated || 0) + '</strong></span>' +
    '<span class="badge">Forward: <strong>' + (counts.Forward || 0) + '</strong></span>' +
    '<span class="badge">Stub: <strong>' + (counts.Stub || 0) + '</strong></span>' +
    '<span class="badge">RPZ: <strong>' + (counts.RPZ || 0) + '</strong></span>' +
    '<span class="badge">Name Server Groups: <strong>' + (counts.NameServerGroups || 0) + '</strong></span>';
  document.getElementById('footnote').textContent =
    'Data source: Infoblox NIOS WAPI (zone_auth, zone_delegated, zone_forward, zone_stub, zone_rp, nsgroup). ' +
    'Collected once when the health check script was run with --topology-viz; reopen this file any time \u2014 no server required.';

  var T = DDI_DATA.topology || { nodes: [], links: [] };
  if (!T.nodes.length) {
    document.querySelector('.canvas-wrap').innerHTML = '<div class="empty">No zone relationships were found on this Grid.</div>';
    return;
  }

  var CAT = [{ name: 'Zone', color: '#6b7280' }, { name: 'Name Server', color: '#2ec27e' }, { name: 'External Primary', color: '#cda515' }, { name: 'External Secondary', color: '#b45309' }, { name: 'Forward Target', color: '#ef601b' }, { name: 'Name Server Group', color: '#0891b2' }];
  var catColor = {}, catIndex = {}; CAT.forEach(function (c, i) { catColor[c.name] = c.color; catIndex[c.name] = i; });
  var REL = [{ key: 'hierarchy', label: 'Subzone of', color: '#8a8f98' }, { key: 'primary', label: 'Primary for', color: '#2ec27e' },
    { key: 'secondary', label: 'Secondary for', color: '#343ced' }, { key: 'forwards', label: 'Forwards to', color: '#ef601b' },
    { key: 'delegated', label: 'Delegated to', color: '#dd2ca5' }, { key: 'stub', label: 'Stub from', color: '#0891b2' },
    { key: 'nsg-primary', label: 'NSG primary member', color: '#0891b2' }, { key: 'nsg-secondary', label: 'NSG secondary member', color: '#7c9eb2' }];
  var relColor = {}, relLabel = {}, active = {}; REL.forEach(function (r) { relColor[r.key] = r.color; relLabel[r.key] = r.label; active[r.key] = true; });
  var nodeById = {}, deg = {}, nodeSpacing = 1.0, viewActive = {};

  function nodeView(n) { return (n && n.view) || 'default'; }
  function syncViews() {
    var seen = {};
    T.nodes.forEach(function (n) { if (n.category === 'Zone') { var vw = nodeView(n); seen[vw] = true; if (!(vw in viewActive)) viewActive[vw] = true; } });
    return Object.keys(viewActive).filter(function (vw) { return seen[vw]; }).sort();
  }

  function prepTopo() {
    deg = {}; T.links.forEach(function (l) { deg[l.source] = (deg[l.source] || 0) + 1; deg[l.target] = (deg[l.target] || 0) + 1; });
    nodeById = {};
    var nodes = T.nodes.map(function (n) {
      var nn = { id: n.id, name: n.name, category: catIndex[n.category] || 0, symbolSize: 8 + Math.min(34, Math.sqrt(deg[n.id] || 0) * 7),
        itemStyle: { color: catColor[n.category] || '#6b7280' }, label: { show: true }, _kind: n.kind || n.category, _cat: n.category, _view: nodeView(n) };
      nodeById[n.id] = nn; return nn;
    });
    return { nodes: nodes };
  }
  function buildVisible(p) {
    var hiddenZone = {};
    T.nodes.forEach(function (n) { if (n.category === 'Zone' && viewActive[nodeView(n)] === false) hiddenZone[n.id] = true; });
    var links = T.links.filter(function (l) { return active[l.rel] && !hiddenZone[l.source] && !hiddenZone[l.target]; });
    var keep = {}; links.forEach(function (l) { keep[l.source] = 1; keep[l.target] = 1; });
    var nodes = p.nodes.filter(function (n) { if (hiddenZone[n.id]) return false; return n._cat === 'Zone' ? true : !!keep[n.id]; });
    var mapped = links.map(function (l) {
      return { source: l.source, target: l.target, _rel: l.rel,
        lineStyle: { color: relColor[l.rel], width: l.rel === 'hierarchy' ? 1.4 : 1, curveness: l.rel === 'hierarchy' ? 0 : 0.12, opacity: 0.7 } };
    });
    return { nodes: nodes, links: mapped };
  }
  function renderGraph() {
    var p = prepTopo(), vis = buildVisible(p);
    chart('graph', 'canvas').setOption({
      tooltip: Object.assign({ formatter: function (x) {
        if (x.dataType === 'edge') { var s = nodeById[x.data.source], t = nodeById[x.data.target]; return (s ? s.name : x.data.source) + ' <b>' + relLabel[x.data._rel] + '</b> ' + (t ? t.name : x.data.target); }
        return '<b>' + x.data.name + '</b><br>' + x.data._kind + '<br><span style="color:' + textSec + '">' + (deg[x.data.id] || 0) + ' connections</span>';
      } }, baseTip),
      legend: [{ data: CAT.map(function (c) { return c.name; }), textStyle: { color: textSec }, top: 6, icon: 'circle', inactiveColor: border }],
      series: [{ type: 'graph', layout: 'force', roam: true, draggable: true,
        categories: CAT.map(function (c) { return { name: c.name, itemStyle: { color: c.color } }; }),
        data: vis.nodes, links: vis.links,
        force: { repulsion: Math.round(160 * nodeSpacing), edgeLength: [Math.round(45 * nodeSpacing), Math.round(130 * nodeSpacing)], gravity: 0.08 / nodeSpacing, friction: 0.16 },
        emphasis: { focus: 'adjacency', label: { show: true }, lineStyle: { width: 2.4, opacity: 1 } },
        label: { position: 'right', color: textPri, fontSize: 11, formatter: function (x) { return x.data.name; } },
        labelLayout: { hideOverlap: true }, scaleLimit: { min: 0.4, max: 6 } }]
    }, true);
  }
  function renderTree() {
    var p = prepTopo();
    var parentOf = {}; T.links.forEach(function (l) { if (l.rel === 'hierarchy') parentOf[l.source] = l.target; });
    var children = {}; Object.keys(parentOf).forEach(function (c) { (children[parentOf[c]] = children[parentOf[c]] || []).push(c); });
    function node(id) { var n = nodeById[id] || { name: id, _kind: '' }; var o = { name: n.name, _kind: n._kind, itemStyle: { color: '#6b7280' }, label: { color: textPri } }; if (children[id]) o.children = children[id].map(node); return o; }
    var byView = {};
    p.nodes.forEach(function (n) {
      if (n._cat !== 'Zone' || parentOf[n.id]) return;
      var vw = n._view || 'default';
      if (viewActive[vw] === false) return;
      (byView[vw] = byView[vw] || []).push(node(n.id));
    });
    var viewBranches = Object.keys(byView).sort().map(function (vw) {
      return { name: 'view: ' + vw, _kind: 'DNS View', itemStyle: { color: '#9333ea' }, label: { color: textPri, fontWeight: 'bold' }, children: byView[vw] };
    });
    chart('tree', 'svg').setOption({
      tooltip: Object.assign({ trigger: 'item', triggerOn: 'mousemove', formatter: function (x) { return '<b>' + x.name + '</b>' + (x.data._kind ? '<br>' + x.data._kind : ''); } }, baseTip),
      series: [{ type: 'tree', data: [{ name: 'DNS Namespace', itemStyle: { color: '#2ec27e' }, label: { color: textPri, fontWeight: 'bold' }, children: viewBranches }],
        top: 24, bottom: 24, left: 90, right: 160, symbolSize: 8, roam: true, initialTreeDepth: 3,
        lineStyle: { color: '#8a8f98', width: 1.2 }, label: { position: 'left', verticalAlign: 'middle', align: 'right', fontSize: 11 },
        leaves: { label: { position: 'right', align: 'left' } }, emphasis: { focus: 'descendant' }, expandAndCollapse: true, animationDuration: 400 }]
    }, true);
  }
  var topoView = 'graph';
  function renderViewChips() {
    var views = syncViews();
    var el = document.getElementById('viewFilters');
    el.innerHTML = views.map(function (vw) {
      var on = viewActive[vw] !== false;
      return '<span class="chip view-chip ' + (on ? 'active' : 'off') + '" data-view-name="' + vw + '"><span class="dot" style="background:#9333ea"></span>view: ' + vw + '</span>';
    }).join('');
    el.querySelectorAll('.view-chip').forEach(function (chip) {
      chip.addEventListener('click', function () {
        var vw = chip.getAttribute('data-view-name');
        viewActive[vw] = !(viewActive[vw] !== false);
        chip.classList.toggle('off', viewActive[vw] === false);
        chip.classList.toggle('active', viewActive[vw] !== false);
        if (topoView === 'graph') renderGraph(); else renderTree();
      });
    });
  }
  function renderTopology() {
    renderViewChips();
    document.getElementById('legend').innerHTML = CAT.map(function (c) { return '<span><span class="dot" style="background:' + c.color + '"></span>' + c.name + '</span>'; }).join('') +
      '<span class="hint-inline">&bull; node size = number of connections &bull; drag to rearrange, scroll to zoom, slider to space nodes &bull; toggle views to show/hide their DNS</span>';
    if (topoView === 'graph') { renderGraph(); chart('graph', 'canvas').resize(); } else { renderTree(); chart('tree', 'svg').resize(); }
  }
  document.getElementById('edgeFilters').innerHTML = REL.map(function (r) { return '<span class="chip active" data-rel="' + r.key + '"><span class="dash" style="background:' + r.color + '"></span>' + r.label + '</span>'; }).join('');
  document.querySelectorAll('.chip[data-rel]').forEach(function (chip) {
    chip.addEventListener('click', function () { var k = chip.getAttribute('data-rel'); active[k] = !active[k]; chip.classList.toggle('off', !active[k]); chip.classList.toggle('active', active[k]); if (topoView === 'graph') renderGraph(); });
  });
  document.querySelectorAll('#viewToggle button').forEach(function (btn) {
    btn.addEventListener('click', function () {
      document.querySelectorAll('#viewToggle button').forEach(function (b) { b.classList.remove('active'); }); btn.classList.add('active');
      topoView = btn.getAttribute('data-view'); var isG = topoView === 'graph';
      document.getElementById('graph').style.display = isG ? 'block' : 'none';
      document.getElementById('tree').style.display = isG ? 'none' : 'block';
      document.getElementById('edgeFilters').style.visibility = isG ? 'visible' : 'hidden';
      document.getElementById('spacingCtl').style.visibility = isG ? 'visible' : 'hidden';
      renderTopology();
    });
  });
  var spacingTimer = null;
  document.getElementById('spacing').addEventListener('input', function (e) {
    nodeSpacing = (+e.target.value) / 100;
    clearTimeout(spacingTimer);
    spacingTimer = setTimeout(function () { if (topoView === 'graph') renderGraph(); }, 130);
  });
  document.getElementById('search').addEventListener('input', function (e) {
    var q = e.target.value.trim().toLowerCase(); var g = chart('graph', 'canvas');
    g.dispatchAction({ type: 'downplay', seriesIndex: 0 }); if (!q) return;
    var vis = buildVisible(prepTopo()); vis.nodes.forEach(function (n, i) { if (n.name.toLowerCase().indexOf(q) !== -1) g.dispatchAction({ type: 'highlight', seriesIndex: 0, dataIndex: i }); });
  });

  renderTopology();
  window.addEventListener('resize', function () { chart('graph', 'canvas').resize(); chart('tree', 'svg').resize(); });
})();
</script>
</body>
</html>

'@

function New-TopologyViz {
    param([string]$OutDir, [string]$BaseName)
    $zones = Get-TopologyZoneData
    $topology = Build-Topology $zones.auth $zones.delegated $zones.forward $zones.stub $zones.nsgroups $zones.rpz

    $payload = [ordered]@{
        meta        = [ordered]@{ grid_master = $script:GridHost }
        topology    = $topology
        zone_counts = [ordered]@{
            Authoritative    = $zones.auth.Count
            Delegated        = $zones.delegated.Count
            Forward          = $zones.forward.Count
            Stub             = $zones.stub.Count
            NameServerGroups = $zones.nsgroups.Count
            RPZ              = $zones.rpz.Count
        }
    }

    # '<' is escaped so a zone/name string can never close the <script> tag.
    $compact = (ConvertTo-Json -InputObject $payload -Depth 10 -Compress).Replace('<', '<')
    $html = $script:TOPOLOGY_HTML_TEMPLATE.Replace('__TOPOLOGY_JSON__', $compact)
    $htmlPath = Join-Path $OutDir ($BaseName + '_topology.html')
    Set-Content -Path $htmlPath -Value $html -Encoding UTF8

    # Plain JSON export of the same data for other tooling.
    $jsonPath = Join-Path $OutDir ($BaseName + '_topology.json')
    Write-JsonFile -Path $jsonPath -Object $payload

    Write-Log 'INFO' ('[topology-viz] wrote {0} node(s), {1} link(s) to {2} and {3}' -f $topology.nodes.Count, $topology.links.Count, $htmlPath, $jsonPath)
    return @($htmlPath, $jsonPath)
}

# =============================================================================
# SECTION 4 - OPTIONAL: GRID LICENSE REPORT  (-LicenseReport)
# Zero additional WAPI calls beyond the Grid-Wide license detail query: it reuses
# the member:license data already collected by the core report.
# =============================================================================
$script:LICENSE_REPORT_HEADER = @(
    'Scope', 'Member Name', 'Member IP', 'Hardware ID', 'Serial Number',
    'License Type', 'Kind', 'Limit', 'Expiration Status', 'Expiry Date'
)

# WAPI epoch seconds -> 'yyyy-MM-dd HH:mm:ss' (local time), 'Permanent' or 'N/A'.
function Format-ExpiryDate {
    param($Value)
    if ($null -eq $Value) { return 'N/A' }
    $epoch = [long]0
    try { $epoch = [long]$Value } catch { return 'N/A' }
    if ($epoch -le 0) { return 'Permanent' }
    try {
        $dt = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc).AddSeconds([double]$epoch).ToLocalTime()
        return $dt.ToString('yyyy-MM-dd HH:mm:ss')
    } catch {
        return 'N/A'
    }
}

# Copy of a raw license record without _ref, with expiry_date made readable.
function Format-LicenseEntry {
    param($Lic)
    $e = [ordered]@{}
    foreach ($p in $Lic.PSObject.Properties) {
        if ($p.Name -ne '_ref') { $e[$p.Name] = $p.Value }
    }
    $e['expiry_date'] = Format-ExpiryDate $Lic.expiry_date
    return $e
}

function New-LicenseReport {
    param($GridWideLicenses, $LicensesByHwid, $Members, [bool]$IncludeIpFlag,
          $MemberIpMap, $MemberVipMap, [string]$OutDir, [string]$BaseName)

    $hwidToHost = @{}
    foreach ($m in $Members) {
        $hostName = [string]$m.host_name
        foreach ($node in (ConvertTo-Array $m.node_info)) {
            if ($node.hwid) { $hwidToHost[[string]$node.hwid] = $hostName }
        }
    }

    $memberLicenses = @{}
    foreach ($hwid in $LicensesByHwid.Keys) {
        if (-not $hwidToHost.ContainsKey($hwid)) { continue }
        $h = $hwidToHost[$hwid]
        if (-not $memberLicenses.ContainsKey($h)) { $memberLicenses[$h] = New-Object System.Collections.ArrayList }
        foreach ($lic in $LicensesByHwid[$hwid]) { [void]$memberLicenses[$h].Add((Format-LicenseEntry $lic)) }
    }

    $membersOut = New-Object System.Collections.ArrayList
    foreach ($m in $Members) {
        $hostName = [string]$m.host_name
        $ip = ''
        if ($IncludeIpFlag) {
            if ($MemberIpMap.ContainsKey($hostName) -and $MemberIpMap[$hostName]) { $ip = $MemberIpMap[$hostName] }
            elseif ($MemberVipMap.ContainsKey($hostName) -and $MemberVipMap[$hostName]) { $ip = $MemberVipMap[$hostName] }
        }
        $lics = @()
        if ($memberLicenses.ContainsKey($hostName)) { $lics = $memberLicenses[$hostName].ToArray() }
        [void]$membersOut.Add([ordered]@{ member_name = $hostName; member_ip = $ip; licenses = $lics })
    }

    $gridWide = New-Object System.Collections.ArrayList
    foreach ($lic in $GridWideLicenses) { [void]$gridWide.Add((Format-LicenseEntry $lic)) }

    $payload = [ordered]@{ grid_wide = $gridWide.ToArray(); members = $membersOut.ToArray() }

    # One CSV row per license entry; members without licenses still get one row.
    $rows = New-Object System.Collections.ArrayList
    foreach ($lic in $gridWide) {
        [void]$rows.Add(@('Grid Wide', '', '', $lic['hwid'], $lic['hwid'], $lic['type'], $lic['kind'],
                          $lic['limit'], $lic['expiration_status'], $lic['expiry_date']))
    }
    foreach ($mo in $membersOut) {
        $licList = @($mo.licenses)
        if ($licList.Count -eq 0) { $licList = @([ordered]@{}) }
        foreach ($lic in $licList) {
            [void]$rows.Add(@('Member', $mo.member_name, $mo.member_ip, $lic['hwid'], $lic['hwid'], $lic['type'],
                              $lic['kind'], $lic['limit'], $lic['expiration_status'], $lic['expiry_date']))
        }
    }

    $csvPath = Join-Path $OutDir ($BaseName + '_license_report.csv')
    Write-CsvFile -Path $csvPath -Header $script:LICENSE_REPORT_HEADER -Rows $rows
    $jsonPath = Join-Path $OutDir ($BaseName + '_license_report.json')
    Write-JsonFile -Path $jsonPath -Object $payload

    $memberLicCount = 0
    foreach ($mo in $membersOut) { $memberLicCount += @($mo.licenses).Count }
    Write-Log 'INFO' ('[license-report] wrote {0} grid-wide and {1} member license entries across {2} member(s) to {3}, {4}' -f $gridWide.Count, $memberLicCount, $membersOut.Count, $csvPath, $jsonPath)
    return @($csvPath, $jsonPath)
}

# =============================================================================
# MAIN ORCHESTRATION
# =============================================================================
function Read-YesNo {
    param([string]$Prompt)
    $ans = ([string](Read-Host $Prompt)).Trim().ToLowerInvariant()
    return (@('y', 'yes', '1', 'true') -contains $ans)
}

# -X / -NoX switch pair: explicit switch wins, otherwise prompt (None -> prompt).
function Resolve-Toggle {
    param([string]$Name, [string]$NegName, [string]$Prompt)
    if ($script:BoundParams.ContainsKey($NegName) -and [bool]$script:BoundParams[$NegName]) { return $false }
    if ($script:BoundParams.ContainsKey($Name)) { return [bool]$script:BoundParams[$Name] }
    return (Read-YesNo $Prompt)
}

function Write-Banner {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 80)
    Write-Host $Title
    Write-Host ('=' * 80)
    Write-Host ''
}

function Invoke-NiosHealthCheck {
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $runName = '{0}_{1}' -f $script:APP_NAME, $ts
    $null = New-Item -ItemType Directory -Force -Path $runName
    $outDir = (Resolve-Path -Path $runName).Path
    $logName = $Log
    if (-not $logName) { $logName = $runName + '.log.jsonl' }
    if (Split-Path -Path $logName -IsAbsolute) { $script:LogPath = $logName } else { $script:LogPath = Join-Path $outDir $logName }
    $script:DebugEnabled = [bool]$DebugMode

    Write-Host ''
    Write-Host ('=' * 60)
    Write-Host 'INFOBLOX HEALTH CHECK DATA COLLECTION'
    Write-Host ('=' * 60)
    Write-Host 'Please provide the following information:'
    Write-Host ('-' * 60)
    Write-Log 'DEBUG' ('Nios-HealthCheck {0}; PowerShell {1}, language mode {2}' -f $script:VERSION, $PSVersionTable.PSVersion, $ExecutionContext.SessionState.LanguageMode)

    # ---- connection info (prompt for anything not supplied) ----
    $gridIp = $GridIp
    while (-not $gridIp) { $gridIp = ([string](Read-Host 'Grid Manager IP/Hostname')).Trim() }
    $wapiUser = $Username
    while (-not $wapiUser) { $wapiUser = ([string](Read-Host 'WAPI Username')).Trim() }
    $pw = $Password
    while ($null -eq $pw -or (($pw -is [string] -or $pw -is [System.Security.SecureString]) -and $pw.Length -eq 0)) {
        $pw = Read-Host 'WAPI Password' -AsSecureString
    }
    if ($pw -is [string]) { $secure = ConvertTo-SecureString -String $pw -AsPlainText -Force } else { $secure = $pw }
    $script:Credential = New-Object System.Management.Automation.PSCredential ($wapiUser, $secure)

    $insecure = [bool]$Insecure
    if (-not $insecure) { $insecure = Read-YesNo 'Bypass TLS Verification (y/n) [n]' }
    $includeIp = Resolve-Toggle 'IncludeIp' 'NoIncludeIp' 'Include Member IP Addresses in output (y/n) [n]'
    $capacityReport = Resolve-Toggle 'CapacityReport' 'NoCapacityReport' 'Include Grid Member Database Capacity report (y/n) [n]'
    $topologyViz = Resolve-Toggle 'TopologyViz' 'NoTopologyViz' 'Include DNS Topology Visualization (y/n) [n]'
    $licenseReport = Resolve-Toggle 'LicenseReport' 'NoLicenseReport' 'Include Grid License Report (y/n) [n]'

    $customer = $Customer
    if (-not $customer) { $customer = ([string](Read-Host 'Customer Name')).Trim() }
    if (-not $customer) { $customer = 'General' }
    if ($script:BoundParams.ContainsKey('Employees')) {
        $employees = [string]$Employees
    } else {
        $employees = ([string](Read-Host 'Employee Count [100]')).Trim()
        if (-not $employees) { $employees = '100' }
    }
    if ($Geo) { $geo = Resolve-GeoValue $Geo }
    else { $geo = Resolve-GeoValue (Read-Host 'Geo Country Name (EMEA, AMS, or APJ) [AMS]') }
    $seName = $User
    if (-not $seName) { $seName = ([string](Read-Host 'User/SE Name')).Trim() }
    if (-not $seName) { $seName = 'SE' }

    Write-Host ('-' * 60)
    Write-Host ''
    $yn = @{ $true = 'YES'; $false = 'NO' }
    Write-Host ('Include Member IP Addresses in output: {0}' -f $yn[$includeIp])
    Write-Host ('Include Grid Member Database Capacity report: {0}' -f $yn[$capacityReport])
    Write-Host ('Include DNS Topology Visualization: {0}' -f $yn[$topologyViz])
    Write-Host ('Include Grid License Report: {0}' -f $yn[$licenseReport])
    Write-Host ''

    # ---- connect ----
    $script:GridHost = $gridIp
    Initialize-Tls $insecure

    if ($ApiVersion) {
        $apiVer = $ApiVersion
        Write-Log 'INFO' ('Using provided API version: {0}' -f $apiVer)
    } else {
        Write-Log 'INFO' ('Connecting to {0} to auto-detect latest WAPI version.' -f $gridIp)
        $script:BaseUrl = 'https://{0}/wapi/v1.0/' -f $gridIp
        $apiVer = Get-LatestWapiVersion $gridIp
        Write-Log 'INFO' ('Auto-detected WAPI version: {0}' -f $apiVer)
    }
    Write-Host ('Connecting to Infoblox Grid at {0} (API {1}).' -f $gridIp, $apiVer)
    $script:BaseUrl = 'https://{0}/wapi/{1}/' -f $gridIp, $apiVer

    if (-not (Test-NiosConnectivity)) { return }

    try {
        Write-Banner 'DATA COLLECTION PHASE'

        $gridName = Get-NiosGridName
        Write-Host ('Grid Name: {0}' -f $gridName)

        $ver = Get-NiosSoftwareVersion
        Write-Host ('Grid Version: {0}' -f $ver)

        $gridUuid = Get-NiosGridUuid $apiVer
        if (Test-WapiSupportsGridUuid $apiVer) { Write-Host ('Grid UUID: {0}' -f $gridUuid) }
        else { Write-Host ('Grid UUID (license_UID fallback for WAPI {0}): {1}' -f $apiVer, $gridUuid) }

        $gridLics = Get-NiosGlobalLicenseTypes
        $members = Get-NiosMembers
        Write-Host ('Found {0} member(s)' -f $members.Count)

        $licensesByHwid = Get-NiosLicensesByHwid
        Write-Host ('Found licenses for {0} unique serial number(s)' -f $licensesByHwid.Count)

        # Member IPs only when opted in. member:dns covers DNS-serving members; the
        # member.vip_setting source covers every member (Reporting, Network Insight...).
        $memberIpMap = @{}
        $memberVipMap = @{}
        if ($includeIp) {
            $memberIpMap = Get-NiosMemberIpv4Map
            Write-Host ('Retrieved IPv4 addresses for {0} member(s) via member:dns' -f $memberIpMap.Count)
            $memberVipMap = Get-NiosMemberVipMap
            Write-Host ('Retrieved IPv4 addresses for {0} member(s) via member.vip_setting (universal fallback)' -f $memberVipMap.Count)
        }

        $dnsSettings = Get-NiosGlobalDnsSettings
        $dhcpGlobal = Get-NiosGlobalDhcpSettings
        $dhcpMap = Get-NiosDhcpServiceMap
        $gridCounts = Get-NiosGridObjectCounts
        $dnsMap = Get-NiosDnsServiceMap

        Write-Host ('Found {0} DNS view(s)' -f $gridCounts.Views)
        Write-Host ('Nameserver Groups configured: {0}' -f $gridCounts.HasNsg)
        Write-Host ('Found {0} smart folder(s)' -f $gridCounts.Folders)
        Write-Host ('Found {0} admin user(s)' -f $gridCounts.Admins)

        $scavEnabled = $false
        if ($null -ne $dnsSettings.Scavenging -and $null -ne $dnsSettings.Scavenging.enable_scavenging) { $scavEnabled = $dnsSettings.Scavenging.enable_scavenging }
        $logResponses = $false
        if ($null -ne $dnsSettings.Logging -and $null -ne $dnsSettings.Logging.log_responses) { $logResponses = $dnsSettings.Logging.log_responses }

        Write-Banner 'PROCESSING MEMBER DATA'

        $results = New-Object System.Collections.ArrayList
        for ($idx = 0; $idx -lt $members.Count; $idx++) {
            $member = $members[$idx]
            $hName = [string](Nz $member.host_name 'N/A')
            Write-Host ('[{0}/{1}] Processing member: {2}' -f ($idx + 1), $members.Count, $hName)

            $ri = Get-NiosMemberRoleAndIp $hName
            $roleLabel = $ri.Role

            # Column F: 3-tier fallback member:dns -> member.vip_setting -> capacityreport._ref
            $memberIpValue = ''
            if ($includeIp) {
                if ($memberIpMap.ContainsKey($hName) -and $memberIpMap[$hName]) { $memberIpValue = $memberIpMap[$hName] }
                elseif ($memberVipMap.ContainsKey($hName) -and $memberVipMap[$hName]) { $memberIpValue = $memberVipMap[$hName] }
                elseif ($ri.Ip) { $memberIpValue = $ri.Ip }
                if (-not $memberIpValue) {
                    Write-Log 'WARNING' ("No IP address found for member '{0}' via member:dns, member.vip_setting, or capacityreport._ref." -f $hName)
                }
            }
            $ipText = '(not included)'; if ($memberIpValue) { $ipText = $memberIpValue }
            Write-Host ('  - Role: {0} | IP: {1}' -f $roleLabel, $ipText)

            $objCount = Get-NiosMemberObjectCount $hName
            Write-Host ('  - Object count: {0}' -f $objCount)

            $baseProtocols = @()
            if ($dnsMap.ContainsKey($hName) -and (Test-Truthy $dnsMap[$hName].Enabled)) { $baseProtocols += 'dns' }
            $dhcpRef = $null
            if ($dhcpMap.ContainsKey($hName)) {
                $dhcpRef = $dhcpMap[$hName].Ref
                if (Test-Truthy $dhcpMap[$hName].Enabled) { $baseProtocols += 'dhcp' }
            }
            $dhcpHosts = Get-NiosActiveDhcpLeases ([string]$dhcpRef)

            $nodes = ConvertTo-Array $member.node_info
            if ($nodes.Count -eq 0) { $nodes = @([pscustomobject]@{}) }
            $isHa = ($nodes.Count -eq 2)
            if ($isHa) { Write-Host '  - HA Pair detected: processing Active and Passive nodes.' }

            for ($ni = 0; $ni -lt $nodes.Count; $ni++) {
                $node = $nodes[$ni]
                $nodeHwid = [string]$node.hwid
                if ($isHa) {
                    $haShow = [string](Nz $node.ha_status 'N/A')
                    $hwShow = 'N/A'; if ($nodeHwid) { $hwShow = $nodeHwid }
                    Write-Host ('    - Node {0}: ha_status={1}, hwid={2}' -f ($ni + 1), $haShow.ToUpperInvariant(), $hwShow)
                }

                $nodeLics = @()
                if ($nodeHwid -and $licensesByHwid.Contains($nodeHwid)) { $nodeLics = @($licensesByHwid[$nodeHwid]) }
                $licTypesLower = @()
                foreach ($l in $nodeLics) { $licTypesLower += ([string]$l.type).ToLowerInvariant() }
                $features = @() + $licTypesLower
                $hasRpz = $false; $hasThreat = $false
                foreach ($x in $licTypesLower) {
                    if ($x.Contains('response policy') -or $x.Contains('rpz')) { $hasRpz = $true }
                    if ($x.Contains('threat') -or $x.Contains('analytics')) { $hasThreat = $true }
                }
                if ($hasRpz) { $features += 'rpz' }
                if ($hasThreat) { $features += 'threat insight' }
                $licTypes = @()
                foreach ($l in $nodeLics) { if ($l.type) { $licTypes += [string]$l.type } }
                $licenseStr = (Get-OrdinalSortedUnique $licTypes) -join ', '

                $cpu = '0%'; $disk = '0%'; $mem = '0%'; $doh = $false
                $nodeProtocols = @() + $baseProtocols
                foreach ($svc in (ConvertTo-Array $node.service_status)) {
                    $sName = [string]$svc.service
                    $desc = [string]$svc.description
                    $status = [string]$svc.status
                    try {
                        if ($sName -ceq 'CPU_USAGE') { $cpu = ($desc -split ':')[-1].Trim() }
                        elseif ($sName -ceq 'DISK_USAGE') { $disk = ($desc -split '%')[0].Trim() + '%' }
                        elseif ($sName -ceq 'MEMORY') { $mem = ($desc -split '%')[0].Trim() + '%' }
                        elseif ($sName -ceq 'DOT_DOH') { $doh = ($status -ceq 'WORKING') }
                        if (($status -ceq 'WORKING' -or $status -ceq 'Running') -and (@('NTP', 'TFTP', 'HTTP', 'FTP', 'SNMP') -ccontains $sName)) {
                            $nodeProtocols += $sName.ToLowerInvariant()
                        }
                    } catch { }
                }

                $platform = 'N/A'
                foreach ($c in @($node.host_platform, $node.hwplatform, $node.hypervisor)) {
                    if (Test-Truthy $c) { $platform = [string]$c; break }
                }
                $haStatus = ConvertTo-TitleCase (([string](Nz $node.ha_status 'Not Configured')).Replace('_', ' '))
                $serial = 'N/A'; if ($nodeHwid) { $serial = $nodeHwid }

                $lle = $dhcpGlobal.LogLeaseEvents

                $row = [ordered]@{
                    'Customer Name'              = $customer
                    'Employee Count'             = $employees
                    'grid_uuid'                  = $gridUuid
                    'Member Serial Number'       = $serial
                    'Member Role'                = $roleLabel
                    'Member IP'                  = $memberIpValue
                    'Member Host Name'           = $hName
                    'Member Model'               = (Nz $node.hwtype 'N/A')
                    'Member Platform'            = $platform
                    'Member ha Status'           = $haStatus
                    'Member Operational State'   = 'Running'
                    'Member Version'             = $ver
                    'Member Version History'     = ''
                    'Member Protocol'            = ((Get-OrdinalSortedUnique $nodeProtocols) -join ', ')
                    'Member Object Count'        = $objCount
                    'Member Enabled Features'    = ((Get-OrdinalSortedUnique $features) -join ', ')
                    'Member License '            = $licenseStr
                    'Log Lease Events'           = $lle
                    'Grid Name'                  = $gridName
                    'Geo Country Name'           = $geo
                    'Collected At'               = (Get-NowText)
                    'grid wide license con'      = $gridLics
                    'Grid Enabled Feature'       = ''
                    'DNS DNS Scavenging'         = $scavEnabled
                    'DNS Query Response Logging' = $logResponses
                    'DNS Nameserver Groups'      = $gridCounts.HasNsg
                    'DNS Anycast'                = $false
                    'DNS DNS Scavenging_2'       = $scavEnabled
                    'DNS DNS Over HTTPs'         = $doh
                    'DNS DTC'                    = $false
                    'DHCP Finger Printing'       = $dhcpGlobal.EnableFingerprint
                    'NIOS File Distribution'     = $false
                    'User Name'                  = $seName
                    'DHCP IPv4 Hosts'            = $dhcpHosts
                    'DNS DNS Views'              = $gridCounts.Views
                    'DTC Members Pct'            = 'Not used'
                    'Grid Admin Count'           = $gridCounts.Admins
                    'NIOS Smart Folders'         = $gridCounts.Folders
                    'Member LPS Total'           = ''
                    'CPU Usage Ratio'            = (ConvertTo-PctRatio $cpu)
                    'Disk Usage Ratio'           = (ConvertTo-PctRatio $disk)
                    'Memeory Usage Ratio'        = (ConvertTo-PctRatio $mem)
                    'Member QPS'                 = ''
                }
                [void]$results.Add($row)
            }
        }

        if ($results.Count -eq 0) {
            Write-Log 'ERROR' 'No data collected; skipping output.'
            return
        }

        Write-Banner 'GENERATING OUTPUT FILES'

        $baseName = $runName
        $hashes = [ordered]@{}

        # Core report: same 43 columns as the Python tool. Column 28 reads the
        # "_2" key because the header has two "DNS DNS Scavenging" columns.
        $csvRows = New-Object System.Collections.ArrayList
        foreach ($r in $results) {
            $vals = @()
            for ($i = 0; $i -lt $script:HEADER_43.Count; $i++) {
                $key = $script:HEADER_43[$i]
                if (($i + 1) -eq 28) { $key = 'DNS DNS Scavenging_2' }
                $vals += , $r[$key]
            }
            [void]$csvRows.Add($vals)
        }
        $cp = Join-Path $outDir ($baseName + '.csv')
        Write-CsvFile -Path $cp -Header $script:HEADER_43 -Rows $csvRows
        $hashes[$baseName + '.csv'] = Get-Sha256 $cp
        Write-Host ('Created: {0}' -f $cp)

        # ---- optional add-ons: separate files, a failure never affects the core report ----
        if ($capacityReport) {
            Write-Banner 'OPTIONAL: GRID MEMBER CAPACITY REPORT (Section 2)'
            try {
                foreach ($p in (New-CapacityReport $members $outDir $baseName)) { Write-Host ('Created: {0}' -f $p) }
            } catch { Write-Log 'ERROR' ('Grid capacity report failed: {0}' -f $_.Exception.Message) }
        }
        if ($topologyViz) {
            Write-Banner 'OPTIONAL: DNS TOPOLOGY VISUALIZATION (Section 3)'
            try {
                foreach ($p in (New-TopologyViz $outDir $baseName)) { Write-Host ('Created: {0}' -f $p) }
            } catch { Write-Log 'ERROR' ('Topology visualization failed: {0}' -f $_.Exception.Message) }
        }
        if ($licenseReport) {
            Write-Banner 'OPTIONAL: GRID LICENSE REPORT (Section 4)'
            try {
                $gwDetailed = Get-NiosGlobalLicensesDetailed
                foreach ($p in (New-LicenseReport $gwDetailed $licensesByHwid $members $includeIp $memberIpMap $memberVipMap $outDir $baseName)) {
                    Write-Host ('Created: {0}' -f $p)
                }
            } catch { Write-Log 'ERROR' ('Grid license report failed: {0}' -f $_.Exception.Message) }
        }

        $summary = [ordered]@{
            grid_ip         = $gridIp
            api_version     = $apiVer
            grid_name       = $gridName
            grid_uuid       = $gridUuid
            include_ip      = $includeIp
            capacity_report = $capacityReport
            topology_viz    = $topologyViz
            license_report  = $licenseReport
            member_count    = $members.Count
            row_count       = $results.Count
            views           = $gridCounts.Views
            admins          = $gridCounts.Admins
            folders         = $gridCounts.Folders
            has_nsg         = $gridCounts.HasNsg
            collected_at    = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.ffffff')
            customer        = $customer
            geo             = $geo
            user            = $seName
            format          = 'csv'
            log_file        = $script:LogPath
            hashes          = $hashes
        }
        Write-JsonFile -Path (Join-Path $outDir ($baseName + '.summary.json')) -Object $summary

        Write-Host ''
        Write-Host ('Total logical members : {0}' -f $members.Count)
        Write-Host ('Total physical rows   : {0}' -f $results.Count)
        Write-Host ('Output directory      : {0}' -f $outDir)
    }
    finally {
        Write-Host ''
        Write-Host 'Logging out of WAPI session.'
        Invoke-NiosLogout
    }
}

Invoke-NiosHealthCheck
