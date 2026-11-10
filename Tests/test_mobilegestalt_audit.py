"""Synthetic parser/privacy/difference regressions; no real device fixtures."""
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import unittest

spec = importlib.util.spec_from_file_location(
    "audit", Path(__file__).resolve().parents[1] / "Scripts/audit-mobilegestalt.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class AuditTests(unittest.TestCase):
    def fixture(self, count=720):
        return {"CacheUUID": "00000000-0000-4000-8000-000000000001",
                "CacheVersion": "24B119", "CacheData": bytes(count * 9),
                "CacheExtra": {audit.SAFE_KEYS["RegionCode"]: "CH",
                               "private-identity": "DO-NOT-EXPORT",
                               "private-blob": b"DO-NOT-EXPORT"}}

    def test_binary_xml_and_no_private_values(self):
        for fmt in (plistlib.FMT_BINARY, plistlib.FMT_XML):
            raw = plistlib.dumps(self.fixture(), fmt=fmt)
            summary = audit.summarize(raw)
            self.assertEqual(summary["cache_data_length"], 6480)
            self.assertEqual(summary["structural_candidate"]["slot_count"], 720)
            self.assertEqual(summary["structural_candidate"]["validity_offset"], 5760)
            self.assertNotIn("DO-NOT-EXPORT", json.dumps(summary))
            self.assertNotIn("private-identity", json.dumps(summary))

    def test_wrong_types_are_not_corruption_claims(self):
        fixture = self.fixture()
        fixture.update(CacheUUID=b"sixteen bytes!!!", CacheVersion=123, CacheData="text")
        summary = audit.summarize(plistlib.dumps(fixture))
        self.assertEqual(summary["top_schema"]["CacheUUID"], "bytes")
        self.assertIsNone(summary["cache_uuid"])
        self.assertIsNone(summary["cache_data_length"])
        self.assertNotIn("structural_candidate", summary)

    def test_invalid_layout_and_nonboolean_historical_slot(self):
        fixture = self.fixture()
        data = bytearray(fixture["CacheData"])
        struct.pack_into("<Q", data, 0x2B5 * 8, 100)
        data[720 * 8 + 0x2B5] = 2
        fixture["CacheData"] = bytes(data)
        layout = audit.summarize(plistlib.dumps(fixture))["structural_candidate"]
        self.assertFalse(layout["canonical_validity"])
        self.assertEqual(layout["historical_slots_not_mappings"]["wapi"]["value"], 100)
        for data in (b"", b"12345678"):
            fixture["CacheData"] = data
            self.assertNotIn("structural_candidate", audit.summarize(plistlib.dumps(fixture)))
        short = audit.summarize(plistlib.dumps(self.fixture(1)))
        self.assertFalse(short["structural_candidate"]["historical_slots_not_mappings"]["wapi"]["in_bounds"])

    def test_aggregate_differences(self):
        a = self.fixture()
        b = self.fixture()
        data = bytearray(b["CacheData"])
        data[7 * 8] = 1
        data[720 * 8 + 8] = 1
        b["CacheData"] = bytes(data)
        summary = audit.compare(plistlib.dumps(a), plistlib.dumps(b))
        diff = summary["candidate_diff"]
        self.assertEqual((diff["bytes"], diff["value_slots"], diff["validity_slots"], diff["union_slots"]), (2, 1, 1, 2))
        self.assertEqual(diff["validity_transitions"], {"0->1": 1})
        self.assertNotIn("candidate_diff", audit.compare(plistlib.dumps(a), plistlib.dumps(self.fixture(1))))

    def test_truncation_and_top_level_rejected(self):
        raw = plistlib.dumps(self.fixture(), fmt=plistlib.FMT_BINARY)
        for bad in (raw[:-10], b"broken", plistlib.dumps(["unexpected"])):
            with self.assertRaises((ValueError, plistlib.InvalidFileException)):
                audit.summarize(bad)


if __name__ == "__main__":
    unittest.main()
