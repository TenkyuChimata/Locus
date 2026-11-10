"""Read-only question-name correspondence; no descriptor or write authorization.

The historically documented MGCopyAnswer prefix/MD5/Base64 transformation
checks labels and cache-key pairing only, never current consumer semantics.
"""
import base64
import hashlib
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def question_key(name):
    digest = hashlib.md5(("MGCopyAnswer" + name).encode(), usedforsecurity=False).digest()
    return base64.b64encode(digest).decode().rstrip("=")


class QuestionKeyTests(unittest.TestCase):
    def test_three_cache_question_names_match_their_declared_keys(self):
        text = (ROOT / "Locus/Region/RegionCacheMapping.swift").read_text()
        for case, name in (("greenTea", "green-tea"), ("notGreenTea", "not-green-tea"), ("wapi", "wapi")):
            match = re.search(r'case \.' + case + r': return "([^"]+)"', text)
            self.assertIsNotNone(match)
            self.assertEqual(match[1], question_key(name))

    def test_region_info_and_sysconfig_observations_are_paired_separately(self):
        text = (ROOT / "Locus/Diagnostics/RuntimeDiagnosticsService.swift").read_text()
        rows = dict((title, (query, key)) for title, query, key in re.findall(
            r'\.init\(title: "([^"]+)", query: "([^"]+)", cacheKey: "([^"]+)"', text))
        info, sysconfig = question_key("RegionInfo"), question_key("RegionInfoFromSysconfig")
        self.assertNotEqual(info, sysconfig)
        self.assertEqual(rows["RegionInfo"], ("RegionInfo", info))
        self.assertEqual(rows["RegionInfoFromSysconfig (direct key)"], (sysconfig, sysconfig))
        self.assertEqual(rows["RegionInfo (direct key)"], (info, info))
        self.assertNotIn("RegionInfo legacy key", rows)
        self.assertNotIn("RegionInfo current key candidate", rows)


if __name__ == "__main__":
    unittest.main()
