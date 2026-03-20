"""
Encrypt and decrypt expense data using Fernet symmetric encryption.
Key is derived from a user password via PBKDF2-HMAC-SHA256.
Plaintext is never written to disk.
"""

import os
import json
import base64
import getpass

from cryptography.fernet import Fernet
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives import hashes

SALT_SIZE = 16
ITERATIONS = 480_000
DATA_FILE = os.path.join(os.path.dirname(__file__), "..", "data", "expenses.enc")


def _derive_key(password: str, salt: bytes) -> bytes:
    kdf = PBKDF2HMAC(
        algorithm=hashes.SHA256(),
        length=32,
        salt=salt,
        iterations=ITERATIONS,
    )
    return base64.urlsafe_b64encode(kdf.derive(password.encode("utf-8")))


def encrypt(records: list[dict], password: str) -> None:
    """Encrypt records and write to data/expenses.enc."""
    os.makedirs(os.path.dirname(DATA_FILE), exist_ok=True)
    salt = os.urandom(SALT_SIZE)
    key = _derive_key(password, salt)
    f = Fernet(key)
    plaintext = json.dumps(records, ensure_ascii=False).encode("utf-8")
    ciphertext = f.encrypt(plaintext)
    with open(DATA_FILE, "wb") as fp:
        fp.write(salt + ciphertext)
    print(f"[encryptor] Saved {len(records)} records -> {DATA_FILE}")


def decrypt(password: str) -> list[dict]:
    """Read data/expenses.enc and decrypt with password. Raises on wrong password."""
    if not os.path.exists(DATA_FILE):
        raise FileNotFoundError(
            f"Encrypted data file not found: {DATA_FILE}\n"
            "Run setup.py first to generate it."
        )
    with open(DATA_FILE, "rb") as fp:
        raw = fp.read()
    salt = raw[:SALT_SIZE]
    ciphertext = raw[SALT_SIZE:]
    key = _derive_key(password, salt)
    f = Fernet(key)
    try:
        plaintext = f.decrypt(ciphertext)
    except Exception:
        raise ValueError("Wrong password or corrupted data file.")
    return json.loads(plaintext.decode("utf-8"))


def prompt_password(confirm: bool = False) -> str:
    """Prompt for password in terminal."""
    pw = getpass.getpass("Enter encryption password: ")
    if confirm:
        pw2 = getpass.getpass("Confirm password: ")
        if pw != pw2:
            raise ValueError("Passwords do not match.")
    return pw
