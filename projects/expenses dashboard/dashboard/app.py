"""
דשבורד סיכום הוצאות - ממשק ראשי
"""

import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import streamlit as st
import pandas as pd

from parser.encryptor import decrypt, DATA_FILE
from dashboard.charts import (
    EXPENSE_CATEGORIES, CATEGORY_LABELS, MONTH_NAMES_HE,
    income_vs_expenses, category_breakdown_pie, category_bar_monthly,
    trend_by_category, trend_within_year, trend_across_years,
    year_over_year, multi_metric_comparison,
    annual_summary_bar, anomaly_chart, savings_rate,
    cbs_comparison_bar, cbs_delta_bar,
    spending_heatmap, category_treemap,
)
from dashboard.cbs_data import fetch_benchmarks
from dashboard.exporter import export_pdf, export_excel


def _styled_df(df: pd.DataFrame, text_cols: list, num_cols: list):
    """RTL-friendly table: text cols right-aligned & first, numbers centered (cells + headers)."""
    ordered = [c for c in text_cols if c in df.columns] + \
              [c for c in num_cols  if c in df.columns]
    df = df[ordered]
    styler = df.style
    # Cell alignment
    for col in text_cols:
        if col in df.columns:
            styler = styler.set_properties(subset=[col], **{"text-align": "right"})
    for col in num_cols:
        if col in df.columns:
            styler = styler.set_properties(subset=[col], **{"text-align": "center"})
    # Header alignment
    header_styles = [
        {
            "selector": f".col_heading.level0.col{i}",
            "props": f"text-align: {'right' if col in text_cols else 'center'};",
        }
        for i, col in enumerate(ordered)
    ]
    styler = styler.set_table_styles(header_styles, overwrite=False)
    return styler


# ---------------------------------------------------------------------------
# Page config
# ---------------------------------------------------------------------------
st.set_page_config(
    page_title="דשבורד הוצאות",
    page_icon="💰",
    layout="wide",
    initial_sidebar_state="expanded",
)

