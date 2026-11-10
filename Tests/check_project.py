"""Static packaging/signing checks, separate from behavior/device tests."""
from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parents[1]
project = (root / "Locus.xcodeproj/project.pbxproj").read_text()
entitlements = plistlib.loads((root / "Locus/Locus.entitlements").read_bytes())
assert entitlements == {
    "com.apple.security.application-groups": ["group.$(PRODUCT_BUNDLE_IDENTIFIER)"]
}
assert project.count("CODE_SIGN_ENTITLEMENTS = Locus/Locus.entitlements;") == 2
assert project.count("PRODUCT_BUNDLE_IDENTIFIER = io.github.tenkyuchimata.locus;") == 2
assert re.findall(r"DEVELOPMENT_TEAM = (.*);", project) == ['""', '""']
for path in (root / "Locus").rglob("*"):
    if path.is_file() and path.suffix in {".m", ".h", ".swift", ".c"}:
        text = path.read_text()
        assert "BadQuery" not in text and "bad_query" not in text, path
        assert not re.search(r'(?:==|isEqualToString:)\s*@?"24A5390f"', text), path
assert "GNU GENERAL PUBLIC LICENSE" in (root / "LICENSE").read_text()
assert "END OF TERMS AND CONDITIONS" in (root / "LICENSE").read_text()
mit = (root / "LICENSES/Locus-original-MIT.txt").read_text()
assert "Copyright (c) 2026 GestaltEdit contributors" in mit
assert "Copyright (c) 2026 Locus contributors" in mit
assert "Permission is hereby granted" in mit
bridge = (root / "Locus/LowLevel/WorseQueryBridge.m").read_text()
assert "Copyright (C) 2026 Taj C (forcequit)" in bridge
assert "either version 3 of the License" in bridge
assert "container_query_operation_set_part_domain" not in bridge
assert "query_set_class(query, 13)" not in bridge
workflow = (root / ".github/workflows/build-ipa.yml")
if not workflow.exists():
    workflow = next((root / ".github/workflows").glob("*.yml"))
build = workflow.read_text()
assert "CODE_SIGNING_ALLOWED=NO" in build and "CODE_SIGNING_REQUIRED=NO" in build
print("PASS: static signing, source migration, license and unsigned workflow checks")
