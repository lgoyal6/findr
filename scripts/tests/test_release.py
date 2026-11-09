import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="leaf-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "bin").mkdir()
        self.calls = self.root / "calls.jsonl"
        self.environment = {
            **os.environ,
            "PATH": f"{self.root / 'bin'}:{os.environ['PATH']}",
            "CALLS": str(self.calls),
        }
        source = Path(__file__).resolve().parents[1] / "release.sh"
        shutil.copy2(source, self.root / "scripts/release.sh")
        (self.root / "VERSION").write_text("1.0.6\n")
        self.executable("bin/git", '''
import os, sys
if sys.argv[1] == 'rev-parse':
    print('a' * 40)
elif os.environ.get('DIRTY'):
    print(' M VERSION')
''')
        self.executable("bin/gh", '''
import json, os, sys
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as calls:
    calls.write(json.dumps(args) + '\\n')
if args[0] == 'api':
    print(os.environ.get('REMOTE_SHA', 'a' * 40) if args[1].endswith('/main')
          else os.environ.get('LATEST', 'v1.0.5'))
elif args[:2] == ['release', 'view']:
    if 'isDraft,targetCommitish' in args:
        state = os.environ.get('RELEASE_STATE', 'missing')
        if state == 'missing':
            sys.exit(1)
        print(state + '\\t' + os.environ.get('DRAFT_TARGET', 'a' * 40))
    else:
        print('https://github.com/lgoyal6/findr/releases/tag/v1.0.6')
elif args[1] == os.environ.get('FAIL_OPERATION'):
    sys.exit(1)
''')
        for name in ("bundle", "check-bundle", "appcast"):
            self.executable(f"scripts/{name}.sh", f'''
import json, os, pathlib, sys
with open(os.environ['CALLS'], 'a') as calls:
    calls.write(json.dumps(['{name}']) + '\\n')
if os.environ.get('FAIL_OPERATION') == '{name}':
    sys.exit(1)
pathlib.Path('dist').mkdir(exist_ok=True)
pathlib.Path('dist/Leaf.dmg').write_bytes(b'test image')
pathlib.Path('dist/appcast.xml').write_text('<rss/>')
''')

    def executable(self, relative, source):
        path = self.root / relative
        path.write_text(f"#!{sys.executable}\n" + source)
        path.chmod(0o755)

    def run_release(self, *arguments, **environment):
        result = subprocess.run(
            ["bash", "scripts/release.sh", *arguments],
            cwd=self.root,
            env={**self.environment, **environment},
            capture_output=True,
            text=True,
        )
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
        operations = [call[1] if call[0] == "release" else call[0] for call in calls]
        return result, operations

    def test_new_release_is_verified_and_uploaded_before_publication(self):
        result, operations = self.run_release("--if-needed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(operations[-6:], ["bundle", "check-bundle", "appcast", "create", "edit", "view"])
        self.assertTrue((self.root / "dist/Leaf.dmg.sha256").exists())

    def test_ci_skips_an_already_published_version(self):
        result, operations = self.run_release("--if-needed", RELEASE_STATE="false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("bundle", operations)
        self.assertNotIn("edit", operations)

    def test_manual_publishing_still_rejects_an_existing_release(self):
        result, operations = self.run_release(RELEASE_STATE="false")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("bundle", operations)

    def test_retry_resumes_a_draft_for_the_same_commit(self):
        result, operations = self.run_release("--if-needed", RELEASE_STATE="true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(operations[-3:], ["upload", "edit", "view"])
        self.assertNotIn("create", operations)

    def test_retry_rejects_a_draft_for_a_different_commit(self):
        result, operations = self.run_release("--if-needed", RELEASE_STATE="true", DRAFT_TARGET="b" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("upload", operations)

    def test_failed_checks_or_uploads_never_publish(self):
        for operation in ("bundle", "check-bundle", "appcast", "upload"):
            with self.subTest(operation=operation):
                result, operations = self.run_release("--if-needed", RELEASE_STATE="true", FAIL_OPERATION=operation)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("edit", operations)

    def test_old_versions_dirty_trees_and_stale_commits_are_rejected(self):
        for environment in ({"LATEST": "v1.0.7"}, {"DIRTY": "true"}, {"REMOTE_SHA": "b" * 40}):
            with self.subTest(environment=environment):
                result, operations = self.run_release("--if-needed", **environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("bundle", operations)


if __name__ == "__main__":
    unittest.main()
