# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Install dependencies
pip install -r requirements.txt

# Parse all Excel files and create encrypted data file (run once)
python setup.py

# Launch the dashboard
streamlit run dashboard/app.py
```

## GitHub Deployment

**Always push to GitHub after every code change.** The local clone is at `C:/Users/GidiAbramovich/Documents/kb-clone`.

```bash
cd "C:/Users/GidiAbramovich/Documents/kb-clone"
git pull origin main
cp -r "c:/Users/GidiAbramovich/Documents/Visual Studio Code/Expenses Summary Dashboard/dashboard" "./projects/expenses dashboard/"
cp "c:/Users/GidiAbramovich/Documents/Visual Studio Code/Expenses Summary Dashboard/CLAUDE.md" "./projects/expenses dashboard/CLAUDE.md"
# Copy other changed files as needed (requirements.txt, setup.py, parser/, etc.)
git add "projects/expenses dashboard/"
git commit -m "fix/feat/update: <description>"
git push origin main
```

Repo: `https://github.com/energidi/claude-knowledge-base`
Target path: `projects/expenses dashboard/`
Never push `data/`, `Expense Files/`, `.env` (already in .gitignore).

## Architecture

Two-phase Python app: **one-time setup** parses Excel files into an encrypted cache; **Streamlit dashboard** reads from that cache at runtime.

### Data flow

```
Expense Files/*.xls(x)
  -> parser/extractor.py   (reads raw sheets, handles .xls and .xlsx)
  -> parser/normalizer.py  (maps 3 structural eras to unified schema)
  -> parser/encryptor.py   (Fernet encryption, PBKDF2 key derivation)
  -> data/expenses.enc     (encrypted JSON, never plaintext on disk)
  -> dashboard/app.py      (Streamlit, decrypts in memory at login)
```

### Three Excel eras

| Era | Years | Summary sheet | Notes |
|---|---|---|---|
| Legacy | 2013 | None | Partial year (Jul-Dec), monthly sheets only |
| Mid | 2014-2024 | `סה"כ` | Column B = `הכנסות`; salary sub-table deduped via `seen_months` set |
| Modern | 2025+ | `סיכום שנה` / `סיכום שנתי` | Header contains `חודש` or `הכנסות` |

### Unified schema (per monthly record)

`year, month, income, total_expenses, balance, loans, insurance, subscriptions, clothing, health, beauty, entertainment, education, gifts, vehicle, purchases, fuel, food, water, electricity, other_fixed, other_variable`

Category mapping: `parser/normalizer.py::LABEL_MAP` (Hebrew -> canonical field).
Display labels: `dashboard/charts.py::CATEGORY_LABELS`.

### Encryption

- `data/expenses.enc` = 16-byte random salt + Fernet ciphertext
- Key: PBKDF2-HMAC-SHA256, 480,000 iterations
- Password never stored; derived in memory only
- Wrong password raises `ValueError`

### Dashboard structure

8 tabs: ✨ תובנות, 📊 סקירה כללית, 🥧 פירוט קטגוריות, 📈 מגמות, 🔀 השוואה שנתית, ⚠️ חריגות, 🇮🇱 השוואה לאומית, 📤 ייצוא דוח

- `dashboard/app.py` - Streamlit entry; auth via `st.session_state.df`; sidebar filters (years, months, categories)
- `dashboard/charts.py` - All Plotly figure builders (pure functions, DataFrame in → Figure out)
- `dashboard/exporter.py` - PDF (reportlab) + Excel (xlsxwriter) export
- `dashboard/cbs_data.py` - CBS household benchmark data; live fetch each session with fallback to 2022 static data

### Design system (ui-ux-pro-max applied)

- **Style:** Dark Mode OLED fintech aesthetic with light main content area
- **Fonts:** `Fira Code` (numbers, data values, KPI amounts) + `Fira Sans` (all body text, labels, tabs)
  - Google Fonts import is in the CSS block at the top of `app.py`
- **Color palette:**

| Role | Hex |
|---|---|
| Primary (blue) | `#3B82F6` |
| Deep navy | `#1E40AF` |
| Success / income | `#10B981` |
| Danger / expense | `#EF4444` |
| Accent (amber) | `#F59E0B` |
| Neutral | `#94A3B8` |
| Page background | `#F8FAFC` |
| Dark text | `#0F172A` |

- **Transitions:** 180-200ms ease-out on all interactive cards and buttons
- **Charts:** color constants in `charts.py` (C_INCOME, C_EXPENSE, C_PRIMARY, etc.); PALETTE is a 20-color list starting with blue, emerald, amber
- **New chart types:** `spending_heatmap(df)` (month × year in Overview tab), `category_treemap(df, year)` (in Category tab)

### UI / UX rules

- **Language**: Full Hebrew, RTL. Never show English text in the UI.
- **Financial language**: Use גבוה/נמוך (not טוב/גרוע) for financial comparisons.
- **Tables**: Always use `_styled_df(df, text_cols, num_cols)` for every `st.dataframe` call.
  - Text columns: right-aligned, appear on the RIGHT (RTL first position)
  - Number/percent columns: centered (cells and headers)
  - Column order passed to `_styled_df`: text_cols first, then num_cols (RTL display reverses visually)
- **Section titles**: `display: block; text-align: center` - always centered.
- **Insights tab**: Filter months where `income > median * 2.5` before best/worst month calculation (loans inflate income).
- **CBS data**: Fetched live via `@st.cache_data(ttl=3600)` every session; fallback to 2022 static values on failure.

### Sidebar filter state

Session state keys: `sel_years`, `sel_months`, `sel_cats`. **Always initialize before widgets** (before the `with st.sidebar:` block) to avoid Streamlit's widget key conflict error:

```python
if "sel_years"  not in st.session_state: st.session_state["sel_years"]  = all_years
if "sel_months" not in st.session_state: st.session_state["sel_months"] = all_months
if "sel_cats"   not in st.session_state: st.session_state["sel_cats"]   = avail_cats
```

Never pass `default=` to a multiselect that also has a `key=` already in session_state.
