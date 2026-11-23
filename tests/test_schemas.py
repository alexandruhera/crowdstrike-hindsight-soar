"""Validate Falcon action contracts with old and filtered trigger payloads."""

import json
from pathlib import Path
import unittest

from jsonschema import Draft7Validator


ROOT = Path(__file__).resolve().parents[1]


def validator(filename):
    return Draft7Validator(json.loads((ROOT / filename).read_text(encoding="utf-8")))


class SchemaTests(unittest.TestCase):
    def test_all_schema_documents_are_valid(self):
        for path in ROOT.glob("*.json"):
            with self.subTest(file=path.name):
                Draft7Validator.check_schema(validator(path.name).schema)

    def test_days_contract_on_trigger_and_processing(self):
        trigger = {"deviceID": "a" * 32, "selected_browser": "Google Chrome", "output_format": "jsonl"}
        processing = {
            "selected_browser": "Google Chrome", "output_format": "jsonl",
            "system_hostname": "testhost", "forensic_analysis_path": r"C:\test-run",
            "forensic_tool_path": r"C:\test-run\hindsight.exe",
        }
        for file, payload in [("trigger-input.json", trigger), ("001-hindsight-processing-input.json", processing)]:
            with self.subTest(file=file):
                schema = validator(file)
                schema.validate(payload)
                schema.validate(dict(payload, profile_history_days=7))
                for invalid in (0, -1, 1.5, "7", True, None):
                    self.assertFalse(schema.is_valid(dict(payload, profile_history_days=invalid)), invalid)


if __name__ == "__main__":
    unittest.main()
