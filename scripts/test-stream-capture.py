#!/usr/bin/env python3
"""Run production capture seams with deterministic OS boundaries; never capture a screen."""
import argparse
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', action='store_true')
args = parser.parse_args()
source = Path(os.environ.get('NOCTURNE_ENGINE_SOURCE', ROOT / '.build/SunshinePerformanceSource')).resolve()

with tempfile.TemporaryDirectory(prefix='nocturne-capture-') as temporary:
    directory = Path(temporary)
    generate = directory / 'generate.cmake'
    generate.write_text(f'''include("{ROOT}/scripts/cmake/NocturneMacOSCapture.cmake")
include("{ROOT}/scripts/cmake/NocturneMacOSVideo.cmake")
nocturne_macos_capture("{source}" "{directory}/display.mm")
nocturne_macos_video("{source}" "{directory}/video.m")
''')
    subprocess.run([os.environ.get('CMAKE_COMMAND', 'cmake'), '-P', str(generate)], check=True)
    display = (source / 'src/platform/macos/display.mm' if args.baseline else directory / 'display.mm').read_text()
    capture = re.search(r'    capture_e capture\(.*?(?=    /\*\*\n     \* @brief Allocate an image)', display, re.S)
    probe = re.search(r'    int dummy_img\(.*?(?=    /\*\*)', display, re.S)
    if not capture or not probe:
        raise SystemExit('The pinned capture seam changed; review the test.')
    # Replace just the Objective-C invocation with a C++ mock at the OS boundary.
    # The image handling, nil checks, waits and return values remain production code.
    for name, match in [('capture.inc', capture), ('probe.inc', probe)]:
        method = match.group().replace('__block ', '')
        method = method.replace('[av_capture capture:^(CMSampleBufferRef sampleBuffer) {',
                                'av_capture->capture([&](CMSampleBufferRef sampleBuffer) {')
        method = method.replace('}];', '});')
        method = method.replace('std::chrono::steady_clock::now()', 'testNow')
        (directory / name).write_text(method)
    binary = directory / 'capture-test'
    subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-Wall', '-Wextra', '-Werror',
                    '-Wno-unused-parameter', '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                    '-I', str(directory), str(ROOT / 'scripts/tests/stream-capture.cpp'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

    if platform.system() == 'Darwin':
        video = (source / 'src/platform/macos/av_video.m' if args.baseline else directory / 'video.m').read_text()
        callback = video[video.index('- (void)captureOutput:'):video.rindex('@end')]
        registration = video[video.index('    [self.videoOutputs setObject:'):video.index('    [self.session startRunning];', video.index('    [self.videoOutputs setObject:'))]
        # Only the map-registration statements, not the enclosing configuration lock.
        registration = registration[:registration.index('    }')] if '    }' in registration else registration
        (directory / 'callback.inc').write_text(callback)
        (directory / 'registration.inc').write_text(registration)
        binary = directory / 'capture-lifecycle-test'
        subprocess.run(['clang', '-x', 'objective-c', '-fno-objc-arc', '-fblocks', '-Wall', '-Wextra',
                        '-Werror', '-Wno-unused-parameter', '-fsanitize=address,undefined',
                        '-fno-omit-frame-pointer', '-framework', 'Foundation', '-I', str(directory),
                        str(ROOT / 'scripts/tests/stream-capture-lifecycle.m'), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
        connection_path = ROOT / '.build/EngineOverrides/Connection.m'
        if not connection_path.is_file():
            raise SystemExit('Run scripts/bootstrap.sh mac to generate the client lifecycle overlay.')
        connection = connection_path.read_text()
        main = re.search(r'-\(void\) main\s*\{.*?^\}', connection, re.S | re.M)
        stop = re.search(r'-\(void\)nocturneTerminateWithCompletion:.*?(?=\n-\(id\) initWithConfig:)', connection, re.S)
        if not main or not stop:
            raise SystemExit('The generated connection lifecycle seam changed; review the test.')
        (directory / 'connection-main.inc').write_text(main.group())
        (directory / 'connection-stop.inc').write_text(stop.group())
        binary = directory / 'connection-lifecycle-test'
        subprocess.run(['clang', '-x', 'objective-c', '-std=gnu11', '-fno-objc-arc', '-fblocks',
                        '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                        '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                        '-framework', 'Foundation', '-I', str(directory),
                        str(ROOT / 'scripts/tests/stream-connection-lifecycle.m'), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
    else:
        print('SKIP: Objective-C callback lifetime/queue tests require macOS Foundation.', flush=True)