# ---------------------------------------------------------------------------
# Global CSS
# ---------------------------------------------------------------------------
st.markdown("""
<style>
@import url('https://fonts.googleapis.com/css2?family=Fira+Code:wght@400;500;600&family=Fira+Sans:wght@300;400;500;600;700&family=Heebo:wght@300;400;500;600;700&display=swap');

* { font-family: 'Fira Sans', 'Heebo', sans-serif !important; }

html, body, [class*="css"] {
    direction: rtl;
    font-family: 'Fira Sans', 'Heebo', sans-serif !important;
    background-color: #F8FAFC;
}

/* Hide default streamlit chrome */
#MainMenu, footer, header { visibility: hidden; }
.block-container { padding-top: 1.5rem; padding-bottom: 2rem; }

/* Fix material icon rendering as text */
.material-symbols-rounded { font-size: 0 !important; color: transparent !important; }
[data-testid="collapsedControl"] { display: none !important; }
[data-testid="stSidebarCollapseButton"] span { display: none !important; }
section[data-testid="stSidebarContent"] > div:first-child span[class*="material"] {
    font-size: 0 !important; color: transparent !important;
}

/* -------- LOGIN PAGE -------- */
.login-wrapper {
    display: flex; flex-direction: column;
    align-items: center; justify-content: center;
    min-height: 80vh; text-align: center;
}
.login-card {
    background: linear-gradient(145deg, #0F172A 0%, #1E3A8A 60%, #1E40AF 100%);
    border-radius: 28px;
    padding: 60px 52px;
    max-width: 460px; width: 100%;
    box-shadow: 0 32px 80px rgba(0,0,0,0.45), 0 0 0 1px rgba(59,130,246,0.15);
}
.login-logo { font-size: 68px; margin-bottom: 10px; }
.login-title { color: #fff; font-size: 30px; font-weight: 700; margin-bottom: 6px; letter-spacing: -0.5px; }
.login-subtitle { color: #93C5FD; font-size: 15px; margin-bottom: 32px; }
.login-divider { height: 1px; background: rgba(255,255,255,0.12); margin: 20px 0; }

/* -------- KPI CARDS -------- */
.kpi-grid {
    display: grid;
    grid-template-columns: repeat(5, 1fr);
    gap: 16px; margin-bottom: 24px;
}
.kpi-card {
    background: #fff;
    border-radius: 18px;
    padding: 22px 20px;
    box-shadow: 0 2px 16px rgba(0,0,0,0.07);
    border: 1px solid #E2E8F0;
    border-top: 4px solid #3B82F6;
    text-align: right;
    transition: transform 180ms ease-out, box-shadow 180ms ease-out;
    cursor: default;
}
.kpi-card:hover { transform: translateY(-4px); box-shadow: 0 10px 36px rgba(59,130,246,0.16); }
.kpi-card.green  { border-top-color: #10B981; }
.kpi-card.green:hover  { box-shadow: 0 10px 36px rgba(16,185,129,0.16); }
.kpi-card.red    { border-top-color: #EF4444; }
.kpi-card.red:hover    { box-shadow: 0 10px 36px rgba(239,68,68,0.16); }
.kpi-card.gold   { border-top-color: #F59E0B; }
.kpi-card.gold:hover   { box-shadow: 0 10px 36px rgba(245,158,11,0.16); }
.kpi-card.purple { border-top-color: #8B5CF6; }
.kpi-card.purple:hover { box-shadow: 0 10px 36px rgba(139,92,246,0.16); }
.kpi-label {
    font-size: 10px; color: #64748B; font-weight: 700;
    margin-bottom: 8px; text-transform: uppercase; letter-spacing: 0.8px;
}
.kpi-value {
    font-size: 24px; font-weight: 700; color: #0F172A;
    font-family: 'Fira Code', monospace !important;
}
.kpi-delta { font-size: 12px; margin-top: 6px; font-weight: 500; }
.kpi-delta.pos { color: #10B981; }
.kpi-delta.neg { color: #EF4444; }

/* -------- DASHBOARD HEADER -------- */
.dash-header {
    background: linear-gradient(135deg, #0F172A 0%, #1E3A8A 55%, #1E40AF 100%);
    border-radius: 20px;
    padding: 24px 32px;
    margin-bottom: 24px;
    box-shadow: 0 8px 40px rgba(30,58,138,0.28);
    border: 1px solid rgba(59,130,246,0.18);
}
.dash-header-title {
    color: #fff; font-size: 26px; font-weight: 700; letter-spacing: -0.5px;
}
.dash-header-sub { color: #93C5FD; font-size: 13px; margin-top: 4px; }

/* -------- SECTION HEADERS -------- */
.section-title {
    font-size: 16px; font-weight: 700; color: #0F172A;
    margin-bottom: 14px; padding-bottom: 8px;
    border-bottom: 3px solid #3B82F6;
    display: block; text-align: center; letter-spacing: -0.2px;
}

/* -------- TABS -------- */
.stTabs [data-baseweb="tab-list"] {
    gap: 4px; background: #F1F5F9;
    border-radius: 12px; padding: 4px;
}
.stTabs [data-baseweb="tab"] {
    border-radius: 8px; padding: 8px 16px;
    font-weight: 500; font-size: 14px;
    transition: all 180ms ease-out;
}
.stTabs [aria-selected="true"] {
    background: #1E40AF !important;
    box-shadow: 0 2px 12px rgba(30,64,175,0.35) !important;
    color: white !important;
}

/* -------- SIDEBAR -------- */
[data-testid="stSidebar"] {
    background: linear-gradient(180deg, #0F172A 0%, #1E1B4B 100%);
}
[data-testid="stSidebar"] * { color: #E2E8F0 !important; }
[data-testid="stSidebar"] .stMultiSelect [data-baseweb="tag"] {
    background-color: #1E40AF !important;
}
[data-testid="stSidebar"] hr { border-color: rgba(255,255,255,0.1) !important; }
[data-testid="stSidebar"] .stButton button {
    background: linear-gradient(135deg, #1E40AF, #3B82F6) !important;
    color: white !important; border: none !important;
    border-radius: 8px !important; width: 100%;
    transition: all 180ms ease-out !important;
}
[data-testid="stSidebar"] .stButton button:hover {
    box-shadow: 0 4px 16px rgba(59,130,246,0.4) !important;
    transform: translateY(-1px) !important;
}

/* -------- HIGHLIGHTS CARDS -------- */
.hl-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; margin-bottom: 28px; }
.hl-card {
    background: #fff; border-radius: 20px; padding: 32px 24px;
    box-shadow: 0 4px 24px rgba(0,0,0,0.08);
    border: 1px solid #F1F5F9; border-top: 5px solid #3B82F6;
    text-align: center;
    transition: transform 200ms ease-out, box-shadow 200ms ease-out;
}
.hl-card:hover { transform: translateY(-5px); box-shadow: 0 14px 44px rgba(59,130,246,0.16); }
.hl-card.green  { border-top-color: #10B981; }
.hl-card.green:hover  { box-shadow: 0 14px 44px rgba(16,185,129,0.16); }
.hl-card.red    { border-top-color: #EF4444; }
.hl-card.red:hover    { box-shadow: 0 14px 44px rgba(239,68,68,0.16); }
.hl-card.gold   { border-top-color: #F59E0B; }
.hl-card.gold:hover   { box-shadow: 0 14px 44px rgba(245,158,11,0.16); }
.hl-card.purple { border-top-color: #8B5CF6; }
.hl-card.purple:hover { box-shadow: 0 14px 44px rgba(139,92,246,0.16); }
.hl-card.teal   { border-top-color: #14B8A6; }
.hl-card.teal:hover   { box-shadow: 0 14px 44px rgba(20,184,166,0.16); }
.hl-icon  { font-size: 42px; margin-bottom: 12px; }
.hl-label {
    font-size: 10px; color: #64748B; font-weight: 700;
    margin-bottom: 8px; text-transform: uppercase; letter-spacing: 0.8px;
}
.hl-value {
    font-size: 28px; font-weight: 700; color: #0F172A;
    font-family: 'Fira Code', monospace !important;
}
.hl-sub { font-size: 13px; color: #94A3B8; margin-top: 8px; }

/* -------- TABLES -------- */
[data-testid="stDataFrame"] { border-radius: 12px; overflow: hidden; box-shadow: 0 2px 12px rgba(0,0,0,0.06); }

/* -------- BUTTONS -------- */
.stDownloadButton button, .stButton > button {
    border-radius: 10px !important;
    font-weight: 600 !important;
    font-family: 'Fira Sans', 'Heebo', sans-serif !important;
    transition: all 180ms ease-out !important;
}
</style>
""", unsafe_allow_html=True)


