"""CI dependency and artifact-admission regressions, using only the stdlib.

This checks the deliberately small policy-bearing part of the workflow. It is
not a YAML parser or a substitute for actionlint/GitHub Actions execution.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/build.yml").read_text()
JOBS = dict(re.findall(
    r"^  ([A-Za-z_][A-Za-z0-9_-]*):[^\S\n]*\n(.*?)(?=^  [A-Za-z_][A-Za-z0-9_-]*:|\Z)",
    WORKFLOW.split("\njobs:\n", 1)[1], re.M | re.S))


class WorkflowPolicyTests(unittest.TestCase):
    def test_builds_and_native_tests_are_independent(self):
        for job in ("portable-tests", "native-tests", "build"):
            self.assertIn(job, JOBS)
            self.assertNotRegex(JOBS[job], r"(?m)^    (?:needs|if):")
        self.assertIn("sh Scripts/test-macos.sh", JOBS["native-tests"])
        self.assertIn("sh Scripts/check-ios-native.sh", JOBS["native-tests"])
        self.assertNotIn("test-macos.sh", JOBS["build"])
        self.assertIn("xcodebuild", JOBS["build"])
        self.assertIn("configuration: [Debug, Release]", JOBS["build"])
        self.assertIn("fail-fast: false", JOBS["build"])

    def test_release_requires_every_check_to_succeed(self):
        package = JOBS["package"]
        needs = re.search(r"(?m)^    needs: \[([^\]]+)\]$", package)
        self.assertIsNotNone(needs)
        required = {name.strip() for name in needs[1].split(",")}
        self.assertEqual(required, {"portable-tests", "native-tests", "build"})
        condition = re.search(r"(?m)^    if: >-\n((?:      .*\n)+)", package)
        self.assertIsNotNone(condition)
        expression = condition[1].strip()
        self.assertTrue(expression.startswith("${{") and expression.endswith("}}"))
        terms = re.split(r"\s*&&\s*", expression[3:-2].strip())
        guards = {}
        for term in terms:
            match = re.fullmatch(r"needs\.([A-Za-z_][A-Za-z0-9_-]*)\.result\s*==\s*'success'", term.strip())
            self.assertIsNotNone(match, term)
            self.assertNotIn(match[1], guards)
            guards[match[1]] = "success"
        self.assertEqual(set(guards), required)

    def test_only_validated_package_job_exposes_an_artifact(self):
        uploaders = {name for name, body in JOBS.items() if "uses: actions/upload-artifact@" in body}
        self.assertEqual(uploaders, {"package"})
        self.assertNotIn("Create unsigned IPA", JOBS["build"])
        self.assertIn("Create unsigned IPA", JOBS["package"])
        self.assertIn("-configuration Release", JOBS["package"])
        self.assertIn("CODE_SIGNING_ALLOWED=NO", JOBS["package"])
        self.assertIn("CODE_SIGNING_REQUIRED=NO", JOBS["package"])

    def test_failures_remain_failures(self):
        self.assertNotIn("continue-on-error", WORKFLOW)
        self.assertNotIn("|| true", WORKFLOW)
        native = (ROOT / "Scripts/test-macos.sh").read_text()
        self.assertIn("set -eu", native)
        self.assertIn("-Werror", native)
        self.assertNotIn("|| true", native)

    def test_sdk_check_uses_device_headers_and_compile_only_flags(self):
        script = (ROOT / "Scripts/check-ios-native.sh").read_text()
        self.assertIn("set -eu", script)
        self.assertIn("xcrun --sdk iphoneos --show-sdk-path", script)
        self.assertIn('-target arm64-apple-ios26.0 -isysroot "$sdk" -fsyntax-only', script)
        self.assertIn("-Werror", script)
        self.assertIn("-fobjc-arc -fblocks -fmodules", script)
        self.assertIn("Locus/LowLevel/*.c", script)
        self.assertIn("Locus/LowLevel/*.m Locus/CoreText/*.m Locus/Locus-Bridging-Header.h", script)
        commands = "\n".join(line for line in script.splitlines() if not line.startswith("#"))
        self.assertNotIn("-framework", commands)
        self.assertNotIn("|| true", commands)


if __name__ == "__main__":
    unittest.main()
