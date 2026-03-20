"""
Plotly chart builders - Hebrew labels, RTL layout, financial dashboard styling.
"""

import pandas as pd
import plotly.graph_objects as go
import plotly.express as px

CATEGORY_LABELS = {
    "income":         "הכנסות",
    "total_expenses": "סה״כ הוצאות",
    "balance":        "יתרה",
    "loans":          "הלוואות",
    "insurance":      "ביטוחים",
    "subscriptions":  "מנויים",
    "clothing":       "ביגוד והנעלה",
    "health":         "בריאות",
    "beauty":         "יופי וטיפוח",
    "entertainment":  "פנאי ובילויים",
    "education":      "חינוך והשכלה",
    "gifts":          "מתנות ואירועים",
    "vehicle":        "רכב",
    "purchases":      "רכישות ושירותים",
    "fuel":           "דלק ותחבורה",
    "food":           "מזון וצריכה ביתית",
    "water":          "מים",
    "electricity":    "חשמל",
    "other_fixed":    "אחר (קבוע)",
    "other_variable": "אחר (משתנה)",
}

EXPENSE_CATEGORIES = [
    "loans", "insurance", "subscriptions", "other_fixed",
    "clothing", "health", "beauty", "entertainment",
    "education", "gifts", "vehicle", "purchases",
    "fuel", "food", "water", "electricity", "other_variable",
]

MONTH_NAMES_HE = {
    1: "ינואר", 2: "פברואר", 3: "מרץ", 4: "אפריל",
    5: "מאי", 6: "יוני", 7: "יולי", 8: "אוגוסט",
    9: "ספטמבר", 10: "אוקטובר", 11: "נובמבר", 12: "דצמבר",
}

C_INCOME      = "#2ecc71"
C_EXPENSE     = "#e74c3c"
C_BALANCE_POS = "#27ae60"
C_BALANCE_NEG = "#c0392b"
C_PRIMARY     = "#3498db"
C_NEUTRAL     = "#95a5a6"
PALETTE       = px.colors.qualitative.Set2

LAYOUT_BASE = dict(
    paper_bgcolor="rgba(0,0,0,0)",
    plot_bgcolor="rgba(0,0,0,0)",
    font=dict(family="Heebo, Arial, sans-serif", size=13, color="#2c3e50"),
    margin=dict(l=70, r=20, t=80, b=60),
    hoverlabel=dict(font_family="Heebo, Arial, sans-serif"),
    uniformtext=dict(mode="hide", minsize=8),
)


def _label(field: str) -> str:
    return CATEGORY_LABELS.get(field, field)


def _period_label(year: int, month: int) -> str:
    return f"{MONTH_NAMES_HE[month]} {year}"


def _apply_base(fig: go.Figure, title: str = "") -> go.Figure:
    fig.update_layout(
        **LAYOUT_BASE,
        title=dict(text=title, font=dict(size=16, color="#2c3e50"), x=0.5, xanchor="center"),
    )
    fig.update_xaxes(showgrid=False, zeroline=False)
    fig.update_yaxes(gridcolor="#ecf0f1", zeroline=False)
    return fig


def _fix_timeline_xaxis(fig: go.Figure, n_points: int) -> go.Figure:
    """Reduce x-axis tick density for long timelines."""
    if n_points > 36:
        fig.update_xaxes(nticks=18, tickangle=-45, tickfont=dict(size=11))
    elif n_points > 18:
        fig.update_xaxes(nticks=n_points, tickangle=-45, tickfont=dict(size=11))
    else:
        fig.update_xaxes(tickangle=-30, tickfont=dict(size=11))
    return fig


def _bar_label_fmt(v: float) -> str:
    """Compact label: 12,500 -> ₪12.5K"""
    if abs(v) >= 1_000_000:
        return f"₪{v/1_000_000:.1f}M"
    if abs(v) >= 1_000:
        return f"₪{v/1_000:.1f}K"
    return f"₪{v:,.0f}"


# ---------------------------------------------------------------------------
# OVERVIEW CHARTS
# ---------------------------------------------------------------------------

