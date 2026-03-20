"""
Normalizes raw extracted data from all eras into a unified schema.

Unified record (per month):
    year, month, income, total_expenses, balance,
    loans, insurance, subscriptions, clothing, health,
    beauty, entertainment, education, gifts, vehicle,
    purchases, fuel, food, water, electricity, other_fixed, other_variable
"""

from __future__ import annotations
import re

# Canonical field names
FIELDS = [
    "year", "month", "income", "total_expenses", "balance",
    "loans", "insurance", "subscriptions", "clothing", "health",
    "beauty", "entertainment", "education", "gifts", "vehicle",
    "purchases", "fuel", "food", "water", "electricity",
    "other_fixed", "other_variable",
]

# Hebrew label -> canonical field
LABEL_MAP = {
    # income / summary
    "הכנסות": "income",
    "הוצאות": "total_expenses",
    "יתרה": "balance",
    # fixed
    "הלוואות": "loans",
    "משכנתא": "loans",
    "ביטוחים": "insurance",
    "ביטוחים (למעט רכב)": "insurance",
    "מינויים": "subscriptions",
    "חיובים אחרים": "other_fixed",
    # periodic
    "ביגוד והנעלה": "clothing",
    "ביגוד": "clothing",
    "בריאות": "health",
    "פנאי ובילויים": "entertainment",
    "פ.ב.ב": "entertainment",
    "השכלה וחוגים": "education",
    "חינוך פורמאלי ובלתי פורמאלי": "education",
    "יופי וטיפוח": "beauty",
    "מתנות לאירועים ושמחות": "gifts",
    "מתנות": "gifts",
    "רכב": "vehicle",
    "רכישות ושירותים": "purchases",
    "רכישות": "purchases",
    # variable
    "דלק, תחבורה וחניה": "fuel",
    "דלק בלבד": "fuel",
    "דלק": "fuel",
    "מזון וצריכה ביתית": "food",
    "מזון וצריכה": "food",
    "מים": "water",
    "חשמל": "electricity",
    " קהילה": "other_variable",
    "ארנונה וביוב": "other_variable",
}

HEBREW_MONTHS = {
    "ינואר": 1, "פברואר": 2, "מרץ": 3, "אפריל": 4,
    "מאי": 5, "יוני": 6, "יולי": 7, "אוגוסט": 8,
    "ספטמבר": 9, "אוקטובר": 10, "נובמבר": 11, "דצמבר": 12,
}


def _safe_float(v) -> float | None:
    if v is None:
        return None
    if isinstance(v, (int, float)):
        f = float(v)
        return None if (f != f) else f  # NaN check
    if isinstance(v, str):
        v = v.strip().replace(",", "").replace("#REF!", "")
        try:
            return float(v) if v else None
        except ValueError:
            return None
    return None


def _empty_record(year: int, month: int) -> dict:
    rec = {f: None for f in FIELDS}
    rec["year"] = year
    rec["month"] = month
    return rec


def _normalize_summary_modern(rows: list[list], year: int) -> list[dict]:
    """2025+ format: סיכום שנה/שנתי - header row then one row per month."""
    records = []
    header = None
    seen_months: set[int] = set()

    for row in rows:
        values = [c for c in row]
        if not any(v for v in values):
            continue

        # Find header row (contains 'חודש' or 'הכנסות')
        if header is None:
            str_vals = [str(v).strip() if v else "" for v in values]
            if "חודש" in str_vals or "הכנסות" in str_vals:
                header = str_vals
            continue

        month_label = str(values[0]).strip() if values[0] else ""
        month_num = HEBREW_MONTHS.get(month_label)
        if month_num is None or month_num in seen_months:
            continue

        seen_months.add(month_num)
        rec = _empty_record(year, month_num)
        for col_idx, label in enumerate(header):
            if col_idx >= len(values):
                break
            field = LABEL_MAP.get(label)
            if field and rec[field] is None:
                rec[field] = _safe_float(values[col_idx])

        records.append(rec)

    return records