# ---------------------------------------------------------------------------
# Auth helpers
# ---------------------------------------------------------------------------
def load_data(password: str) -> pd.DataFrame:
    records = decrypt(password)
    df = pd.DataFrame(records)
    for col in EXPENSE_CATEGORIES:
        if col not in df.columns:
            df[col] = None
    return df.sort_values(["year", "month"]).reset_index(drop=True)


# ---------------------------------------------------------------------------
# LOGIN PAGE
# ---------------------------------------------------------------------------
if "df" not in st.session_state:
    st.session_state.df = None

if st.session_state.df is None:
    if not os.path.exists(DATA_FILE):
        st.error("קובץ הנתונים לא נמצא. יש להריץ תחילה את `python setup.py`.")
        st.stop()

    st.markdown("""
    <div class="login-wrapper">
        <div class="login-card">
            <div class="login-logo">💰</div>
            <div class="login-title">דשבורד הוצאות</div>
            <div class="login-subtitle">ניהול וניתוח הוצאות משפחתיות</div>
            <div class="login-divider"></div>
        </div>
    </div>
    """, unsafe_allow_html=True)

    col1, col2, col3 = st.columns([1, 1.4, 1])
    with col2:
        st.markdown("<br>", unsafe_allow_html=True)
        with st.form("login", clear_on_submit=True):
            st.markdown("### 🔐 כניסה למערכת")
            password = st.text_input("סיסמה", type="password", placeholder="הכנס סיסמה...")
            submitted = st.form_submit_button("כניסה", use_container_width=True)

        if submitted:
            if not password:
                st.warning("יש להזין סיסמה.")
            else:
                with st.spinner("מפענח נתונים..."):
                    try:
                        df = load_data(password)
                        st.session_state.df = df
                        st.rerun()
                    except ValueError:
                        st.error("סיסמה שגויה. נסה שנית.")
    st.stop()


# ---------------------------------------------------------------------------
# MAIN DASHBOARD
# ---------------------------------------------------------------------------
df: pd.DataFrame = st.session_state.df
all_years  = sorted(df["year"].unique())
all_months = list(range(1, 13))
avail_cats = [c for c in EXPENSE_CATEGORIES if c in df.columns]

# ---------------------------------------------------------------------------
# SIDEBAR - Filters
# ---------------------------------------------------------------------------
with st.sidebar:
    st.markdown("## 🔍 סינון")
    st.markdown("---")

    # Year filter with quick buttons
    st.markdown("**שנים**")
    col_a, col_b = st.columns(2)
    with col_a:
        if st.button("הכל", key="yr_all", use_container_width=True):
            st.session_state["sel_years"] = all_years
    with col_b:
        if st.button("שנה אחרונה", key="yr_last", use_container_width=True):
            st.session_state["sel_years"] = [max(all_years)]

    selected_years = st.multiselect(" ", all_years, key="sel_years")

    st.markdown("**חודשים**")
    col_c, col_d = st.columns(2)
    with col_c:
        if st.button("הכל ", key="mo_all", use_container_width=True):
            st.session_state["sel_months"] = all_months
    with col_d:
        if st.button("רבעון ראשון", key="mo_q1", use_container_width=True):
            st.session_state["sel_months"] = [1, 2, 3]

    selected_months = st.multiselect(
        " ", all_months, key="sel_months",
        format_func=lambda m: MONTH_NAMES_HE[m],
    )

    st.markdown("**קטגוריות הוצאות**")
    col_e, col_f = st.columns(2)
    with col_e:
        if st.button("הכל  ", key="cat_all", use_container_width=True):
            st.session_state["sel_cats"] = avail_cats
    with col_f:
        if st.button("נקה", key="cat_none", use_container_width=True):
            st.session_state["sel_cats"] = []

    selected_cats = st.multiselect(
        " ", avail_cats, key="sel_cats",
        format_func=lambda c: CATEGORY_LABELS.get(c, c),
    )

    st.markdown("---")
    if st.button("🔒 נעילה", use_container_width=True):
        st.session_state.df = None
        st.rerun()

