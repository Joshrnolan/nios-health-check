"""
update_sheet1_description.py
────────────────────────────
For each row in Sheet2, finds the first available (unused) matching row in
Sheet1 and writes Sheet2's 'Member Serial Number' + 'Member Host Name'
into Sheet1's 'Description' column.

Matching rules
──────────────
For every Sheet2 row, derive a target_model and an optional hw_sku_filter,
then find the first Sheet1 row where:
    • Sheet1 'Model Info'     == target_model   (case-insensitive)
    • Sheet1 'HW License SKU' == hw_sku_filter  (only when filter is set)
    • That Sheet1 row has not already been matched

How target_model and hw_sku_filter are derived from Sheet2 'Member Model':

  CASE A — 'Member Model' STARTS WITH "IB-V"
    • Replace the leading "IB-V" with "TE-"
        e.g.  "IB-V825"  →  target_model = "TE-825"
    • hw_sku_filter = "VM"  (Sheet1 'HW License SKU' MUST equal "VM")

  CASE B — 'Member Model' does NOT start with "IB-V"
    • Replace the leading "IB-" with "TE-"
        e.g.  "IB-825"   →  target_model = "TE-825"
    • hw_sku_filter = None  (no constraint on 'HW License SKU')

Usage
─────
    python update_sheet1_description.py <sheet1.tsv> <sheet2.csv> [output.xlsx]

    sheet1.tsv   – tab-delimited file treated as Sheet1
    sheet2.csv   – comma-delimited CSV file treated as Sheet2
    If output filename is omitted the script writes
    <sheet1_stem>_updated.xlsx next to the Sheet1 file.

Requirements
────────────
    pip install openpyxl pandas
"""

import sys
import pathlib
from typing import Optional, Tuple

import pandas as pd


# ── helpers ───────────────────────────────────────────────────────────────────

def derive_match_params(member_model: str) -> Tuple[str, Optional[str]]:
    """
    Return (target_model, hw_sku_filter) derived from Sheet2 'Member Model'.

    target_model    – value to compare against Sheet1 'Model Info'
    hw_sku_filter   – required value for Sheet1 'HW License SKU', or None
    """
    m = member_model.strip()

    if m.upper().startswith("IB-V"):
        # Case A: strip "IB-V", prepend "TE-"
        target_model   = "TE-" + m[4:]        # len("IB-V") == 4
        hw_sku_filter  = "VM"
    else:
        # Case B: replace leading "IB-" with "TE-"
        if m.upper().startswith("IB-"):
            target_model = "TE-" + m[3:]      # len("IB-") == 3
        else:
            target_model = m                  # no recognised prefix – use as-is
        hw_sku_filter = None

    return target_model, hw_sku_filter


def build_description(existing: str, serial: str, hostname: str, enabled_features: str) -> str:
    """Append optional DIP label, hostname, then serial as individual new lines."""
    new_parts = []
    if "sw_tp" in str(enabled_features).lower():
        new_parts.append("DNS Infrastructure Protection")
    if "rpz" in str(enabled_features).lower():
        new_parts.append("DNS Firewall")
    if hostname and str(hostname).strip() not in ("", "nan"):
        new_parts.append(str(hostname).strip())
    if serial and str(serial).strip() not in ("", "nan"):
        new_parts.append(str(serial).strip())
    new_lines = "\n".join(new_parts)
    existing = existing.strip()
    if existing:
        return existing + "\n" + new_lines
    return new_lines


# ── core processing ───────────────────────────────────────────────────────────