def income_vs_expenses(df: pd.DataFrame) -> go.Figure:
    df = df.sort_values(["year", "month"]).copy()
    df["period"] = df.apply(lambda r: _period_label(r["year"], r["month"]), axis=1)

    fig = go.Figure()
    fig.add_trace(go.Scatter(
        x=df["period"], y=df["income"], name="הכנסות",
        line=dict(color=C_INCOME, width=2.5),
        hovertemplate="הכנסות: ₪%{y:,.0f}<extra></extra>",
    ))
    fig.add_trace(go.Scatter(
        x=df["period"], y=df["total_expenses"], name="הוצאות",
        line=dict(color=C_EXPENSE, width=2.5),
        hovertemplate="הוצאות: ₪%{y:,.0f}<extra></extra>",
    ))
    bal = df["balance"].fillna(0)
    fig.add_trace(go.Bar(
        x=df["period"], y=bal, name="יתרה",
        marker_color=[C_BALANCE_POS if v >= 0 else C_BALANCE_NEG for v in bal],
        opacity=0.5,
        text=[_bar_label_fmt(v) for v in bal],
        textposition="outside",
        textfont=dict(size=10),
        hovertemplate="יתרה: ₪%{y:,.0f}<extra></extra>",
    ))
    _apply_base(fig, "הכנסות מול הוצאות")
    min_bal = df["balance"].fillna(0).min()
    max_val = max(df["income"].fillna(0).max(), df["total_expenses"].fillna(0).max())
    fig.update_layout(
        hovermode="x unified",
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="left", x=0),
        yaxis_title="סכום (₪)",
        yaxis=dict(range=[min(min_bal * 1.3, 0), max_val * 1.2]),
    )
    _fix_timeline_xaxis(fig, len(df))
    return fig


def annual_summary_bar(df: pd.DataFrame, metric: str) -> go.Figure:
    annual = df.groupby("year")[metric].sum().reset_index()
    color_map = {"income": C_INCOME, "total_expenses": C_EXPENSE}
    bar_color = color_map.get(metric, C_PRIMARY)
    vals = annual[metric]
    fig = go.Figure(go.Bar(
        x=annual["year"].astype(str), y=vals,
        marker_color=bar_color,
        text=[_bar_label_fmt(v) for v in vals],
        textposition="outside",
        textfont=dict(size=11, color="#2c3e50"),
        hovertemplate="%{x}: ₪%{y:,.0f}<extra></extra>",
    ))
    _apply_base(fig, f"סיכום שנתי: {_label(metric)}")
    fig.update_layout(yaxis_title="סכום (₪)", xaxis_title="שנה",
                      yaxis=dict(range=[0, vals.max() * 1.15]))
    return fig


def savings_rate(df: pd.DataFrame) -> go.Figure:
    df = df.sort_values(["year", "month"]).copy()
    df["period"] = df.apply(lambda r: _period_label(r["year"], r["month"]), axis=1)
    # Skip rows with missing income or balance
    valid = df["income"].notna() & (df["income"] > 0) & df["balance"].notna()
    df = df[valid].copy()
    df["rate"] = df["balance"] / df["income"] * 100
    colors = [C_BALANCE_POS if v >= 0 else C_BALANCE_NEG for v in df["rate"]]
    fig = go.Figure(go.Bar(
        x=df["period"], y=df["rate"], marker_color=colors,
        text=[f"{v:.1f}%" for v in df["rate"]],
        textposition="outside",
        textfont=dict(size=9),
        hovertemplate="%{x}: %{y:.1f}%<extra></extra>",
    ))
    fig.add_hline(y=0, line_color=C_NEUTRAL, line_dash="dash")
    _apply_base(fig, "שיעור חיסכון חודשי")
    max_abs = df["rate"].abs().max() * 1.25 if not df.empty else 50
    fig.update_layout(
        yaxis_title="שיעור חיסכון (%)",
        yaxis=dict(range=[-max_abs, max_abs]),
    )
    _fix_timeline_xaxis(fig, len(df))
    return fig


# ---------------------------------------------------------------------------
# CATEGORY CHARTS
# ---------------------------------------------------------------------------

def category_breakdown_pie(df: pd.DataFrame, year=None) -> go.Figure:
    cats = [c for c in EXPENSE_CATEGORIES if c in df.columns]
    totals = df[cats].sum()
    totals = totals[totals > 0]
    title = f"פירוט הוצאות - {year}" if year else "פירוט הוצאות (כל השנים)"
    fig = go.Figure(go.Pie(
        labels=[_label(c) for c in totals.index],
        values=totals.values,
        hole=0.42,
        marker=dict(colors=PALETTE, line=dict(color="#fff", width=1.5)),
        hovertemplate="%{label}<br>₪%{value:,.0f} | %{percent}<extra></extra>",
        textinfo="label+percent",
        textfont=dict(family="Heebo, Arial, sans-serif", size=11),
    ))
    _apply_base(fig, title)
    fig.update_layout(showlegend=False)
    return fig