# Initialize filter session state (must happen before widgets are created to avoid conflict)
if "sel_years"  not in st.session_state: st.session_state["sel_years"]  = all_years
if "sel_months" not in st.session_state: st.session_state["sel_months"] = all_months
if "sel_cats"   not in st.session_state: st.session_state["sel_cats"]   = avail_cats

# Apply filters
fdf = df[
    df["year"].isin(selected_years) &
    df["month"].isin(selected_months)
].copy() if selected_years and selected_months else df.copy()

# ---------------------------------------------------------------------------
# HEADER
# ---------------------------------------------------------------------------
year_label = (
    str(selected_years[0]) if len(selected_years) == 1
    else f"{min(selected_years)}-{max(selected_years)}"
    if selected_years else "כל השנים"
)
st.markdown(f"""
<div class="dash-header">
    <div>
        <div class="dash-header-title">💰 דשבורד הוצאות המשפחה</div>
        <div class="dash-header-sub">מציג: {year_label} | {len(fdf)} חודשים | נתונים מ-{min(all_years)} עד {max(all_years)}</div>
    </div>
</div>
""", unsafe_allow_html=True)

# ---------------------------------------------------------------------------
# KPI CARDS
# ---------------------------------------------------------------------------
total_income = fdf["income"].sum()
total_exp    = fdf["total_expenses"].sum()
total_bal    = fdf["balance"].sum()
avg_income   = fdf["income"].mean()
avg_exp      = fdf["total_expenses"].mean()
savings_pct  = (total_bal / total_income * 100) if total_income else 0
bal_class    = "green" if total_bal >= 0 else "red"
sav_class    = "pos" if savings_pct >= 0 else "neg"
sav_arrow    = "▲" if savings_pct >= 0 else "▼"

st.markdown(f"""
<div class="kpi-grid">
    <div class="kpi-card green">
        <div class="kpi-label">סה״כ הכנסות</div>
        <div class="kpi-value">₪{total_income:,.0f}</div>
    </div>
    <div class="kpi-card red">
        <div class="kpi-label">סה״כ הוצאות</div>
        <div class="kpi-value">₪{total_exp:,.0f}</div>
    </div>
    <div class="kpi-card {bal_class}">
        <div class="kpi-label">יתרה נטו</div>
        <div class="kpi-value">₪{total_bal:,.0f}</div>
        <div class="kpi-delta {sav_class}">{sav_arrow} {abs(savings_pct):.1f}% שיעור חיסכון</div>
    </div>
    <div class="kpi-card gold">
        <div class="kpi-label">ממוצע חודשי הכנסות</div>
        <div class="kpi-value">₪{avg_income:,.0f}</div>
    </div>
    <div class="kpi-card purple">
        <div class="kpi-label">ממוצע חודשי הוצאות</div>
        <div class="kpi-value">₪{avg_exp:,.0f}</div>
    </div>
</div>
""", unsafe_allow_html=True)

# ---------------------------------------------------------------------------
# TABS
# ---------------------------------------------------------------------------
# Fetch CBS benchmarks once per session (live attempt, fallback to static)
@st.cache_data(ttl=3600, show_spinner=False)
def _load_cbs():
    return fetch_benchmarks()

cbs_benchmarks, cbs_year = _load_cbs()

tab0, tab1, tab2, tab3, tab4, tab5, tab6, tab7 = st.tabs([
    "✨ תובנות",
    "📊 סקירה כללית",
    "🥧 פירוט קטגוריות",
    "📈 מגמות",
    "🔀 השוואה שנתית",
    "⚠️ חריגות",
    "🇮🇱 השוואה לאומית",
    "📤 ייצוא דוח",
])

