"""Isolated packaging tests; fake tools never build, sign or launch an app."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="voicerelay-package-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        for name in ("build-app.sh", "install-app.py"):
            shutil.copy2(REPO / "scripts" / name, self.root / "scripts" / name)
        self.built = self.root / "DerivedData/Build/Products/Release/VoiceRelay.app"
        self.built.mkdir(parents=True)
        (self.built / "new").write_text("new package")
        self.app = self.root / "dist/VoiceRelay.app"
        self.app.mkdir(parents=True)
        (self.app / "old").write_text("previous valid package")
        tools = self.root / "tools"
        tools.mkdir()
        for name, source in {
            "xcodebuild": '#!/bin/bash\nexit "${BUILD_FAIL:-0}"\n',
            "ditto": '#!/bin/bash\nif [[ "${COPY_FAIL:-0}" == 1 ]]; then mkdir -p "$2"; exit 1; fi\n/bin/cp -R "$1" "$2"\n',
            "codesign": '#!/bin/bash\nexit "${SIGN_FAIL:-0}"\n',
        }.items():
            file = tools / name
            file.write_text(source)
            file.chmod(0o700)
        self.env = dict(os.environ, PATH=str(tools) + ":" + os.environ["PATH"])
        self.env.pop("VOICERELAY_SIGNING_IDENTITY", None)

    def run_package(self, **settings):
        result = subprocess.run(["/bin/bash", str(self.root / "scripts/build-app.sh"), "release"],
                                env=dict(self.env, **settings), capture_output=True, text=True)
        self.assertFalse(list((self.root / "dist").glob(".VoiceRelay-package.*")))
        return result

    def test_success_atomically_replaces_and_removes_obsolete_files(self):
        self.assertEqual(self.run_package().returncode, 0)
        self.assertTrue((self.app / "new").is_file())
        self.assertFalse((self.app / "old").exists())
        self.assertEqual(self.run_package().returncode, 0)

    def test_failures_preserve_previous_package(self):
        for setting in ("BUILD_FAIL", "COPY_FAIL", "SIGN_FAIL"):
            with self.subTest(setting=setting):
                self.assertNotEqual(self.run_package(**{setting: "1"}).returncode, 0)
                self.assertEqual((self.app / "old").read_text(), "previous valid package")
                self.assertFalse((self.app / "new").exists())

    def test_symlink_destination_is_not_replaced_or_followed(self):
        actual = self.root / "private-original.app"
        self.app.rename(actual)
        self.app.symlink_to(actual, target_is_directory=True)
        self.assertNotEqual(self.run_package().returncode, 0)
        self.assertTrue(self.app.is_symlink())
        self.assertTrue((actual / "old").is_file())
        self.assertFalse((actual / "new").exists())


if __name__ == "__main__":
    unittest.main()