def category_bar_monthly(df: pd.DataFrame, categories: list) -> go.Figure:
    """Stacked bar - total label on top of each bar."""
    df = df.sort_values(["year", "month"]).copy()
    df["period"] = df.apply(lambda r: _period_label(r["year"], r["month"]), axis=1)

    valid_cats = [c for c in categories if c in df.columns]
    totals = df[valid_cats].fillna(0).sum(axis=1)

    fig = go.Figure()
    for i, cat in enumerate(valid_cats):
        is_last = (i == len(valid_cats) - 1)
        fig.add_trace(go.Bar(
            x=df["period"], y=df[cat].fillna(0), name=_label(cat),
            marker_color=PALETTE[i % len(PALETTE)],
            hovertemplate=f"{_label(cat)}: ₪%{{y:,.0f}}<extra></extra>",
            text=[_bar_label_fmt(t) if is_last else "" for t in totals],
            textposition="outside",
            textfont=dict(size=9, color="#2c3e50"),
        ))
    _apply_base(fig, "הוצאות חודשיות לפי קטגוריה")
    fig.update_layout(
        barmode="stack",
        yaxis_title="סכום (₪)",
        yaxis=dict(range=[0, totals.max() * 1.2]),
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="left", x=0),
    )
    _fix_timeline_xaxis(fig, len(df))
    return fig


# ---------------------------------------------------------------------------
# TREND CHARTS
# ---------------------------------------------------------------------------

def trend_within_year(df: pd.DataFrame, category: str, year: int) -> go.Figure:
    """Monthly trend for a single year with bar + line overlay."""
    ydf = df[(df["year"] == year) & df[category].notna()].sort_values("month").copy()
    ydf["month_name"] = ydf["month"].map(MONTH_NAMES_HE)
    vals = ydf[category]

    fig = go.Figure()
    fig.add_trace(go.Bar(
        x=ydf["month_name"], y=vals,
        name=str(year),
        marker_color=C_PRIMARY,
        opacity=0.75,
        text=[_bar_label_fmt(v) for v in vals],
        textposition="outside",
        textfont=dict(size=10),
        hovertemplate="%{x}: ₪%{y:,.0f}<extra></extra>",
    ))
    # Annual average line
    avg = vals.mean()
    fig.add_hline(y=avg, line_dash="dash", line_color=C_NEUTRAL,
                  annotation_text=f"ממוצע: {_bar_label_fmt(avg)}",
                  annotation_position="top right")
    _apply_base(fig, f"מגמה חודשית {year}: {_label(category)}")
    fig.update_layout(yaxis_title="סכום (₪)",
                      yaxis=dict(range=[0, max(vals.max(), avg) * 1.2]))
    return fig


def trend_across_years(df: pd.DataFrame, category: str) -> go.Figure:
    """Annual totals bar chart with trend line overlay."""
    annual = df.groupby("year")[category].sum().reset_index()
    annual["year_str"] = annual["year"].astype(int).astype(str)
    vals = annual[category]

    fig = go.Figure()
    fig.add_trace(go.Bar(
        x=annual["year_str"], y=vals,
        name="סה״כ שנתי",
        marker_color=C_PRIMARY,
        opacity=0.75,
        text=[_bar_label_fmt(v) for v in vals],
        textposition="outside",
        textfont=dict(size=11, color="#2c3e50"),
        hovertemplate="%{x}: ₪%{y:,.0f}<extra></extra>",
    ))
    fig.add_trace(go.Scatter(
        x=annual["year_str"], y=vals,
        mode="lines+markers", name="קו מגמה",
        line=dict(color=C_EXPENSE, width=2, dash="dot"),
        marker=dict(size=8, color=C_EXPENSE),
    ))
    _apply_base(fig, f"מגמה שנתית: {_label(category)}")
    fig.update_layout(
        yaxis_title="סכום (₪)",
        xaxis_title="שנה",
        yaxis=dict(range=[0, vals.max() * 1.2]),
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="left", x=0),
    )
    return fig