# ---- TAB 0: Highlights -----------------------------------------------------
with tab0:
    # Compute highlights from filtered data
    # Exclude months where income is > 2x median (likely a loan receipt inflating the number)
    income_median = fdf["income"].median()
    normal_months = fdf[fdf["income"].notna() & (fdf["income"] <= income_median * 2.5)].copy()

    valid_bal = normal_months["balance"].dropna()
    valid_inc = fdf["income"].dropna()
    valid_exp = fdf["total_expenses"].dropna()
    best_month_row  = normal_months.loc[valid_bal.idxmax()] if not valid_bal.empty else None
    worst_month_row = normal_months.loc[valid_bal.idxmin()] if not valid_bal.empty else None
    avg_savings_pct = (fdf["balance"].sum() / valid_inc.sum() * 100) if valid_inc.sum() else 0

    top_cat, top_cat_val = None, 0
    for cat in avail_cats:
        v = fdf[cat].dropna().sum()
        if v > top_cat_val:
            top_cat_val, top_cat = v, cat

    # Trend direction (last 3 months vs previous 3) - exclude NaN
    sorted_fdf = fdf.sort_values(["year", "month"])
    recent_exp = sorted_fdf["total_expenses"].dropna().tail(3)
    prev_exp   = sorted_fdf["total_expenses"].dropna().iloc[-6:-3]
    if len(recent_exp) >= 2 and len(prev_exp) >= 2:
        trend_delta = recent_exp.mean() - prev_exp.mean()
        trend_icon  = "📈" if trend_delta > 0 else "📉"
        direction   = "עלו" if trend_delta > 0 else "ירדו"
        trend_text  = f"הוצאות {direction} ב-₪{abs(trend_delta):,.0f}"
    else:
        trend_icon, trend_text = "➡️", "אין מספיק נתונים"

    st.markdown("""
    <style>
    .hl-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; margin-bottom: 24px; }
    .hl-card {
        background: #fff; border-radius: 16px; padding: 28px 24px;
        box-shadow: 0 4px 20px rgba(0,0,0,0.08);
        border-top: 5px solid #3498db;
        text-align: center;
    }
    .hl-card.green  { border-top-color: #27ae60; }
    .hl-card.red    { border-top-color: #e74c3c; }
    .hl-card.gold   { border-top-color: #f39c12; }
    .hl-card.purple { border-top-color: #9b59b6; }
    .hl-card.teal   { border-top-color: #1abc9c; }
    .hl-icon  { font-size: 40px; margin-bottom: 10px; }
    .hl-label { font-size: 13px; color: #7f8c8d; font-weight: 500; margin-bottom: 6px; }
    .hl-value { font-size: 26px; font-weight: 700; color: #2c3e50; }
    .hl-sub   { font-size: 13px; color: #95a5a6; margin-top: 6px; }
    </style>
    """, unsafe_allow_html=True)

    bm_label = f"{MONTH_NAMES_HE.get(int(best_month_row['month']), '')} {int(best_month_row['year'])}" if best_month_row is not None else "-"
    wm_label = f"{MONTH_NAMES_HE.get(int(worst_month_row['month']), '')} {int(worst_month_row['year'])}" if worst_month_row is not None else "-"

    st.markdown(f"""
    <div class="hl-grid">
        <div class="hl-card green">
            <div class="hl-icon">💰</div>
            <div class="hl-label">סה״כ נחסך</div>
            <div class="hl-value">₪{total_bal:,.0f}</div>
            <div class="hl-sub">{avg_savings_pct:.1f}% מהכנסות</div>
        </div>
        <div class="hl-card gold">
            <div class="hl-icon">🏆</div>
            <div class="hl-label">חודש עם היתרה הגבוהה</div>
            <div class="hl-value">{bm_label}</div>
            <div class="hl-sub">₪{valid_bal.max():,.0f} יתרה</div>
        </div>
        <div class="hl-card red">
            <div class="hl-icon">⚠️</div>
            <div class="hl-label">חודש עם היתרה הנמוכה</div>
            <div class="hl-value">{wm_label}</div>
            <div class="hl-sub">₪{valid_bal.min():,.0f} יתרה</div>
        </div>
        <div class="hl-card purple">
            <div class="hl-icon">🏷️</div>
            <div class="hl-label">קטגוריה גדולה ביותר</div>
            <div class="hl-value">{CATEGORY_LABELS.get(top_cat, '-') if top_cat else '-'}</div>
            <div class="hl-sub">₪{top_cat_val:,.0f} סה״כ</div>
        </div>
        <div class="hl-card teal">
            <div class="hl-icon">{trend_icon}</div>
            <div class="hl-label">מגמה (3 חודשים אחרונים)</div>
            <div class="hl-value">{trend_text}</div>
            <div class="hl-sub">לעומת 3 החודשים הקודמים</div>
        </div>
        <div class="hl-card">
            <div class="hl-icon">📅</div>
            <div class="hl-label">חודשים בתקופה</div>
            <div class="hl-value">{len(fdf)}</div>
            <div class="hl-sub">{min(all_years)} - {max(all_years)}</div>
        </div>
    </div>
    """, unsafe_allow_html=True)

    # Category ranking table
    st.markdown('<div class="section-title">דירוג קטגוריות הוצאות</div>', unsafe_allow_html=True)
    rank_rows = []
    total_exp_sum = fdf["total_expenses"].sum() or 1
    for i, cat in enumerate(avail_cats):
        val = fdf[cat].dropna().sum()
        if val > 0:
            rank_rows.append({
                "דירוג": f"#{len(rank_rows)+1}",
                "קטגוריה": CATEGORY_LABELS.get(cat, cat),
                "סה״כ": f"₪{val:,.0f}",
                "ממוצע חודשי": f"₪{fdf[cat].dropna().mean():,.0f}",
                "אחוז מההוצאות": f"{val / total_exp_sum * 100:.1f}%",
            })
    if rank_rows:
        rank_df = pd.DataFrame(rank_rows)
        st.dataframe(
            _styled_df(rank_df, ["דירוג", "קטגוריה"], ["סה״כ", "ממוצע חודשי", "אחוז מההוצאות"]),
            hide_index=True, use_container_width=True,
        )