def _normalize_summary_mid(rows: list[list], year: int) -> list[dict]:
    """2014-2024 format: סה"כ sheet - header row then one row per month.
    Some files have a salary sub-table below that also lists months - we
    stop after collecting the first occurrence of each month to avoid duplication.
    """
    records = []
    header = None
    seen_months: set[int] = set()

    for row in rows:
        values = list(row)
        if not any(v for v in values):
            continue

        str_vals = [str(v).strip() if v else "" for v in values]

        if header is None:
            # Header row: second cell is 'הכנסות'
            if len(str_vals) > 1 and str_vals[1] == "הכנסות":
                header = str_vals
            continue

        month_label = str_vals[0] if str_vals else ""
        month_num = HEBREW_MONTHS.get(month_label)
        if month_num is None or month_num in seen_months:
            continue

        seen_months.add(month_num)
        rec = _empty_record(year, month_num)
        for col_idx, label in enumerate(header):
            if col_idx >= len(values):
                break
            field = LABEL_MAP.get(label)
            if field and rec[field] is None:
                rec[field] = _safe_float(values[col_idx])

        records.append(rec)

    return records


def _normalize_monthly_sheet(rows: list[list], year: int, month: int) -> dict | None:
    """
    Fallback: parse individual monthly sheet for summary totals.
    Looks for rows with known labels and their totals.
    """
    rec = _empty_record(year, month)
    found_any = False

    for row in rows:
        values = list(row)
        for col_idx, cell in enumerate(values):
            label = str(cell).strip() if cell else ""
            field = LABEL_MAP.get(label)
            if field is None:
                continue
            # Look for the next numeric value in the same row
            for val in values[col_idx + 1:]:
                num = _safe_float(val)
                if num is not None and num > 0:
                    if rec[field] is None:
                        rec[field] = num
                        found_any = True
                    break

    return rec if found_any else None


def _normalize_legacy_2013(raw: dict, year: int) -> list[dict]:
    """2013: only monthly sheets, very different structure."""
    records = []
    for month_num, rows in raw["monthly"].items():
        rec = _normalize_monthly_sheet(rows, year, month_num)
        if rec:
            records.append(rec)
    return records


def normalize(raw_all: dict[int, dict]) -> list[dict]:
    """
    Takes output of extractor.extract_all() and returns
    a flat list of normalized monthly records.
    """
    all_records = []

    for year in sorted(raw_all.keys()):
        raw = raw_all[year]
        summary = raw.get("summary")
        monthly = raw.get("monthly", {})

        records = []

        if year == 2013:
            records = _normalize_legacy_2013(raw, year)

        elif summary is not None:
            if year >= 2025:
                records = _normalize_summary_modern(summary, year)
            else:
                records = _normalize_summary_mid(summary, year)

            # Fill any missing months from individual monthly sheets
            covered = {r["month"] for r in records}
            for month_num, rows in monthly.items():
                if month_num not in covered:
                    rec = _normalize_monthly_sheet(rows, year, month_num)
                    if rec:
                        records.append(rec)

        else:
            # No summary sheet - parse each monthly sheet
            for month_num, rows in monthly.items():
                rec = _normalize_monthly_sheet(rows, year, month_num)
                if rec:
                    records.append(rec)

        # Derive missing totals where possible
        for rec in records:
            if rec["total_expenses"] is None:
                expense_fields = [
                    "loans", "insurance", "subscriptions", "other_fixed",
                    "clothing", "health", "beauty", "entertainment",
                    "education", "gifts", "vehicle", "purchases",
                    "fuel", "food", "water", "electricity",
                    "other_variable",
                ]
                vals = [rec[f] for f in expense_fields if rec[f] is not None]
                if vals:
                    rec["total_expenses"] = sum(vals)

            if rec["balance"] is None and rec["income"] and rec["total_expenses"]:
                rec["balance"] = rec["income"] - rec["total_expenses"]

        print(f"[normalizer] {year}: {len(records)} months normalized")
        all_records.extend(records)

    return all_records