def trend_by_category(df: pd.DataFrame, category: str) -> go.Figure:
    """Full timeline trend - all months across all years."""
    df = df.sort_values(["year", "month"]).copy()
    df = df[df[category].notna()].copy()
    df["period"] = df.apply(lambda r: _period_label(r["year"], r["month"]), axis=1)
    vals = df[category]
    fig = go.Figure()
    fig.add_trace(go.Scatter(
        x=df["period"], y=vals,
        mode="lines+markers", name=_label(category),
        line=dict(color=C_PRIMARY, width=2.5),
        marker=dict(size=5),
        hovertemplate=f"{_label(category)}: ₪%{{y:,.0f}}<extra></extra>",
    ))
    if len(df) >= 3:
        rolling = vals.rolling(3, min_periods=1).mean()
        fig.add_trace(go.Scatter(
            x=df["period"], y=rolling, name="ממוצע נע (3 חודשים)",
            mode="lines", line=dict(dash="dash", color=C_NEUTRAL, width=1.5),
        ))
    _apply_base(fig, f"ציר זמן מלא: {_label(category)}")
    fig.update_layout(
        yaxis_title="סכום (₪)",
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="left", x=0),
    )
    _fix_timeline_xaxis(fig, len(df))
    return fig


# ---------------------------------------------------------------------------
# COMPARISON CHARTS
# ---------------------------------------------------------------------------

def year_over_year(df: pd.DataFrame, metric: str, years: list) -> go.Figure:
    fig = go.Figure()
    for i, year in enumerate(sorted(years)):
        yr = int(year)
        ydf = df[df["year"] == yr].sort_values("month")
        fig.add_trace(go.Scatter(
            x=ydf["month"], y=ydf[metric].fillna(0), name=str(yr),
            mode="lines+markers",
            line=dict(color=PALETTE[i % len(PALETTE)], width=2.5),
            marker=dict(size=7),
            hovertemplate=f"{yr} - %{{x}}: ₪%{{y:,.0f}}<extra></extra>",
        ))
    _apply_base(fig, f"השוואה שנתית: {_label(metric)}")
    fig.update_layout(
        xaxis=dict(
            tickmode="array", tickvals=list(range(1, 13)),
            ticktext=[MONTH_NAMES_HE[m] for m in range(1, 13)],
        ),
        yaxis_title="סכום (₪)",
        hovermode="x unified",
        legend_title="שנה",
    )
    return fig


def multi_metric_comparison(df: pd.DataFrame, metrics: list, years: list) -> go.Figure:
    int_years = [int(y) for y in years]
    annual = df[df["year"].isin(int_years)].groupby("year")[metrics].sum().reset_index()
    fig = go.Figure()
    all_vals = []
    for i, year in enumerate(sorted(int_years)):
        row = annual[annual["year"] == year]
        if row.empty:
            continue
        vals = [row[m].values[0] for m in metrics]
        all_vals.extend(vals)
        fig.add_trace(go.Bar(
            name=str(int(year)),
            x=[_label(m) for m in metrics],
            y=vals,
            marker_color=PALETTE[i % len(PALETTE)],
            text=[_bar_label_fmt(v) for v in vals],
            textposition="outside",
            textfont=dict(size=10),
            hovertemplate=f"{year}: ₪%{{y:,.0f}}<extra></extra>",
        ))
    _apply_base(fig, "השוואת מדדים בין שנים")
    fig.update_layout(
        barmode="group",
        yaxis_title="סכום (₪)",
        yaxis=dict(range=[0, max(all_vals) * 1.2]) if all_vals else {},
        legend_title="שנה",
        xaxis=dict(tickangle=-20),
    )
    return fig


# ---------------------------------------------------------------------------
# ANOMALY CHART
# ---------------------------------------------------------------------------

