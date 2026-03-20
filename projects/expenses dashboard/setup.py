"""
Setup script - run once to parse all Excel files and create the encrypted data file.

Usage:
    python setup.py

After running successfully and verifying the dashboard works,
you can safely delete the 'Expense Files' folder.
"""

import sys
import os

sys.path.insert(0, os.path.dirname(__file__))

from parser.extractor import extract_all
from parser.normalizer import normalize
from parser.encryptor import encrypt, prompt_password


def main():
    print("=" * 60)
    print("  Expenses Dashboard - Setup")
    print("=" * 60)
    print()
    print("Step 1/3: Reading Excel files...")
    raw = extract_all()
    print(f"          Found data for years: {sorted(raw.keys())}")
    print()

    print("Step 2/3: Normalizing data...")
    records = normalize(raw)
    print(f"          Total monthly records: {len(records)}")
    years = sorted(set(r["year"] for r in records))
    print(f"          Years covered: {years}")
    print()

    print("Step 3/3: Encrypting and saving...")
    print("          Choose a strong password. You will need it every time")
    print("          you open the dashboard. It is NOT stored anywhere.")
    print()
    try:
        password = prompt_password(confirm=True)
    except ValueError as e:
        print(f"Error: {e}")
        sys.exit(1)

    encrypt(records, password)
    print()
    print("=" * 60)
    print("  DONE! Encrypted file saved to: data/expenses.enc")
    print()
    print("  Next steps:")
    print("  1. Run:  streamlit run dashboard/app.py")
    print("  2. Enter your password in the dashboard")
    print("  3. Verify all data looks correct")
    print("  4. Delete the 'Expense Files' folder if desired")
    print("=" * 60)


if __name__ == "__main__":
    main()
