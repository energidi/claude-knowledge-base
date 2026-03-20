"""
Export filtered expense data to PDF or Excel.
"""

from __future__ import annotations
import io
from datetime import datetime

import pandas as pd
from reportlab.lib.pagesizes import A4
from reportlab.lib import colors
from reportlab.lib.units import cm
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.platypus import (
    SimpleDocTemplate, Table, TableStyle, Paragraph,
    Spacer, HRFlowable,
)
from reportlab.lib.enums import TA_CENTER, TA_LEFT

from dashboard.charts import CATEGORY_LABELS, EXPENSE_CATEGORIES, MONTH_NAMES_HE

MONTH_NAMES = MONTH_NAMES_HE


def _fmt(v) -> str:
    if v is None or (isinstance(v, float) and v != v):
        return "-"
    return f"₪{v:,.0f}"


def _label(field: str) -> str:
    return CATEGORY_LABELS.get(field, field.replace("_", " ").title())


def export_excel(df: pd.DataFrame, title: str = "Expenses Report") -> bytes:
    """Return Excel bytes for the given DataFrame."""
    output = io.BytesIO()
    with pd.ExcelWriter(output, engine="xlsxwriter") as writer:
        workbook = writer.book

        # Formats
        header_fmt = workbook.add_format({
            "bold": True, "bg_color": "#2c3e50", "font_color": "white",
            "border": 1, "align": "center",
        })
        money_fmt = workbook.add_format({"num_format": '₪#,##0', "border": 1})
        text_fmt = workbook.add_format({"border": 1})
        pos_fmt = workbook.add_format({
            "num_format": '₪#,##0', "border": 1,
            "font_color": "#27ae60",
        })
        neg_fmt = workbook.add_format({
            "num_format": '₪#,##0', "border": 1,
            "font_color": "#e74c3c",
        })

        # --- Monthly Detail sheet ---
        detail = df.copy()
        detail["חודש"] = detail["month"].map(MONTH_NAMES)
        cols = ["year", "חודש", "income", "total_expenses", "balance"] + [
            c for c in EXPENSE_CATEGORIES if c in detail.columns
        ]
        present = [c for c in cols if c in detail.columns]
        detail = detail.sort_values(["year", "month"])[present]
        detail.to_excel(writer, sheet_name="פירוט חודשי", index=False)

        ws = writer.sheets["פירוט חודשי"]
        col_renames = {"year": "שנה", "חודש": "חודש"}
        headers = [col_renames.get(c, _label(c)) for c in present]
        for col_idx, h in enumerate(headers):
            ws.write(0, col_idx, h, header_fmt)
            ws.set_column(col_idx, col_idx, max(12, len(h) + 2))
        for row_idx, row in enumerate(detail.itertuples(index=False), start=1):
            for col_idx, field in enumerate(present):
                val = getattr(row, field, None)
                if field in ("year", "חודש"):
                    ws.write(row_idx, col_idx, val, text_fmt)
                elif field == "balance":
                    safe = 0 if (val is None or (isinstance(val, float) and val != val)) else val
                    fmt = pos_fmt if safe >= 0 else neg_fmt
                    ws.write(row_idx, col_idx, safe, fmt)
                else:
                    safe = 0 if (val is None or (isinstance(val, float) and val != val)) else val
                    ws.write(row_idx, col_idx, safe, money_fmt)

        # --- Annual Summary sheet ---
        num_cols = ["income", "total_expenses", "balance"] + [
            c for c in EXPENSE_CATEGORIES if c in df.columns
        ]
        annual = df.groupby("year")[num_cols].sum().reset_index()
        annual.to_excel(writer, sheet_name="סיכום שנתי", index=False)

        ws2 = writer.sheets["סיכום שנתי"]
        ann_headers = ["שנה"] + [_label(c) for c in num_cols]
        for col_idx, h in enumerate(ann_headers):
            ws2.write(0, col_idx, h, header_fmt)
            ws2.set_column(col_idx, col_idx, max(12, len(h) + 2))

    output.seek(0)
    return output.read()


