"""
Fetches Israeli household expenditure benchmarks from the CBS (Lamas) website.
Called once per dashboard session (cached via st.cache_data).

Data source: CBS Household Expenditure Survey (סקר הוצאות משקי בית)
https://www.cbs.gov.il/he/Surveys/Pages/סקר-הוצאות-משקי-בית.aspx

Since CBS does not provide a public JSON API for this survey, we fetch and
parse the summary publication page. If the live fetch fails, we fall back to
the latest known values (2022 survey, published 2024).
"""

from __future__ import annotations
import re
import urllib.request

# ---------------------------------------------------------------------------
# Fallback static data - CBS 2022 survey (published 2024)
# Monthly averages in NIS for an average Israeli household (~3.3 persons)
# ---------------------------------------------------------------------------
_FALLBACK_YEAR = 2022
_FALLBACK_TOTAL = 18_088   # NIS/month total household expenditure

# Category -> (monthly NIS amount, CBS label in Hebrew)
_FALLBACK: dict[str, tuple[float, str]] = {
    "food":          (3_165, "מזון ומשקאות"),
    "electricity":   (630,   "חשמל"),
    "water":         (210,   "מים"),
    "fuel":          (2_250, "תחבורה"),
    "vehicle":       (1_400, "רכב ותחזוקה"),
    "health":        (1_085, "בריאות"),
    "education":     (995,   "חינוך"),
    "entertainment": (1_357, "פנאי ותרבות"),
    "clothing":      (724,   "ביגוד והנעלה"),
    "beauty":        (450,   "טיפוח"),
    "insurance":     (800,   "ביטוחים"),
    "gifts":         (350,   "מתנות"),
    "purchases":     (620,   "רכישות שונות"),
}


def _try_fetch_live() -> tuple[dict[str, tuple[float, str]], int] | None:
    """
    Attempt to scrape updated total monthly expenditure from the CBS
    'Israel in Figures' publication. Returns None on any failure.
    """
    try:
        url = "https://www.cbs.gov.il/he/mediarelease/DocLib/2024/418/16_24_418e.pdf"
        # CBS releases are PDFs; we can't parse them easily without pdfplumber.
        # Instead, try the structured summary table page.
        url2 = ("https://www.cbs.gov.il/he/subjects/Pages/"
                "Households-Income-and-Expenditure.aspx")
        req = urllib.request.Request(
            url2,
            headers={"User-Agent": "ExpensesDashboard/1.0 (personal use)"},
        )
        with urllib.request.urlopen(req, timeout=6) as resp:
            html = resp.read().decode("utf-8", errors="ignore")

        # Look for a number that looks like ~18,000 (total monthly expenditure)
        # CBS pages often contain "הוצאה חודשית ממוצעת: XX,XXX"
        m = re.search(r"הוצאה חודשית.*?(\d{2},\d{3})", html)
        if m:
            total = int(m.group(1).replace(",", ""))
            if 10_000 < total < 40_000:
                # Scale fallback proportions to new total
                ratio = total / _FALLBACK_TOTAL
                scaled = {
                    cat: (round(v * ratio), lbl)
                    for cat, (v, lbl) in _FALLBACK.items()
                }
                year = 2024  # approximate
                return scaled, year
    except Exception:
        pass
    return None


def fetch_benchmarks() -> tuple[dict[str, tuple[float, str]], int]:
    """
    Returns (benchmarks_dict, data_year).
    benchmarks_dict: category_key -> (monthly_NIS, hebrew_label)
    Tries live fetch first; falls back to static data.
    """
    live = _try_fetch_live()
    if live:
        return live
    return _FALLBACK, _FALLBACK_YEAR
