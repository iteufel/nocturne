#!/usr/bin/env python3
"""Replay ScreenCaptureKit startup completions without capturing a real screen."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', action='store_true')
args = parser.parse_args()
source = Path(os.environ.get('NOCTURNE_ENGINE_SOURCE', ROOT / '.build/SunshinePerformanceSource')).resolve()
with tempfile.TemporaryDirectory(prefix='nocturne-sckit-startup-') as temporary:
    directory = Path(temporary)
    capture_path = source / 'src/platform/macos/sc_capture.mm'
    if not args.baseline:
        generate = directory / 'generate.cmake'
        generate.write_text(f'''include("{ROOT}/scripts/cmake/NocturneMacOSScreenCapture.cmake")
nocturne_macos_screen_capture("{source}" "{directory}/capture.mm")
''')
        subprocess.run(['cmake', '-P', str(generate)], check=True)
        capture_path = directory / 'capture.mm'
    capture = capture_path.read_text()
    content = capture[capture.index('static SCShareableContent *copyShareableContent('):capture.index('static BOOL isUsableImageSampleBuffer(')]
    start = capture[capture.index('- (SCStream *)startConfiguredStream'):capture.index('- (dispatch_semaphore_t)captureVideo')]
    (directory / 'content.inc').write_text(content)
    (directory / 'start.inc').write_text(start)
    binary = directory / 'sckit-startup'
    subprocess.run(['clang++', '-std=c++17', '-fno-objc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                    '-Wno-unused-parameter', '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                    '-framework', 'Foundation', '-I', str(directory), '-I', str(ROOT / 'Sources/StreamingEngine'),
                    str(ROOT / 'scripts/tests/stream-sckit-startup.mm'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
