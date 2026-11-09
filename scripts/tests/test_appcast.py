import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="leaf-appcast-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        self.tools = self.root / ".build/artifacts/sparkle/Sparkle/bin"
        self.tools.mkdir(parents=True)
        contents = self.root / "dist/Leaf.app/Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "1.0.6", "SUPublicEDKey": "test-public-key"}))
        shutil.copy2(Path(__file__).resolve().parents[1] / "appcast.sh", self.root / "scripts/appcast.sh")
        self.environment = {**os.environ, "SPARKLE_PRIVATE_KEY": "test-private-key", "KEY_PATH_LOG": str(self.root / "key-path")}
        for name in ("generate_keys", "generate_appcast", "sign_update"):
            path = self.tools / name
            path.write_text(f"#!{sys.executable}\n" + '''
import os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if name == 'generate_keys':
    if '-p' in args:
        print(os.environ.get('KEY_PUBLIC', 'test-public-key'))
    else:
        assert pathlib.Path(args[args.index('-f') + 1]).read_text() == 'test-private-key'
else:
    if os.environ.get('EXPECT_KEY_FILE'):
        assert '--ed-key-file' in args, 'CI signing must avoid Keychain prompts'
        key = pathlib.Path(args[args.index('--ed-key-file') + 1])
        assert key.read_text() == 'test-private-key'
        assert key.stat().st_mode & 0o077 == 0, 'Private key file must be owner-only'
        pathlib.Path(os.environ['KEY_PATH_LOG']).write_text(str(key))
    else:
        assert args[:2] == ['--account', 'io.github.lgoyal6.findr']
    if name == 'generate_appcast':
        pathlib.Path('dist/appcast.xml').write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure sparkle:edSignature="test-signature"/></item></channel></rss>')
''')
            path.chmod(0o755)

    def test_ci_signs_and_verifies_with_a_temporary_key_file(self):
        result = subprocess.run(["bash", "scripts/appcast.sh"], cwd=self.root,
                                env={**self.environment, "EXPECT_KEY_FILE": "true"}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Path((self.root / "key-path").read_text()).exists())
        self.assertNotIn("test-private-key", result.stdout)

    def test_local_signing_keeps_using_the_existing_keychain(self):
        environment = {**self.environment, "SPARKLE_PRIVATE_KEY": ""}
        result = subprocess.run(["bash", "scripts/appcast.sh"], cwd=self.root,
                                env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_mismatched_public_key_blocks_signing(self):
        result = subprocess.run(["bash", "scripts/appcast.sh"], cwd=self.root,
                                env={**self.environment, "KEY_PUBLIC": "different-key"}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "dist/appcast.xml").exists())


if __name__ == "__main__":
    unittest.main()
