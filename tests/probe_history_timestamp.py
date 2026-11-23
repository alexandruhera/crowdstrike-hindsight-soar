"""Observe History and its WAL during a real, isolated Chrome navigation."""

from datetime import datetime, timezone
import os
from pathlib import Path
import sqlite3
import tempfile

from playwright.sync_api import sync_playwright


VISIT = "https://example.invalid/timestamp-probe"


def snapshot(profile):
    values = []
    for filename in ("History", "History-wal"):
        try:
            modified = (profile / filename).stat().st_mtime
        except FileNotFoundError:
            values.append("absent")
        else:
            values.append(datetime.fromtimestamp(modified, timezone.utc).isoformat())
    return values


def probe():
    with tempfile.TemporaryDirectory() as tmp, sync_playwright() as playwright:
        user_data = Path(tmp) / "user-data"
        profile = user_data / "Default"
        options = {"channel": "chrome"}
        if executable := os.getenv("CHROME_EXECUTABLE"):
            options = {"executable_path": executable}
        context = playwright.chromium.launch_persistent_context(str(user_data), headless=True, timeout=30_000, **options)
        try:
            browser_version = context.browser.version
            page = context.pages[0]
            # Intercept HTTP(S) locally so the visit is synthetic and repeatable.
            context.route("**/*", lambda route: route.fulfill(content_type="text/html", body="Fixture"))
            before = snapshot(profile)
            page.goto(VISIT, wait_until="load", timeout=15_000)
            opened = snapshot(profile)
        finally:
            context.close()
        closed = snapshot(profile)
        with sqlite3.connect((profile / "History").as_uri() + "?mode=ro", uri=True) as db:
            assert db.execute("SELECT count(*) FROM urls WHERE url = ?", (VISIT,)).fetchone()[0] == 1
        db.close()

    lines = [f"### Chrome {browser_version} History timestamp probe", "", "| State | History UTC | History-wal UTC |",
             "| --- | --- | --- |"]
    for state, values in (("Before visit", before), ("After visit, browser open", opened),
                          ("After browser exit", closed)):
        lines.append(f"| {state} | {values[0]} | {values[1]} |")
    lines += ["", "The closed database contains the synthetic visit. Times reflect this run and Chrome version."]
    report = "\n".join(lines) + "\n"
    print(report)
    if summary := os.getenv("GITHUB_STEP_SUMMARY"):
        with open(summary, "a", encoding="utf-8") as output:
            output.write(report)


if __name__ == "__main__":
    probe()
