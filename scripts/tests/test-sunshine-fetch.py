#!/usr/bin/env python3
"""Exercise checksum enforcement and atomic cache publication without a network or mounted DMG."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PAYLOAD = b'official-asset-fixture'

class SunshineFetchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'bin').mkdir()
        shutil.copy2(ROOT / 'scripts/fetch-sunshine.sh', self.root / 'scripts')
        pins = (ROOT / 'scripts/sunshine-version.sh').read_text()
        digest = hashlib.sha256(PAYLOAD).hexdigest()
        pins = '\n'.join('NOCTURNE_SUNSHINE_ARM64_SHA256=' + digest if line.startswith('NOCTURNE_SUNSHINE_ARM64_SHA256=') else line for line in pins.splitlines())
        (self.root / 'scripts/sunshine-version.sh').write_text(pins)
        tool = '''#!/usr/bin/env python3
import os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
with open(os.environ['FETCH_LOG'], 'a') as log: log.write(name + ' ' + ' '.join(sys.argv[1:]) + '\\n')
if name == 'uname': print('arm64')
if name == 'curl':
    p = pathlib.Path(sys.argv[sys.argv.index('--output') + 1])
    p.write_bytes(b'wrong' if os.environ.get('FETCH_MODE') != 'good' else b'official-asset-fixture')
    if os.environ.get('FETCH_MODE') == 'interrupted': sys.exit(56)
'''
        for name in ['uname', 'curl', 'hdiutil', 'ditto']:
            p = self.root / 'bin' / name
            p.write_text(tool)
            p.chmod(0o755)
        self.log = self.root / 'commands'
        self.env = dict(os.environ, PATH=str(self.root / 'bin') + os.pathsep + os.environ['PATH'], FETCH_LOG=str(self.log))
        version = next(line.split('=', 1)[1] for line in pins.splitlines() if line.startswith('NOCTURNE_SUNSHINE_VERSION='))
        self.archive = self.root / '.build/downloads' / ('Sunshine-v' + version + '-arm64.dmg')

    def fetch(self, mode='good'):
        return subprocess.run(['bash', 'scripts/fetch-sunshine.sh'], cwd=self.root, env=dict(self.env, FETCH_MODE=mode), text=True, capture_output=True)

    def test_verified_download_is_cached_and_reused(self):
        first = self.fetch()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(self.archive.read_bytes(), PAYLOAD)
        self.assertFalse(list(self.archive.parent.glob('*.partial.*')))
        second = self.fetch('interrupted')
        self.assertEqual(second.returncode, 0, second.stderr)
        log = self.log.read_text()
        self.assertEqual(sum(line.startswith('curl ') for line in log.splitlines()), 1)
        self.assertIn('--proto =https --proto-redir =https', log)
        self.assertIn('/Sunshine-macOS-arm64.dmg', log)

    def test_wrong_checksum_never_caches_or_extracts(self):
        result = self.fetch('wrong')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checksum mismatch', result.stderr)
        self.assertFalse(self.archive.exists())
        self.assertFalse(list(self.archive.parent.glob('*.partial.*')))
        self.assertNotIn('hdiutil ', self.log.read_text())
        self.assertNotIn('ditto ', self.log.read_text())

    def test_interrupted_download_does_not_poison_cache(self):
        self.assertNotEqual(self.fetch('interrupted').returncode, 0)
        self.assertFalse(self.archive.exists())
        self.assertFalse(list(self.archive.parent.glob('*.partial.*')))
        self.assertEqual(self.fetch().returncode, 0)
        self.assertEqual(self.archive.read_bytes(), PAYLOAD)

    def test_corrupt_existing_cache_fails_before_extraction(self):
        self.archive.parent.mkdir(parents=True)
        self.archive.write_bytes(b'corrupted cache')
        result = self.fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checksum mismatch', result.stderr)
        log = self.log.read_text()
        self.assertNotIn('curl ', log)
        self.assertNotIn('hdiutil ', log)
        self.assertNotIn('ditto ', log)

if __name__ == '__main__':
    unittest.main()