# ---- TAB 1: Overview -------------------------------------------------------
with tab1:
    st.plotly_chart(income_vs_expenses(fdf), use_container_width=True)

    c1, c2 = st.columns(2)
    with c1:
        st.plotly_chart(annual_summary_bar(fdf, "income"), use_container_width=True)
    with c2:
        st.plotly_chart(annual_summary_bar(fdf, "total_expenses"), use_container_width=True)

    st.plotly_chart(savings_rate(fdf), use_container_width=True)
    st.plotly_chart(spending_heatmap(fdf), use_container_width=True)

    st.markdown('<div class="section-title">חודשים מובילים</div>', unsafe_allow_html=True)
    show = fdf[["year", "month", "income", "total_expenses", "balance"]].copy()
    show["month_name"] = show["month"].map(MONTH_NAMES_HE)
    show = show.sort_values("balance", ascending=False)

    cb, cw = st.columns(2)
    def fmt_table(d):
        d = (d[["year", "month_name", "income", "total_expenses", "balance"]]
             .rename(columns={"year": "שנה", "month_name": "חודש",
                              "income": "הכנסות", "total_expenses": "הוצאות", "balance": "יתרה"}))
        for col in ["הכנסות", "הוצאות", "יתרה"]:
            d[col] = d[col].apply(lambda v: f"₪{v:,.0f}" if pd.notna(v) else "-")
        return _styled_df(d, ["שנה", "חודש"], ["הכנסות", "הוצאות", "יתרה"])

    with cb:
        st.markdown("**5 חודשים עם היתרה הגבוהה ביותר**")
        st.dataframe(fmt_table(show.head(5)), hide_index=True, use_container_width=True)
    with cw:
        st.markdown("**5 חודשים עם היתרה הנמוכה ביותר**")
        st.dataframe(fmt_table(show.tail(5)), hide_index=True, use_container_width=True)

# ---- TAB 2: Category Breakdown ---------------------------------------------
with tab2:
    year_for_pie = st.selectbox(
        "בחר שנה לפירוט", ["כל השנים"] + [str(y) for y in all_years], key="pie_year"
    )
    pie_df = fdf if year_for_pie == "כל השנים" else fdf[fdf["year"] == int(year_for_pie)]

    yr_arg = None if year_for_pie == "כל השנים" else int(year_for_pie)

    c1, c2 = st.columns([1, 1])
    with c1:
        st.plotly_chart(category_breakdown_pie(pie_df, yr_arg), use_container_width=True)
    with c2:
        total_for_pct = pie_df["total_expenses"].sum() or 1
        cat_rows = []
        for cat in avail_cats:
            val = pie_df[cat].sum() if cat in pie_df.columns else 0
            if val and val > 0:
                cat_rows.append({
                    "קטגוריה": CATEGORY_LABELS.get(cat, cat),
                    "סכום": f"₪{val:,.0f}",
                    "אחוז מהוצאות": f"{val / total_for_pct * 100:.1f}%",
                    "_sort": val,
                })
        if cat_rows:
            cat_df = pd.DataFrame(cat_rows).sort_values("_sort", ascending=False).drop(columns=["_sort"])
            st.dataframe(_styled_df(cat_df, ["קטגוריה"], ["סכום", "אחוז מהוצאות"]),
                         hide_index=True, use_container_width=True)

    st.plotly_chart(category_treemap(pie_df, yr_arg), use_container_width=True)

    cats_to_show = selected_cats if selected_cats else avail_cats
    st.plotly_chart(category_bar_monthly(fdf, cats_to_show), use_container_width=True)

