#!/usr/bin/env python3
"""Dependency-free fixture harness; never launches simctl, Simulator, or a listener.

Copies production sources. Only the native RemoteTunnel implementation (which
requires the Rust binary) is excluded; its routing value type is copied verbatim.
The normal project tests also discover Tests/SimulatorTests.swift.
"""
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
(root / '.build').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='simulator-tests-', dir=root / '.build') as directory:
    build = Path(directory)
    kit = build / 'Sources/NocturneKit'
    host = build / 'Sources/NocturneHostKit'
    tests = build / 'Tests/SimulatorTests'
    for path in (kit, host, tests):
        path.mkdir(parents=True)
    shared = ['Protocol', 'AppStreaming', 'DesktopStreaming', 'StreamDisplaySize',
              'ChatProtocol', 'ChatVoice', 'ChatSupervisor', 'DeveloperProtocol',
              'SimulatorStreaming']
    for name in shared:
        shutil.copy2(root / f'Sources/Shared/{name}.swift', kit)
    remote = (root / 'Sources/Shared/RemoteAccess.swift').read_text()
    remote = remote.split('/// Owns native sockets;')[0].replace('import NocturneRemote\n', '')
    (kit / 'RemoteAccess.swift').write_text(remote)
    for name in ['SimulatorSessionManager', 'SimctlSimulatorBackend', 'DeveloperCommand', 'ChatAgentConfiguration', 'ServerSettings', 'DisplaySettings']:
        shutil.copy2(root / f'Sources/HostKit/{name}.swift', host)
    shutil.copy2(root / 'Tests/SimulatorTests.swift', tests)
    env = os.environ.copy()
    cache = build / 'cache'
    cache.mkdir()
    def run(args):
        subprocess.run(args, env=env, check=True, timeout=180)
    def module(name, sources, dependencies=()):
        args = ['swiftc', '-emit-library', '-emit-module', '-parse-as-library', '-enable-testing',
                '-module-name', name, '-module-cache-path', str(cache), '-I', str(build), '-L', str(build),
                '-emit-module-path', str(build / (name + '.swiftmodule')),
                '-o', str(build / ('lib' + name + '.dylib'))]
        for dependency in dependencies:
            args += ['-l' + dependency]
        run(args + [str(source) for source in sorted(sources.glob('*.swift'))])
    module('NocturneKit', kit)
    module('NocturneHostKit', host, ['NocturneKit'])
    platform = Path(subprocess.check_output(['xcrun', '--show-sdk-platform-path'], text=True).strip())
    frameworks = platform / 'Developer/Library/Frameworks'
    bundle = build / 'SimulatorFixtures.xctest/Contents'
    (bundle / 'MacOS').mkdir(parents=True)
    (bundle / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'SimulatorFixtures', 'CFBundleIdentifier': 'dev.nocturne.simulator-fixtures',
        'CFBundlePackageType': 'BNDL'}))
    run(['swiftc', '-emit-library', '-Xlinker', '-bundle', '-parse-as-library', '-module-name', 'SimulatorFixtures',
         '-module-cache-path', str(cache), '-I', str(build), '-L', str(build), '-F', str(frameworks),
         '-I', str(platform / 'Developer/usr/lib'), '-L', str(platform / 'Developer/usr/lib'),
         '-lXCTestSwiftSupport', '-Xlinker', '-rpath', '-Xlinker', str(platform / 'Developer/usr/lib'),
         '-Xlinker', '-rpath', '-Xlinker', str(frameworks), '-lNocturneKit', '-lNocturneHostKit', '-Xlinker', '-rpath', '-Xlinker', str(build),
         '-o', str(bundle / 'MacOS/SimulatorFixtures'), str(tests / 'SimulatorTests.swift')])
    run(['xcrun', 'xctest', str(bundle.parent)])
