#!/usr/bin/env python3
"""Exercise CI build orchestration without compiling Rust or booting simulators."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
FAKE_TOOL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['COMMAND_LOG'], 'a') as log:
    log.write(json.dumps([name, *args]) + '\n')
build_started = pathlib.Path(os.environ['COMMAND_LOG']).with_suffix('.build-started')
if name == 'xcodebuild' and args[0] == 'build-for-testing':
    build_started.touch()
if name == 'uname':
    print('arm64')
elif name == 'xcrun' and args[:3] == ['simctl', 'list', 'runtimes']:
    print(json.dumps({'runtimes': [{'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0', 'isAvailable': True}]}))
elif name == 'xcrun' and args[:3] == ['simctl', 'list', 'devicetypes']:
    print(json.dumps({'devicetypes': [{'identifier': name, 'name': name} for name in ['iPhone 18 Pro', 'iPad Pro 13-inch (M5)']]}))
elif name == 'xcrun' and args[:2] == ['simctl', 'create']:
    print('phone' if 'iPhone' in args[2] else 'tablet')
elif name == 'xcrun' and args[:2] == ['simctl', 'boot']:
    if os.environ.get('FAIL_BOOT_COMMAND') == args[2]:
        sys.exit(44)
    if os.environ.get('WAIT_BOOT_FOR_BUILD') == 'true':
        deadline = time.monotonic() + 2
        while not build_started.exists():
            if time.monotonic() > deadline:
                sys.exit(45)
            time.sleep(0.01)
elif name == 'xcodebuild' and '-create-xcframework' in args:
    pathlib.Path(args[args.index('-output') + 1]).mkdir(parents=True)
elif name == 'xcodebuild' and os.environ.get('FAIL_XCODE_ACTION') in args:
    sys.exit(42)
elif name == 'xcrun' and args[:2] == ['simctl', 'bootstatus'] and os.environ.get('FAIL_BOOT') == args[2]:
    sys.exit(43)
elif name == 'git' and args[0] == 'clone':
    pathlib.Path(args[-1], '.git').mkdir(parents=True)
elif name == 'git' and args[2:] == ['rev-parse', 'HEAD']:
    print('02dc9780496eeeac6d01c8bbdccb8b6fe71ef28a' if args[1].endswith('moonlight-ios') else '5d14406844143538cd8f8851d2d8a67c1fe443e5')
'''


class BuildOrchestrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'bin').mkdir()
        for name in ['bootstrap.sh', 'build-remote.sh', 'test-ios-ci.sh']:
            shutil.copy2(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        for name in ['cargo', 'rustup', 'uname', 'xcrun', 'xcodebuild']:
            tool = self.root / 'bin' / name
            tool.write_text(FAKE_TOOL)
            tool.chmod(0o755)
        self.log = self.root / 'commands.jsonl'
        self.env = dict(os.environ, PATH=str(self.root / 'bin') + os.pathsep + os.environ['PATH'],
                        COMMAND_LOG=str(self.log), GITHUB_ACTIONS='true')

    def run_script(self, name, *args, **env):
        return subprocess.run(['bash', str(self.root / 'scripts' / name), *args],
                              env=dict(self.env, **env), text=True, capture_output=True)

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_remote_builds_only_requested_platforms(self):
        for mode, targets in [('mac', ['aarch64-apple-darwin']),
                              ('ios-device', ['aarch64-apple-ios']),
                              ('ios-simulator', ['aarch64-apple-ios-sim']),
                              ('all', ['aarch64-apple-darwin', 'aarch64-apple-ios',
                                       'aarch64-apple-ios-sim', 'x86_64-apple-ios'])]:
            with self.subTest(mode=mode):
                self.log.write_text('')
                result = self.run_script('build-remote.sh', mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                commands = self.commands()
                builds = [c for c in commands if c[:2] == ['cargo', 'build']]
                self.assertEqual([c[c.index('--target') + 1] for c in builds], targets)
                self.assertTrue(all('--locked' in c and '--release' in c for c in builds))
                frameworks = [c for c in commands if c[:2] == ['xcodebuild', '-create-xcframework']]
                self.assertEqual(len(frameworks), 1)
                self.assertEqual(frameworks[0].count('-library'), 3 if mode == 'all' else 1)
                lipos = [c for c in commands if c[:2] == ['xcrun', 'lipo']]
                self.assertEqual(len(lipos), 1 if mode == 'all' else 0)

    def test_invalid_remote_mode_fails_before_building(self):
        result = self.run_script('build-remote.sh', 'typo')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Usage:', result.stderr)
        self.assertFalse(self.log.exists(), 'Invalid options must not invoke build tools')

    def test_bootstrap_scopes_transport_and_mac_runtime(self):
        for name in ['build-remote.sh', 'fetch-sunshine.sh']:
            tool = self.root / 'scripts' / name
            tool.write_text(FAKE_TOOL)
            tool.chmod(0o755)
        for name in ['git', 'ruby', 'swift']:
            tool = self.root / 'bin' / name
            tool.write_text(FAKE_TOOL)
            tool.chmod(0o755)
        for platform in ['mac', 'ios-device', 'ios-simulator', 'all']:
            with self.subTest(platform=platform):
                self.log.write_text('')
                result = self.run_script('bootstrap.sh', platform)
                self.assertEqual(result.returncode, 0, result.stderr)
                commands = self.commands()
                self.assertIn(['build-remote.sh', platform], commands)
                self.assertEqual(['fetch-sunshine.sh'] in commands, platform in ['mac', 'all'])
                self.assertIn(['ruby', 'scripts/generate-project.rb'], commands)

    def test_client_build_is_shared_and_boots_overlap_it(self):
        result = self.run_script('test-ios-ci.sh', WAIT_BOOT_FOR_BUILD='true')
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        builds = [c for c in commands if c[:2] == ['xcodebuild', 'build-for-testing']]
        self.assertEqual(len(builds), 1, 'Build the test products once for both devices')
        self.assertIn('generic/platform=iOS Simulator', builds[0])
        self.assertIn('ONLY_ACTIVE_ARCH=YES', builds[0])
        build_index = commands.index(builds[0])
        boots = [c for c in commands if c[:2] == ['xcrun', 'simctl'] and c[2] == 'boot']
        self.assertEqual(len(boots), 2)
        creates = [c for c in commands if c[:3] == ['xcrun', 'simctl', 'create']]
        self.assertEqual(len(creates), 2)
        self.assertLess(max(commands.index(c) for c in creates), min(commands.index(c) for c in boots))
        waits = [c for c in commands if c[:3] == ['xcrun', 'simctl', 'bootstatus']]
        self.assertEqual(len(waits), 2)
        self.assertTrue(all(commands.index(c) > build_index for c in waits))
        tests = [c for c in commands if c[:2] == ['xcodebuild', 'test-without-building']]
        self.assertEqual(len(tests), 2)
        for simulator, command in zip(['phone', 'tablet'], tests):
            self.assertIn('platform=iOS Simulator,id=' + simulator, command)
            self.assertIn('-only-testing:NocturneClientTests', command)
            self.assertEqual(command[command.index('-collect-test-diagnostics') + 1], 'never')
        self.assertEqual(len(set(c[c.index('-resultBundlePath') + 1] for c in tests)), 2)
        self.assert_deleted_both(commands)

    def assert_deleted_both(self, commands):
        deleted = [c[3] for c in commands if c[:3] == ['xcrun', 'simctl', 'delete']]
        self.assertCountEqual(deleted, ['phone', 'tablet'])

    def test_build_failure_cleans_up_both_devices(self):
        result = self.run_script('test-ios-ci.sh', FAIL_XCODE_ACTION='build-for-testing')
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assert_deleted_both(self.commands())
        self.assertFalse(any(c[:2] == ['xcodebuild', 'test-without-building'] for c in self.commands()))

    def test_test_failure_cleans_up_both_devices(self):
        result = self.run_script('test-ios-ci.sh', FAIL_XCODE_ACTION='test-without-building')
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assert_deleted_both(self.commands())

    def test_boot_failure_cleans_up_both_devices(self):
        result = self.run_script('test-ios-ci.sh', FAIL_BOOT='phone')
        self.assertNotEqual(result.returncode, 0)
        self.assert_deleted_both(self.commands())

    def test_background_boot_command_failure_is_reported(self):
        result = self.run_script('test-ios-ci.sh', FAIL_BOOT_COMMAND='phone')
        self.assertEqual(result.returncode, 44, result.stderr)
        self.assert_deleted_both(self.commands())

    def test_local_simulators_are_protected(self):
        result = self.run_script('test-ios-ci.sh', GITHUB_ACTIONS='false')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())


if __name__ == '__main__':
    unittest.main()