# ---- TAB 3: Trends ---------------------------------------------------------
with tab3:
    trend_opts = ["income", "total_expenses", "balance"] + avail_cats
    trend_cat = st.selectbox(
        "בחר מדד", trend_opts,
        format_func=lambda c: CATEGORY_LABELS.get(c, c),
        key="trend_cat",
    )

    t_sub1, t_sub2, t_sub3 = st.tabs([
        "📅 ציר זמן מלא",
        "📆 מגמה בתוך שנה",
        "📊 מגמה בין שנים",
    ])

    with t_sub1:
        st.plotly_chart(trend_by_category(fdf, trend_cat), use_container_width=True)

    with t_sub2:
        year_for_trend = st.selectbox(
            "בחר שנה", sorted(fdf["year"].unique(), reverse=True),
            format_func=lambda y: str(int(y)),
            key="trend_year",
        )
        if trend_cat in fdf.columns:
            st.plotly_chart(trend_within_year(fdf, trend_cat, int(year_for_trend)), use_container_width=True)

    with t_sub3:
        st.plotly_chart(trend_across_years(fdf, trend_cat), use_container_width=True)

    st.markdown('<div class="section-title">ממוצעים שנתיים</div>', unsafe_allow_html=True)
    avg_data = fdf.groupby("year")[trend_cat].agg(["mean", "sum", "min", "max"]).reset_index()
    avg_data["שנה"] = avg_data["year"].astype(int).astype(str)
    avg_data = avg_data.drop(columns=["year"]).sort_values("sum", ascending=False)
    avg_data.columns = ["ממוצע חודשי", "סה״כ שנתי", "מינימום", "מקסימום", "שנה"]
    for col in ["ממוצע חודשי", "סה״כ שנתי", "מינימום", "מקסימום"]:
        avg_data[col] = avg_data[col].apply(lambda v: f"₪{v:,.0f}" if pd.notna(v) else "-")
    st.dataframe(
        _styled_df(avg_data, ["שנה"], ["ממוצע חודשי", "סה״כ שנתי", "מינימום", "מקסימום"]),
        hide_index=True, use_container_width=True,
    )

# ---- TAB 4: Year-over-Year -------------------------------------------------
with tab4:
    st.markdown("#### השוואת שנים לפי מדד אחד")
    yoy_metric = st.selectbox(
        "מדד להשוואה",
        ["income", "total_expenses", "balance"] + avail_cats,
        format_func=lambda c: CATEGORY_LABELS.get(c, c),
        key="yoy_metric",
    )
    yoy_years = st.multiselect(
        "שנים להשוואה", all_years,
        default=all_years[-3:] if len(all_years) >= 3 else all_years,
        key="yoy_years",
    )
    if yoy_years:
        st.plotly_chart(year_over_year(df, yoy_metric, yoy_years), use_container_width=True)

    st.markdown("---")
    st.markdown("#### השוואת מספר מדדים בין שנים")
    multi_years = st.multiselect(
        "שנים", all_years,
        default=all_years[-3:] if len(all_years) >= 3 else all_years,
        key="multi_years",
    )
    multi_metrics = st.multiselect(
        "מדדים להשוואה",
        ["income", "total_expenses", "balance"] + avail_cats,
        default=["income", "total_expenses", "balance"],
        format_func=lambda c: CATEGORY_LABELS.get(c, c),
        key="multi_metrics",
    )
    if multi_years and multi_metrics:
        st.plotly_chart(multi_metric_comparison(df, multi_metrics, multi_years), use_container_width=True)

        # Comparison table with % change vs first selected year
        st.markdown('<div class="section-title">טבלת השוואה</div>', unsafe_allow_html=True)
        base_year = min(multi_years)
        annual = df[df["year"].isin(multi_years)].groupby("year")[multi_metrics].sum()
        base = annual.loc[base_year] if base_year in annual.index else None

        rows = []
        for yr in sorted(multi_years):
            if yr not in annual.index:
                continue
            row = {"שנה": str(int(yr))}
            for m in multi_metrics:
                val = annual.loc[yr, m]
                row[CATEGORY_LABELS.get(m, m)] = f"₪{val:,.0f}"
                if base is not None and yr != base_year and base[m]:
                    pct = (val - base[m]) / abs(base[m]) * 100
                    row[f"{CATEGORY_LABELS.get(m, m)} %"] = f"{pct:+.1f}%"
            rows.append(row)
        if rows:
            comp_df = pd.DataFrame(rows)
            metric_cols = [c for c in comp_df.columns if c != "שנה"]
            st.dataframe(
                _styled_df(comp_df, ["שנה"], metric_cols),
                hide_index=True, use_container_width=True,
            )

