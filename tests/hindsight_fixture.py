"""Generate an artificial History database and verify one visit in each archive."""

import argparse
from io import BytesIO
import json
from pathlib import Path
import sqlite3
import tempfile
from zipfile import ZipFile

from openpyxl import load_workbook


VISIT_URL = "https://example.invalid/falcon-hindsight-test"
VISIT_TIME = 13370000000000000  # Chromium microseconds since 1601 UTC.


def create_profile(profile):
    profile.mkdir(parents=True)
    with sqlite3.connect(profile / "History") as db:
        db.executescript("""
            CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT,
                visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER,
                hidden INTEGER, favicon_id INTEGER);
            CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER,
                visit_time INTEGER, from_visit INTEGER, transition INTEGER);
        """)
        db.execute("INSERT INTO urls VALUES (1, ?, ?, 1, 1, ?, 0, 0)",
                   (VISIT_URL, "Synthetic CI visit", VISIT_TIME))
        db.execute("INSERT INTO visits VALUES (1, 1, ?, 0, 1)", (VISIT_TIME,))


def verify_archive(path, output_format):
    with ZipFile(path) as archive:
        assert archive.testzip() is None, "Archive failed its CRC check"
        entries = archive.namelist()
        assert len(entries) == 1 and entries[0].endswith("." + output_format), entries
        data = archive.read(entries[0])

    if output_format == "jsonl":
        records = [json.loads(line) for line in data.splitlines() if line.strip()]
        found = any(record.get("url") == VISIT_URL for record in records)
    elif output_format == "sqlite":
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "result.sqlite"
            db_path.write_bytes(data)
            db = sqlite3.connect(db_path)
            try:
                assert db.execute("PRAGMA integrity_check").fetchall() == [("ok",)]
                found = db.execute("SELECT 1 FROM timeline WHERE url = ?", (VISIT_URL,)).fetchone()
            finally:
                db.close()
    else:
        workbook = load_workbook(BytesIO(data), read_only=True)
        try:
            found = any(VISIT_URL in row for row in workbook["Timeline"].values)
        finally:
            workbook.close()
    assert found, f"Synthetic visit missing from {output_format} archive"


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    commands = cli.add_subparsers(dest="command", required=True)
    commands.add_parser("create").add_argument("profile", type=Path)
    verify = commands.add_parser("verify")
    verify.add_argument("archive", type=Path)
    verify.add_argument("format", choices=("jsonl", "sqlite", "xlsx"))
    args = cli.parse_args()
    if args.command == "create":
        create_profile(args.profile)
    else:
        verify_archive(args.archive, args.format)
