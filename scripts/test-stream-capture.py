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
parser.add_argument('--host-only', action='store_true', help='Test the Mac capture engine without the iOS client overlay')
args = parser.parse_args()
source = Path(os.environ.get('NOCTURNE_ENGINE_SOURCE', ROOT / '.build/SunshinePerformanceSource')).resolve()

with tempfile.TemporaryDirectory(prefix='nocturne-capture-') as temporary:
    directory = Path(temporary)
    generate = directory / 'generate.cmake'
    generate.write_text(f'''include("{ROOT}/scripts/cmake/NocturneMacOSCapture.cmake")
include("{ROOT}/scripts/cmake/NocturneMacOSVideo.cmake")
include("{ROOT}/scripts/cmake/NocturneVideo.cmake")
nocturne_macos_capture("{source}" "{directory}/display.mm")
nocturne_macos_video("{source}" "{directory}/video.m")
nocturne_video("{source}" "{directory}/engine-video.cpp")
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
        method = method.replace('[av_capture nocturneStopCapture:signal]', 'av_capture->nocturneStopCapture(signal)')
        method = method.replace('std::chrono::steady_clock::now()', 'testNow')
        (directory / name).write_text(method)
    binary = directory / 'capture-test'
    subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-Wall', '-Wextra', '-Werror',
                    '-Wno-unused-parameter', '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                    '-I', str(directory), str(ROOT / 'scripts/tests/stream-capture.cpp'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

    # A ready workspace does not imply that the video backend can start. Exercise
    # the engine's real pre-probe gate before the platform's real wake call.
    engine_video = (source / 'src/video.cpp' if args.baseline else directory / 'engine-video.cpp').read_text()
    gate = re.search(r'    bool allow_encoder_probing\(\).*?(?=\n  }  // namespace)', engine_video, re.S)
    probe_entry = re.search(r'  int probe_encoders\(\) \{(.*?)(?=    auto encoder_list)', engine_video, re.S)
    wake = re.search(r'    if \(!display_device::wake_display\(display_name, 1s\)\) \{.*?\n    }', display, re.S)
    if not gate or not probe_entry or not wake:
        raise SystemExit('The pinned encoder probe/wake seam changed; review the test.')
    (directory / 'probe-gate.inc').write_text(gate.group())
    (directory / 'probe-entry.inc').write_text(probe_entry.group(1))
    (directory / 'display-wake.inc').write_text(wake.group())
    binary = directory / 'probe-wake-test'
    subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-Wall', '-Wextra', '-Werror',
                    '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(directory),
                    str(ROOT / 'scripts/tests/stream-probe-wake.cpp'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    # The overlay must retain the inactive-display guard outside macOS.
    other_binary = directory / 'probe-other-platform-test'
    subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-Wall', '-Wextra', '-Werror',
                    '-DNOCTURNE_TEST_OTHER_PLATFORM=1', '-fsanitize=address,undefined',
                    '-fno-omit-frame-pointer', '-I', str(directory),
                    str(ROOT / 'scripts/tests/stream-probe-wake.cpp'), '-o', str(other_binary)], check=True)
    subprocess.run([str(other_binary)], check=True)

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
        if args.host_only:
            raise SystemExit(0)
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
