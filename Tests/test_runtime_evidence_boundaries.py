"""Source/provenance admission checks complement actual C/Swift/ObjC tests.

No firmware or private device data is embedded or required by these checks.
"""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RuntimeEvidenceBoundaryTests(unittest.TestCase):
    def test_runtime_target_constants_match_reviewed_manifest(self):
        manifest = json.loads((ROOT / 'docs/evidence/mobilegestalt-24B119.json').read_text())
        source = (ROOT / 'Locus/Diagnostics/MobileGestaltEvidenceCollector.swift').read_text()
        rows = re.findall(r'\.init\(name: "([^"]+)", hash: "([^"]+)", offset: (0x[0-9A-F]+), slot: (\d+), flags: (0x[0-9A-F]+)\)', source)
        self.assertEqual(len(rows), 3)
        for row, expected in zip(rows, manifest['questions']):
            name, key, offset, slot, flags = row
            self.assertEqual((name, key, int(offset, 16), int(slot), int(flags, 16)),
                             (expected['name'], expected['hash'], int(expected['section_offset'], 16), expected['slot'], expected['flags']))
            self.assertEqual(int(expected['value_offset'], 16), int(slot) * 8)
            self.assertEqual(int(expected['validity_offset'], 16), 5760 + int(slot))
        self.assertIn(manifest['lc_uuid'], source)
        self.assertIn(manifest['cache_uuid'], source)
        self.assertIn(manifest['sha256'], source)
        self.assertIn('NOT re-executed by this collector', source)
        self.assertIn('tableOffset = 0x830, tableCount = 2323, recordSize = 64', source)

    def test_collection_is_independent_of_runtime_queries_leases_and_mutation(self):
        sources = [ROOT / 'Locus/Diagnostics/MobileGestaltEvidenceCollector.swift',
                   ROOT / 'Locus/LowLevel/MobileGestaltEvidence.m',
                   ROOT / 'Locus/LowLevel/MobileGestaltImage.m',
                   ROOT / 'Locus/LowLevel/ReadOnlyEvidenceFile.c']
        forbidden = r'\b(?:dlopen|dlsym|MGCopyAnswer|MGGetBoolAnswer|runtimeAnswers|acquireLeaseRequiringWrite|replaceCacheData|LocusReplaceFile|notify_post|pwrite|ftruncate|respring)\s*\('
        for source in sources:
            self.assertNotRegex(source.read_text(), forbidden, str(source))
        reader = sources[-1].read_text()
        self.assertNotRegex(reader, r'\b(?:O_WRONLY|O_RDWR|O_CREAT|O_TRUNC|write|unlink|rename)\b')
        view = (ROOT / 'Locus/Diagnostics/RuntimeDiagnosticsView.swift').read_text()
        self.assertNotIn('.task { service.refresh() }', view)
        self.assertIn('UIActivityViewController(activityItems: [url]', view)
        mapping = (ROOT / 'Locus/Region/RegionCacheMapping.swift').read_text()
        self.assertIn('static let reviewed: [ReviewedCacheSchema] = []', mapping)

    def test_behavioral_tests_are_wired_to_ci_scripts(self):
        portable = (ROOT / 'Scripts/test-portable.sh').read_text()
        swift = (ROOT / 'Scripts/test-swift.sh').read_text()
        native = (ROOT / 'Scripts/test-macos.sh').read_text()
        self.assertIn('Tests/ReadOnlyEvidenceFileTests.c', portable)
        self.assertIn('Locus/Diagnostics/MobileGestaltEvidenceCollector.swift', swift)
        self.assertIn('Tests/RuntimeEvidence/main.swift', swift)
        self.assertIn('Tests/MobileGestaltEvidenceTests.m', native)
        self.assertIn('Locus/LowLevel/ReadOnlyEvidenceFile.c', native)
        bridge = (ROOT / 'Locus/Locus-Bridging-Header.h').read_text()
        self.assertIn('LowLevel/MobileGestaltEvidence.h', bridge)


if __name__ == '__main__':
    unittest.main()
