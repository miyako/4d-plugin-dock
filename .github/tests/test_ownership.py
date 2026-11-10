"""Actual first-party sources and entire unchanged SDK, not replacement PA_* APIs."""

import argparse
import hashlib
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE_REF = None
CASES = (
    "callback-method", "callback-fallback", "callback-empty", "callback-ref",
    "callback-noresult", "callback-handle-failure", "getter-kinds",
    "setters", "get-text", "get-mismatch", "get-failed", "handoffs",
    "arrays", "content",
)


@unittest.skipUnless(platform.system() == "Darwin", "requires Apple's native frameworks")
class OwnershipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="dock-ownership-")
        cls.addClassCleanup(cls.temp.cleanup)
        temp = Path(cls.temp.name)
        root = ROOT
        if SOURCE_REF:
            root = temp / "baseline"
            paths = subprocess.check_output(
                ["git", "ls-files", "4D Plugin API", "support", "4DPlugin-Dock.cpp",
                 "4DPlugin-Dock.h"], cwd=ROOT, text=True,
            ).splitlines()
            for name in paths:
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(subprocess.check_output(
                    ["git", "show", f"{SOURCE_REF}:{name}"], cwd=ROOT,
                ))
        sdk = root / "4D Plugin API"
        expected_sdk = "5bac571c5c4cafd280fa7f23d775458a23701287e8735be27d4a2190002f4e3f"
        if hashlib.sha256((sdk / "4DPluginAPI.c").read_bytes()).hexdigest() != expected_sdk:
            raise RuntimeError("Bundled SDK changed; re-audit engine shim contracts")
        common = ["-g", "-O1", "-fsanitize=address,undefined",
                  "-fno-omit-frame-pointer", "-Wno-deprecated-declarations",
                  "-Wno-multichar", "-Wno-deprecated",
                  "-I", str(root), "-I", str(sdk), "-I", str(sdk / "Classes")]
        cls.binary = temp / "ownership"
        commands = [
            ["clang", *common, "-Wno-int-conversion", "-c", str(sdk / "4DPluginAPI.c"),
             "-o", str(temp / "sdk.o")],
            ["clang++", *common, "-std=c++17", "-x", "objective-c++",
             str(ROOT / ".github/tests/native/ownership.mm"),
             str(sdk / "Classes/C_TEXT.cpp"), str(sdk / "Classes/ARRAY_TEXT.cpp"),
             str(sdk / "Classes/C_BLOB.cpp"), str(sdk / "Classes/C_LONGINT.cpp"),
             str(sdk / "Classes/C_REAL.cpp"),
             "-x", "none", str(temp / "sdk.o"),
             "-framework", "Cocoa", "-framework", "CoreGraphics",
             "-framework", "ImageIO", "-framework", "CoreServices",
             "-o", str(cls.binary)],
        ]
        for command in commands:
            result = subprocess.run(command, cwd=root, text=True, capture_output=True)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)

    def test_native_ownership(self):
        for case in CASES:
            for empty in ("allocated", "null"):
                with self.subTest(case=case, empty=empty):
                    result = subprocess.run(
                        [str(self.binary), case, empty], text=True, capture_output=True,
                        env={**os.environ, "ASAN_OPTIONS": "detect_leaks=0",
                             "UBSAN_OPTIONS": "halt_on_error=1"},
                    )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("strings=0 handles=0 refs=0", result.stdout)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-ref")
    args, rest = parser.parse_known_args()
    SOURCE_REF = args.source_ref
    unittest.main(argv=[__file__, *rest])
