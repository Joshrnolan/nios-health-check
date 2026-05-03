
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

# enhance_shape_data.py

A Python script that enriches a Lucid diagram shape data export (TSV) from the Infoblox NIOS Health Check application with device
inventory details from a NIOS health audit export (CSV) using the nios_health_check.py script in this repository, then writes the
updated data to a new Excel file.

---

## Overview

For each device record in the nios_health_check.py NIOS CSV (**sheet2**), the script finds the
matching row in the Lucid TSV file (**sheet1**) and appends the device's hostname,
serial number, and optional feature labels to the `Description` field.
Once a Lucid TSV row has been matched it is locked and cannot be matched again,
ensuring a 1-to-1 relationship between device records and diagram rows.

---

## Requirements

```bash
pip install pandas openpyxl
```

Python **3.6 or later** is supported.

---

## Usage

```bash
python enhance_shape_data.py <sheet1.tsv> <sheet2.csv> [output.xlsx]
```

| Argument | Required | Description |
|---|---|---|
| `sheet1.tsv` | ✅ | Tab-delimited Lucid diagram export |
| `sheet2.csv` | ✅ | Comma-delimited NIOS health audit export from nios_health_check_final.py |
| `output.xlsx` | ❌ | Output filename — defaults to `<sheet1_stem>_updated.xlsx` |

### Example

```bash
python enhance_shape_data.py lucidshapedata.tsv nios_health_audit_20260429.csv
# → writes lucidshapedata_updated.xlsx
```

---

## Matching Logic

sheet2 rows are processed in two passes to ensure correct priority:

1. **Pass 1** — All rows where `Member Enabled Features` contains `sw_tp` (DNS Infrastructure Protection)
2. **Pass 2** — All remaining rows (original order)

For each sheet2 output row, a target model and optional SKU filter are derived from
`Member Model`, then used to find the first available (unmatched) sheet1 row
satisfying **all** of the following conditions:

### Condition 1 — Model match

sheet2 `Member Model` is transformed to derive a `target_model` for
comparison against sheet1 `Model Info`:

| sheet2 `Member Model` starts with | Transformation | Example |
|---|---|---|
| `IB-V` | Replace `IB-V` → `TE-` | `IB-V2225` → `TE-2225` |
| `IB-` | Replace `IB-` → `TE-` | `IB-1415` → `TE-1415` |
| Anything else | Used as-is | `ND-2205` → `ND-2205` |

### Condition 2 — HW License SKU (IB-V models only)

When sheet2 `Member Model` starts with `IB-V`, the matched sheet1 row
**must** have `HW License SKU` equal to `VM`.

### Condition 3 — SW Add-ons 'DNS-IP' check (sw_tp / tp_sub devices only)

When sheet2 `Member Enabled Features` contains the token `sw_tp` **or**
`tp_sub`, the matched Sheet1 row **must** have `SW Add-ons` containing
`DNS-IP`.

---

## Description Field Output

The script **appends** to the existing `Description` value in Sheet1 rather
than replacing it. The following lines are added, each on its own line:

```
<existing Description value>
DNS Infrastructure Protection    ← only if Member Enabled Features contains sw_tp
DNS Firewall                     ← only if Member Enabled Features contains rpz
<Member Host Name>
<Member Serial Number>
```

Lines are only written when the corresponding feature token is present or
the field is non-empty.

---

## Unit #/Range Numbering

After all matching is complete, `Unit #/Range` in Sheet1 is reassigned so
that each value is **unique within its `Unit Group`**. Rows are processed
top-to-bottom; each group's counter starts at `1` and increments by `1` for
every row in that group. Rows with a blank `Unit Group` are left untouched.

---

## Required Columns

### Sheet1 (TSV)

| Column | Purpose |
|---|---|
| `Model Info` | Matched against derived target model from sheet2 |
| `HW License SKU` | Must equal `VM` for IB-V device matches |
| `SW Add-ons` | Must contain `DNS-IP` for sw_tp / tp_sub device matches |
| `Description` | Appended with hostname, serial, and feature labels |
| `Unit Group` | Used for Unit #/Range renumbering |
| `Unit #/Range` | Reassigned to be unique per Unit Group |

### sheet2 (CSV)

| Column | Purpose |
|---|---|
| `Member Model` | Source for model matching and case detection |
| `Member Host Name` | Written to Sheet1 `Description` |
| `Member Serial Number` | Written to Sheet1 `Description` |
| `Member Enabled Features` | Controls DNS-IP validation, DIP/Firewall labels, and processing order |

---

## Console Output

The script prints a detailed log for every row processed:

```
Reading Sheet1 from : lucidshapedata.tsv
Reading Sheet2 from : nios_health_audit_20260429.csv

  [MATCHED Case A [IB-V→TE-] SKU=VM] Sheet2 row 2 'IB-V2225' → Sheet1 row 1 Model='TE-2225' SKU='VM' → Description='Grid Manager DNS\nrtpgm.ddi.epa.gov\n42322EE0BBE1625FFAFC7EEBD902AE2E'
  [MATCHED Case B [IB-→TE-]] Sheet2 row 9 'IB-1415' → Sheet1 row 4 Model='TE-1415' SKU='1' → Description='DNS & DHCP\nrtpdhcp.ddi.epa.gov\n1405202103700146'
  [NO MATCH] Sheet2 row 22 'Member Model'='ND-2205' → target='ND-2205' — no available Sheet1 row.

Reassigning 'Unit #/Range' per 'Unit Group':
  Unit Group='GM' → row 1 Unit #/Range=1
  Unit Group='B'  → row 3 Unit #/Range=1
  ...

────────────────────────────────────────────────────────────
Done.  Matched : 30
       Unmatched Sheet2 rows : 4
       Row numbers            : [22, 23, 24, 25]
Output : lucidshapedata_updated.xlsx
```
