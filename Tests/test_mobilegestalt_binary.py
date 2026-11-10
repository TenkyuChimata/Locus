"""Synthetic pointer/table tests plus opt-in, read-only exact-artifact regressions.

LOCUS_MG_BINARY selects the external artifact. No binary or private plist is
copied into the repository. Tests never authorize a runtime schema.
"""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Scripts/verify-mobilegestalt-24B119.py"
spec = importlib.util.spec_from_file_location("binary_review", SCRIPT)
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)
EVIDENCE = json.loads(review.MANIFEST.read_text())


class SyntheticImage:
    def __init__(self, chunks):
        self.chunks = chunks

    def read(self, address, size):
        matches = [data[address - start:address - start + size] for start, data in self.chunks
                   if start <= address and address + size <= start + len(data)]
        review.require(size > 0 and len(matches) == 1, "Synthetic address out of bounds")
        return matches[0]

    def word(self, address):
        return struct.unpack("<I", self.read(address, 4))[0]

    def cstring(self, address):
        data = self.read(address, 23)
        review.require(data[-1] == 0, "Missing cstring terminator")
        return data[:-1].decode("ascii")


class PointerAndTableTests(unittest.TestCase):
    def test_v5_uses_34_bits_and_restores_high8(self):
        self.assertEqual(review.decode_v5(0x001000002FF3167D, 0x180000000), 0x1AFF3167D)
        self.assertEqual(review.decode_v5((1 << 33) | 0x123, 0x180000000), 0x380000123)
        self.assertEqual(review.decode_v5((0xAB << 34) | 0x123, 0x180000000), 0xAB00000180000123)

    def test_unknown_auth_reserved_null_are_rejected(self):
        for raw in (0, 1 << 63, (1 << 42) | 1):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                review.decode_v5(raw, 0x180000000)
        # Recovering an auth target is explicitly separate from authentication.
        self.assertEqual(review.decode_v5((1 << 63) | (0xCAFE << 34) | 0x123,
                                         0x180000000, authenticated=True), 0x180000123)

    def fixture(self):
        text = b"A" * 22 + b"\0" + b"B" * 22 + b"\0"
        records = bytearray(128)
        for i, slot in enumerate((383, 694)):
            struct.pack_into("<Q", records, i * 64, (1 << 52) | (0x100 + i * 23))
            records[i * 64 + 0x38] = 0x19 if i == 0 else 0x1C
            struct.pack_into("<hI", records, i * 64 + 0x3A, slot, 11)
        return text, records

    def test_complete_records_and_slot_ownership(self):
        text, records = self.fixture()
        image = SyntheticImage([(0x180000100, text), (0x2000, records)])
        found, _, owners = review.scan_table(image, 0x2000, 2, 0x180000000)
        self.assertEqual([r["slot"] for r in found], [383, 694])
        self.assertEqual(set(owners), {383, 694})
        self.assertEqual(found[1]["flags"], 0x1C)

    def test_duplicate_conflict_signed_and_out_of_bounds_indices(self):
        for mutation in ("duplicate", "conflict", "negative", "too-large", "encoded-auth", "truncated"):
            text, records = self.fixture()
            if mutation == "duplicate":
                records[64:128] = records[:64]
            elif mutation == "conflict":
                struct.pack_into("<h", records, 64 + 0x3A, 383)
            elif mutation == "negative":
                struct.pack_into("<h", records, 0x3A, -2)
            elif mutation == "too-large":
                struct.pack_into("<h", records, 0x3A, 720)
            elif mutation == "encoded-auth":
                records[7] |= 0x80
            else:
                records = records[:-1]
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                review.scan_table(SyntheticImage([(0x180000100, text), (0x2000, records)]),
                                  0x2000, 2, 0x180000000)

    def test_validation_survives_python_optimization(self):
        code = ("import runpy; m=runpy.run_path(%r); m['require'](False, 'gate retained')" % str(SCRIPT))
        result = subprocess.run([sys.executable, "-O", "-c", code], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("gate retained", result.stderr)

    def test_malformed_macho_rejected(self):
        for raw in (b"", bytes(32), struct.pack("<8I", 0xFEEDFACF, 0x100000C, 2, 6, 1, 8, 0, 0) + bytes(8)):
            with self.assertRaises(ValueError):
                review.MachO(raw)


@unittest.skipUnless(os.environ.get("LOCUS_MG_BINARY"), "External exact binary not supplied (LOCUS_MG_BINARY)")
class ExactArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw = Path(os.environ["LOCUS_MG_BINARY"]).read_bytes()
        cls.image = review.MachO(cls.raw)

    def test_exact_binary_and_all_perfect_hash_entries(self):
        result = review.verify(self.image, EVIDENCE)
        self.assertEqual(result["offline_binary_mapping"], "PASS")
        self.assertEqual(result["safe_mutation_authorization"], "NO-GO")
        self.assertEqual(result["occupied_slots"], 716)

    def check_mutation(self, address, replacement, message):
        # Change bytes only in memory. Recompute the test's outer digest to
        # exercise semantic checks independently of the exact-file hash gate.
        section = next(s for s in self.image.sections if s[2] <= address < s[2] + s[3])
        offset = section[4] + address - section[2]
        changed = bytearray(self.raw)
        changed[offset:offset + len(replacement)] = replacement
        evidence = copy.deepcopy(EVIDENCE)
        evidence["sha256"] = hashlib.sha256(changed).hexdigest()
        with self.assertRaisesRegex(ValueError, message):
            review.verify(review.MachO(changed), evidence)

    def test_off_by_one_historical_and_wrong_slot(self):
        for entry in EVIDENCE["questions"]:
            address = int(entry["descriptor_va"], 16)
            for slot in (entry["slot"] - 1, 720, -1):
                with self.subTest(key=entry["name"], slot=slot):
                    self.check_mutation(address + 0x3A, struct.pack("<h", slot), "slot|index|Mapping")

    def test_descriptor_duplicate_and_conflict(self):
        source, target = (int(e["descriptor_va"], 16) for e in EVIDENCE["questions"][:2])
        self.check_mutation(target, self.image.read(source, 64), "Duplicate")
        self.check_mutation(target + 0x3A, struct.pack("<h", 383), "Conflicting")

    def test_wrong_flags_type_and_encoded_pointer(self):
        address = int(EVIDENCE["questions"][0]["descriptor_va"], 16)
        self.check_mutation(address + 0x38, b"\x1c", "Mapping")
        self.check_mutation(address + 0x3C, struct.pack("<I", 12), "Mapping")
        self.check_mutation(address + 7, b"\x80", "auth")

    def test_cache_uuid_linkage(self):
        self.check_mutation(0x1AFF389DB, b"0", "CacheUUID constant")
        self.check_mutation(0x1E555BE10 + 24, struct.pack("<Q", 35), "CFString length")

    def test_identity_and_control_flow_rejected(self):
        for field, value, message in (("lc_uuid", "00000000-0000-4000-8000-000000000001", "LC_UUID"),
                                       ("sha256", "0" * 64, "SHA-256"), ("size", 1, "size")):
            evidence = copy.deepcopy(EVIDENCE)
            evidence[field] = value
            with self.assertRaisesRegex(ValueError, message):
                review.verify(self.image, evidence)
        self.check_mutation(0x1AFEAFD84, bytes(4), "control flow")


if __name__ == "__main__":
    unittest.main()