# ---- TAB 5: Anomalies ------------------------------------------------------
with tab5:
    anom_metric = st.selectbox(
        "בחר מדד לניתוח חריגות",
        ["total_expenses", "income", "balance"] + avail_cats,
        format_func=lambda c: CATEGORY_LABELS.get(c, c),
        key="anom_metric",
    )
    st.plotly_chart(anomaly_chart(fdf, anom_metric), use_container_width=True)

    col = fdf[anom_metric].dropna()
    mean, std = col.mean(), col.std()
    anom = fdf.loc[col.index][abs(col - mean) > 1.5 * std].copy()
    anom["month_name"] = anom["month"].map(MONTH_NAMES_HE)
    anom["סטייה"] = (col[anom.index] - mean).apply(lambda v: f"₪{v:+,.0f}")

    if not anom.empty:
        st.markdown(f'<div class="section-title">חודשים חריגים ({len(anom)} נמצאו)</div>', unsafe_allow_html=True)
        disp = anom[["year", "month_name", anom_metric, "סטייה"]].rename(columns={
            "year": "שנה", "month_name": "חודש",
            anom_metric: CATEGORY_LABELS.get(anom_metric, anom_metric),
        })
        metric_col = CATEGORY_LABELS.get(anom_metric, anom_metric)
        disp[metric_col] = disp[metric_col].apply(lambda v: f"₪{v:,.0f}" if pd.notna(v) else "-")
        st.dataframe(
            _styled_df(disp, ["שנה", "חודש"], [metric_col, "סטייה"]),
            hide_index=True, use_container_width=True,
        )
    else:
        st.info("לא נמצאו חריגות בתקופה הנבחרת.")

# ---- TAB 6: National Benchmark (CBS / Lamas) --------------------------------
with tab6:
    st.markdown(f"""
    <div style="background:#f0f4ff;border-radius:12px;padding:14px 18px;margin-bottom:16px;
                border-right:4px solid #3498db;font-size:14px;color:#2c3e50;">
        📊 נתוני הלמ"ס מסקר הוצאות משקי בית {cbs_year} | ממוצע משק בית ישראלי (~3.3 נפשות)
        <br><span style="font-size:12px;color:#7f8c8d;">
        הנתונים נטענים בכל כניסה לדשבורד מאתר הלמ"ס. ייתכנו הבדלים בגודל משק הבית.</span>
    </div>
    """, unsafe_allow_html=True)

    # User monthly averages per category (from filtered data)
    user_avg = {cat: fdf[cat].dropna().mean() for cat in EXPENSE_CATEGORIES if cat in fdf.columns}

    st.plotly_chart(cbs_comparison_bar(user_avg, cbs_benchmarks), use_container_width=True)
    st.plotly_chart(cbs_delta_bar(user_avg, cbs_benchmarks), use_container_width=True)

    # Summary table
    st.markdown('<div class="section-title">טבלת השוואה מפורטת</div>', unsafe_allow_html=True)
    cbs_rows = []
    for cat, (cbs_val, cbs_lbl) in cbs_benchmarks.items():
        user_val = user_avg.get(cat)
        if user_val and user_val > 0:
            delta = user_val - cbs_val
            delta_pct = delta / cbs_val * 100 if cbs_val else 0
            status = "🔴 גבוה מהממוצע" if delta_pct > 15 else "🟢 נמוך מהממוצע" if delta_pct < -15 else "🟡 קרוב לממוצע"
            cbs_rows.append({
                "קטגוריה": CATEGORY_LABELS.get(cat, cat),
                "ממוצע שלי": f"₪{user_val:,.0f}",
                "ממוצע לאומי": f"₪{cbs_val:,.0f}",
                "הפרש": f"₪{delta:+,.0f}",
                "סטייה %": f"{delta_pct:+.1f}%",
                "סטטוס": status,
            })
    if cbs_rows:
        cbs_df = pd.DataFrame(cbs_rows).sort_values("סטייה %", ascending=False)
        st.dataframe(
            _styled_df(cbs_df, ["קטגוריה", "סטטוס"], ["ממוצע שלי", "ממוצע לאומי", "הפרש", "סטייה %"]),
            hide_index=True, use_container_width=True,
        )

# ---- TAB 7: Export ---------------------------------------------------------
with tab7:
    report_title = st.text_input("כותרת הדוח", value=f"דוח הוצאות - {year_label}")
    c1, c2 = st.columns(2)
    with c1:
        st.markdown("**📄 דוח PDF** - סיכום, פירוט שנתי וקטגוריות")
        pdf_bytes = export_pdf(fdf, report_title)
        st.download_button(
            "⬇️ הורד PDF", data=pdf_bytes,
            file_name=f"expenses_{year_label}.pdf",
            mime="application/pdf", use_container_width=True,
        )
    with c2:
        st.markdown("**📊 קובץ Excel** - פירוט חודשי + סיכום שנתי")
        xlsx_bytes = export_excel(fdf, report_title)
        st.download_button(
            "⬇️ הורד Excel", data=xlsx_bytes,
            file_name=f"expenses_{year_label}.xlsx",
            mime="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            use_container_width=True,
        )

    st.markdown("---")
    st.markdown('<div class="section-title">נתונים גולמיים</div>', unsafe_allow_html=True)
    display_df = fdf.copy()
    display_df["month"] = display_df["month"].map(MONTH_NAMES_HE)
    display_df = display_df.rename(columns={**CATEGORY_LABELS, "month": "חודש", "year": "שנה"})
    st.dataframe(display_df, use_container_width=True)