def process(sheet1_path: str, sheet2_path: str, output_path: str) -> None:
    print(f"Reading Sheet1 from : {sheet1_path}")
    print(f"Reading Sheet2 from : {sheet2_path}")

    # ── load input files ──────────────────────────────────────────────────────
    sheet1: pd.DataFrame = pd.read_csv(
        sheet1_path, sep="\t", dtype=str, encoding="utf-8"
    ).fillna("")
    sheet1.columns = sheet1.columns.str.strip()   # guard against header whitespace

    sheet2: pd.DataFrame = pd.read_csv(
        sheet2_path, sep=",", dtype=str, encoding="utf-8"
    ).fillna("")
    sheet2.columns = sheet2.columns.str.strip()   # guard against header whitespace

    # ── validate columns ──────────────────────────────────────────────────────
    required_s1 = {"Model Info", "HW License SKU", "Description", "Unit Group", "Unit #/Range", "SW Add-ons"}
    required_s2 = {"Member Serial Number", "Member Host Name", "Member Model", "Member Enabled Features"}

    missing_s1 = required_s1 - set(sheet1.columns)
    missing_s2 = required_s2 - set(sheet2.columns)
    if missing_s1:
        raise ValueError(f"Sheet1 is missing columns: {missing_s1}")
    if missing_s2:
        raise ValueError(f"Sheet2 is missing columns: {missing_s2}")

    # ── track which Sheet1 rows have already been matched ─────────────────────
    sheet1["_matched"] = False

    matched_count  = 0
    unmatched_rows = []

    # ── reorder Sheet2: sw_tp rows first, then the rest ──────────────────────
    def has_sw_tp(row):
        tokens = {t.strip() for t in str(row["Member Enabled Features"]).lower().split(",")}
        return "sw_tp" in tokens

    sw_tp_mask      = sheet2.apply(has_sw_tp, axis=1)
    sheet2_ordered  = pd.concat([sheet2[sw_tp_mask], sheet2[~sw_tp_mask]],
                                 ignore_index=False)

    # ── iterate Sheet2 — each row drives one match attempt ───────────────────
    for s2_idx, s2_row in sheet2_ordered.iterrows():
        member_model = s2_row["Member Model"].strip()

        if not member_model:
            print(f"  [SKIP] Sheet2 row {s2_idx + 2}: empty 'Member Model'.")
            continue

        target_model, hw_sku_filter = derive_match_params(member_model)

        # Build boolean mask for Sheet1 candidates
        # 1. Not yet matched
        mask = ~sheet1["_matched"]
        # 2. Model Info matches (case-insensitive)
        mask &= sheet1["Model Info"].str.strip().str.upper() == target_model.upper()
        # 3. HW License SKU constraint (Case A only)
        if hw_sku_filter is not None:
            mask &= sheet1["HW License SKU"].str.strip().str.upper() == hw_sku_filter.upper()
        # 4. SW Add-ons must contain "DNS-IP" when Member Enabled Features
        #    contains 'sw_tp' or 'tp_sub' (matched as whole tokens)
        features_lower = s2_row["Member Enabled Features"].lower()
        features_tokens = {t.strip() for t in features_lower.split(",")}
        if "sw_tp" in features_tokens or "tp_sub" in features_tokens:
            mask &= sheet1["SW Add-ons"].str.contains("DNS-IP", case=False,
                                                       na=False, regex=False)

        candidates = sheet1[mask]

        if candidates.empty:
            sku_hint = f" + HW License SKU='{hw_sku_filter}'" if hw_sku_filter else ""
            print(
                f"  [NO MATCH] Sheet2 row {s2_idx + 2} "
                f"'Member Model'='{member_model}' "
                f"→ target='{target_model}'{sku_hint} "
                f"— no available Sheet1 row."
            )
            unmatched_rows.append(s2_idx + 2)
            continue

        # Take the first available Sheet1 candidate
        s1_idx  = candidates.index[0]
        s1_row  = sheet1.loc[s1_idx]

        serial            = s2_row["Member Serial Number"]
        hostname          = s2_row["Member Host Name"]
        enabled_features  = s2_row["Member Enabled Features"]
        existing          = s1_row["Description"]
        new_desc          = build_description(existing, serial, hostname, enabled_features)

        sheet1.at[s1_idx, "Description"] = new_desc
        sheet1.at[s1_idx, "_matched"]    = True

        case_label = "A [IB-V→TE-] SKU=VM" if hw_sku_filter else "B [IB-→TE-]"
        print(
            f"  [MATCHED Case {case_label}] "
            f"Sheet2 row {s2_idx + 2} '{member_model}' "
            f"→ Sheet1 row {s1_idx + 2} "
            f"Model='{s1_row['Model Info']}' SKU='{s1_row['HW License SKU']}' "
            f"→ Description='{new_desc}'"
        )
        matched_count += 1

    # ── clean up internal tracking column ────────────────────────────────────
    sheet1.drop(columns=["_matched"], inplace=True)

    # ── reassign Unit #/Range to be unique within each Unit Group ─────────────
    # Rows are processed in their existing order; each Unit Group gets its own
    # counter starting at 1 and incrementing by 1 for every row in that group.
    print("\nReassigning 'Unit #/Range' per 'Unit Group':")
    group_counters: dict = {}
    for idx, row in sheet1.iterrows():
        group = row["Unit Group"].strip()
        if not group:
            continue                          # leave blank-group rows untouched
        counter = group_counters.get(group, 0) + 1
        group_counters[group] = counter
        sheet1.at[idx, "Unit #/Range"] = str(counter)
        print(f"  Unit Group='{group}' → row {idx + 2} Unit #/Range={counter}")

    # ── write output (Sheet1 only) ────────────────────────────────────────────
    with pd.ExcelWriter(output_path, engine="openpyxl") as writer:
        sheet1.to_excel(writer, sheet_name="Sheet1", index=False)

    print(f"\n{'─'*60}")
    print(f"Done.  Matched : {matched_count}")
    print(f"       Unmatched Sheet2 rows : {len(unmatched_rows)}")
    if unmatched_rows:
        print(f"       Row numbers          : {unmatched_rows}")
    print(f"Output : {output_path}")


# ── entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    s1_path  = pathlib.Path(sys.argv[1]).resolve()
    s2_path  = pathlib.Path(sys.argv[2]).resolve()
    out_path = (
        pathlib.Path(sys.argv[3]).resolve()
        if len(sys.argv) >= 4
        else s1_path.with_name(s1_path.stem + "_updated.xlsx")
    )

    process(str(s1_path), str(s2_path), str(out_path))