def anomaly_chart(df: pd.DataFrame, metric: str) -> go.Figure:
    df = df.sort_values(["year", "month"]).copy()
    df["period"] = df.apply(lambda r: _period_label(r["year"], r["month"]), axis=1)
    df = df[df[metric].notna()].copy()
    col = df[metric]
    mean, std = col.mean(), col.std()
    is_high = col > mean + 1.5 * std
    is_low  = col < mean - 1.5 * std
    colors = [C_EXPENSE if h else C_INCOME if l else C_PRIMARY
              for h, l in zip(is_high, is_low)]
    fig = go.Figure()
    fig.add_trace(go.Bar(
        x=df["period"], y=col,
        marker_color=colors,
        text=[_bar_label_fmt(v) if (h or l) else "" for v, h, l in zip(col, is_high, is_low)],
        textposition="outside",
        textfont=dict(size=10, color="#2c3e50"),
        hovertemplate="%{x}: ₪%{y:,.0f}<extra></extra>",
    ))
    fig.add_hline(y=mean, line_dash="dash", line_color=C_NEUTRAL,
                  annotation_text=f"ממוצע: {_bar_label_fmt(mean)}", annotation_position="top right")
    fig.add_hline(y=mean + 1.5 * std, line_dash="dot", line_color=C_EXPENSE,
                  annotation_text="+1.5σ", annotation_position="top right")
    if mean - 1.5 * std > 0:
        fig.add_hline(y=mean - 1.5 * std, line_dash="dot", line_color=C_INCOME,
                      annotation_text="-1.5σ", annotation_position="bottom right")
    _apply_base(fig, f"חריגות: {_label(metric)}")
    fig.update_layout(yaxis_title="סכום (₪)")
    _fix_timeline_xaxis(fig, len(df))
    return fig


# ---------------------------------------------------------------------------
# CBS BENCHMARK COMPARISON
# ---------------------------------------------------------------------------

def cbs_comparison_bar(user_avg: dict[str, float], benchmarks: dict[str, tuple[float, str]]) -> go.Figure:
    """Grouped bar: user monthly average vs CBS national average per category."""
    cats = [c for c in benchmarks if c in user_avg and user_avg[c] is not None and user_avg[c] > 0]
    cats = sorted(cats, key=lambda c: user_avg.get(c, 0), reverse=True)

    user_vals = [user_avg[c] for c in cats]
    cbs_vals  = [benchmarks[c][0] for c in cats]
    labels    = [_label(c) for c in cats]

    fig = go.Figure()
    fig.add_trace(go.Bar(
        name="הממוצע שלי",
        x=labels, y=user_vals,
        marker_color=C_PRIMARY,
        text=[_bar_label_fmt(v) for v in user_vals],
        textposition="outside",
        textfont=dict(size=10),
        hovertemplate="%{x}<br>הממוצע שלי: ₪%{y:,.0f}<extra></extra>",
    ))
    fig.add_trace(go.Bar(
        name="ממוצע לאומי (הלמ\"ס)",
        x=labels, y=cbs_vals,
        marker_color=C_NEUTRAL,
        text=[_bar_label_fmt(v) for v in cbs_vals],
        textposition="outside",
        textfont=dict(size=10),
        hovertemplate="%{x}<br>ממוצע לאומי: ₪%{y:,.0f}<extra></extra>",
    ))
    _apply_base(fig, "השוואה לממוצע הלאומי לפי קטגוריה")
    fig.update_layout(
        barmode="group",
        yaxis_title="ממוצע חודשי (₪)",
        xaxis=dict(tickangle=-30),
        yaxis=dict(range=[0, max(max(user_vals), max(cbs_vals)) * 1.2]),
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="left", x=0),
    )
    return fig


def cbs_delta_bar(user_avg: dict[str, float], benchmarks: dict[str, tuple[float, str]]) -> go.Figure:
    """Bar showing % above/below CBS national average per category."""
    cats = [c for c in benchmarks if c in user_avg and user_avg[c] is not None and user_avg[c] > 0]
    deltas = {c: (user_avg[c] - benchmarks[c][0]) / benchmarks[c][0] * 100 for c in cats}
    cats = sorted(cats, key=lambda c: deltas[c], reverse=True)

    vals   = [deltas[c] for c in cats]
    labels = [_label(c) for c in cats]
    colors = [C_EXPENSE if v > 0 else C_INCOME for v in vals]

    fig = go.Figure(go.Bar(
        x=labels, y=vals,
        marker_color=colors,
        text=[f"{v:+.1f}%" for v in vals],
        textposition="outside",
        textfont=dict(size=10),
        hovertemplate="%{x}: %{y:+.1f}% מהממוצע הלאומי<extra></extra>",
    ))
    fig.add_hline(y=0, line_color=C_NEUTRAL, line_dash="dash")
    _apply_base(fig, "סטייה מהממוצע הלאומי (%) לפי קטגוריה")
    fig.update_layout(
        yaxis_title="סטייה מהממוצע (%)",
        xaxis=dict(tickangle=-30),
    )
    return fig