def export_pdf(df: pd.DataFrame, title: str = "Expenses Report") -> bytes:
    """Return PDF bytes summarizing the filtered data."""
    output = io.BytesIO()
    doc = SimpleDocTemplate(
        output, pagesize=A4,
        leftMargin=1.5 * cm, rightMargin=1.5 * cm,
        topMargin=1.5 * cm, bottomMargin=1.5 * cm,
    )
    styles = getSampleStyleSheet()
    title_style = ParagraphStyle(
        "Title", parent=styles["Title"],
        fontSize=18, alignment=TA_CENTER, spaceAfter=12,
    )
    heading_style = ParagraphStyle(
        "Heading", parent=styles["Heading2"],
        fontSize=13, spaceBefore=12, spaceAfter=6,
    )
    normal = styles["Normal"]

    story = []

    # Title
    story.append(Paragraph(title, title_style))
    story.append(Paragraph(
        f"נוצר בתאריך: {datetime.now().strftime('%Y-%m-%d %H:%M')}",
        ParagraphStyle("sub", parent=normal, alignment=TA_CENTER, textColor=colors.grey),
    ))
    story.append(Spacer(1, 0.5 * cm))
    story.append(HRFlowable(width="100%", thickness=1, color=colors.HexColor("#2c3e50")))
    story.append(Spacer(1, 0.5 * cm))

    # Key metrics
    years = sorted(df["year"].unique())
    story.append(Paragraph("נתונים מרכזיים", heading_style))
    metrics_data = [
        ["מדד", "ערך"],
        ["שנים", ", ".join(str(y) for y in years)],
        ["סה״כ חודשים", str(len(df))],
        ["סה״כ הכנסות", _fmt(df["income"].sum())],
        ["סה״כ הוצאות", _fmt(df["total_expenses"].sum())],
        ["יתרה נטו", _fmt(df["balance"].sum())],
        ["ממוצע חודשי הכנסות", _fmt(df["income"].mean())],
        ["ממוצע חודשי הוצאות", _fmt(df["total_expenses"].mean())],
        ["חודש גבוה ביותר (יתרה)", _fmt(df["balance"].max())],
        ["חודש נמוך ביותר (יתרה)", _fmt(df["balance"].min())],
    ]
    t = Table(metrics_data, colWidths=[8 * cm, 6 * cm])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#2c3e50")),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("ALIGN", (0, 0), (-1, -1), "LEFT"),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.whitesmoke, colors.white]),
        ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#bdc3c7")),
        ("FONTSIZE", (0, 0), (-1, -1), 10),
        ("PADDING", (0, 0), (-1, -1), 5),
    ]))
    story.append(t)
    story.append(Spacer(1, 0.5 * cm))

    # Annual breakdown
    story.append(Paragraph("סיכום שנתי", heading_style))
    num_cols = ["income", "total_expenses", "balance"]
    annual = df.groupby("year")[num_cols].sum().reset_index()

    ann_header = ["שנה", "הכנסות", "הוצאות", "יתרה"]
    ann_data = [ann_header]
    for _, row in annual.iterrows():
        ann_data.append([
            str(int(row["year"])),
            _fmt(row["income"]),
            _fmt(row["total_expenses"]),
            _fmt(row["balance"]),
        ])

    t2 = Table(ann_data, colWidths=[3 * cm, 5 * cm, 5 * cm, 5 * cm])
    t2.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#2c3e50")),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("ALIGN", (1, 0), (-1, -1), "RIGHT"),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.whitesmoke, colors.white]),
        ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#bdc3c7")),
        ("FONTSIZE", (0, 0), (-1, -1), 10),
        ("PADDING", (0, 0), (-1, -1), 5),
    ]))
    story.append(t2)
    story.append(Spacer(1, 0.5 * cm))

    # Category totals
    story.append(Paragraph("סיכום קטגוריות הוצאות", heading_style))
    cat_data = [["קטגוריה", "סכום", "% מהוצאות"]]
    total_exp = df["total_expenses"].sum() or 1
    for cat in EXPENSE_CATEGORIES:
        if cat in df.columns:
            val = df[cat].sum()
            if val and val > 0:
                cat_data.append([
                    _label(cat),
                    _fmt(val),
                    f"{val / total_exp * 100:.1f}%",
                ])
    t3 = Table(cat_data, colWidths=[8 * cm, 5 * cm, 5 * cm])
    t3.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#2c3e50")),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("ALIGN", (1, 0), (-1, -1), "RIGHT"),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.whitesmoke, colors.white]),
        ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#bdc3c7")),
        ("FONTSIZE", (0, 0), (-1, -1), 10),
        ("PADDING", (0, 0), (-1, -1), 5),
    ]))
    story.append(t3)

    doc.build(story)
    output.seek(0)
    return output.read()
