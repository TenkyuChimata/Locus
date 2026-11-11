"""Optional read-only regression for the reused 24B119 disassembly evidence.

No Apple binary is bundled. These checks establish static control flow only,
not device initialization, persistence or write authorization.
"""
import hashlib
import os
from pathlib import Path
import struct
import unittest


@unittest.skipUnless(os.environ.get("LOCUS_MG_BINARY"), "LOCUS_MG_BINARY is required for static firmware checks")
class RegionalBehaviorEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.image = Path(os.environ["LOCUS_MG_BINARY"]).read_bytes()
        if hashlib.sha256(cls.image).hexdigest() != "d5b2c93693db10cfb47574b4a9555c4c5affc5309b5f15101066dfd02308c9f7":
            raise AssertionError("Expected the independently identified 24B119 libMobileGestalt image")
        cls.segments = []
        offset = 32
        for _ in range(struct.unpack_from("<I", cls.image, 16)[0]):
            command, length = struct.unpack_from("<II", cls.image, offset)
            if command == 0x19:
                address, _, file_offset, size = struct.unpack_from("<QQQQ", cls.image, offset + 24)
                cls.segments.append((address, file_offset, size))
            offset += length

    def read(self, address, size):
        matches = [self.image[offset + address - base:offset + address - base + size]
                   for base, offset, length in self.segments if base <= address and address + size <= base + length]
        self.assertEqual(len(matches), 1)
        return matches[0]

    def test_success_keeps_true_pointer_and_skips_false_reload(self):
        # x28 = *(0x1e00fe000 + 0x6e0), the same true pointer used by MGGetBoolAnswer.
        self.assertEqual(self.read(0x1AFEB6DB8, 8).hex(), "5c1218909c7343f9")
        self.assertEqual(self.read(0x1AFEAFEC4, 8).hex(), "681218f0087143f9")
        # Successful expansion jumps directly to ldr x2,[x28], bypassing 6ea0/6ea4.
        branch = struct.unpack("<I", self.read(0x1AFEB6DF4, 4))[0]
        self.assertEqual(branch >> 26, 0b000101)
        self.assertEqual(0x1AFEB6DF4 + (branch & 0x3FFFFFF) * 4, 0x1AFEB6EA8)
        self.assertEqual(self.read(0x1AFEB6EA0, 12).hex(), "5c1218909c6f43f9820340f9")

    def test_rule_success_bypasses_swbhvalid_true_assignment(self):
        # Rule success targets 6d20; only the priority-input path enters 6cfc/6d14.
        self.assertEqual(self.read(0x1AFEB6CF4, 4).hex(), "79010037")
        self.assertEqual(self.read(0x1AFEB6D00, 8).hex(), "087143f9020140f9")
        self.assertEqual(self.read(0x1AFEB6D14, 4).hex(), "0bc60994")

    def test_valid_uses_full_case_sensitive_dictionary_key(self):
        # Handler x1 = 0x1e5551ff0; getter preserves x1 as the dictionary key.
        self.assertEqual(self.read(0x1AFEE67F4, 8).hex(), "41b31af021c03f91")
        self.assertEqual(self.read(0x1AFEB68FC, 4).hex(), "f40301aa")
        raw_pointer = struct.unpack("<Q", self.read(0x1E5551FF0 + 16, 8))[0]
        address = 0x180000000 + (raw_pointer & 0x3FFFFFFFF)
        self.assertEqual(self.read(address, len(b"RegionalBehaviorValid\0")), b"RegionalBehaviorValid\0")


if __name__ == "__main__":
    unittest.main()
