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

After every code change, push to GitHub automatically:

```bash
# Clone target (already exists at this path)
# C:/Users/GidiAbramovich/Documents/kb-clone

cd "C:/Users/GidiAbramovich/Documents/kb-clone"
git pull origin main
cp -r "c:/Users/GidiAbramovich/Documents/Visual Studio Code/Expenses Summary Dashboard/dashboard" "./projects/expenses dashboard/"
cp "c:/Users/GidiAbramovich/Documents/Visual Studio Code/Expenses Summary Dashboard/CLAUDE.md" "./projects/expenses dashboard/CLAUDE.md"
# Add other changed files as needed (requirements.txt, setup.py, parser/, etc.)
git add "projects/expenses dashboard/"
git commit -m "update: <description>"
git push origin main
```

Repo: `https://github.com/energidi/claude-knowledge-base`
Target path: `projects/expenses dashboard/`
Never push `data/`, `Expense Files/`, `.env` (already in .gitignore).

## Architecture

This is a two-phase Python app: a **one-time setup** that parses Excel files into an encrypted cache, and a **Streamlit dashboard** that reads from that cache.

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

The expense files span 2013-2026 with different sheet structures:

| Era | Years | Summary sheet | Notes |
|---|---|---|---|
| Legacy | 2013 | None | Partial year (Jul-Dec), parsed from monthly sheets only |
| Mid | 2014-2024 | `סה"כ` | Header row where column B = `הכנסות`; salary sub-table below also contains month names - deduplicated by `seen_months` set |
| Modern | 2025+ | `סיכום שנה` / `סיכום שנתי` | Header row contains `חודש` or `הכנסות` |

### Unified schema (per monthly record)

`year, month, income, total_expenses, balance, loans, insurance, subscriptions, clothing, health, beauty, entertainment, education, gifts, vehicle, purchases, fuel, food, water, electricity, other_fixed, other_variable`

Category mapping lives in `parser/normalizer.py::LABEL_MAP` (Hebrew label -> canonical field). Display labels live in `dashboard/charts.py::CATEGORY_LABELS`.

### Encryption

- `data/expenses.enc` = 16-byte random salt + Fernet ciphertext
- Key derived via PBKDF2-HMAC-SHA256 (480,000 iterations)
- Password never stored; derived in memory only at dashboard login
- Wrong password raises `ValueError` (Fernet token validation)

### Dashboard structure

- `dashboard/app.py` - Streamlit entry point; handles auth via `st.session_state.df`; 6 tabs: Overview, Category Breakdown, Trends, Year-over-Year, Anomalies, Export
- `dashboard/charts.py` - All Plotly figure builders; pure functions, accept DataFrame return Figure
- `dashboard/exporter.py` - PDF (reportlab) and Excel (xlsxwriter) export; called directly from download buttons in app.py
