#!/usr/bin/env python3
"""Opt-in real-frame test on a locked Mac; never unlocks it or disables monitors.

Requires NOCTURNE_TEST_DISPLAYS=1, the pinned engine source, an installed Nocturne
display worker, and existing Screen Recording permission. --sleep-displays tests
one-time display sleep; it changes no power preferences and restores rendering.
--baseline omits the explicit wake to reproduce the 149.2 capture failure.
Only frame counts, dimensions and brightness ranges are collected, never images.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import select
import subprocess
import tempfile
import time
import urllib.request
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', action='store_true')
parser.add_argument('--sleep-displays', action='store_true')
parser.add_argument('--raw', action='store_true', help='Capture the virtual display itself, including when a physical main display is available')
parser.add_argument('--worker', default='/Applications/Nocturne.app/Contents/MacOS/Nocturne')
args = parser.parse_args()
if platform.system() != 'Darwin' or os.environ.get('NOCTURNE_TEST_DISPLAYS') != '1':
    raise SystemExit('Set NOCTURNE_TEST_DISPLAYS=1 on the affected Mac to run this hardware test.')
source = Path(os.environ.get('NOCTURNE_ENGINE_SOURCE', ROOT / '.build/SunshinePerformanceSource')).resolve()

with tempfile.TemporaryDirectory(prefix='nocturne-native-capture-') as temporary:
    directory = Path(temporary)
    generate = directory / 'generate.cmake'
    generate.write_text(f'include("{ROOT}/scripts/cmake/NocturneMacOSVideo.cmake")\nnocturne_macos_video("{source}" "{directory}/video.m")\n')
    subprocess.run([os.environ.get('CMAKE_COMMAND', 'cmake'), '-P', str(generate)], check=True)
    includes = ['-I', str(source), '-I', str(source / 'src/platform/macos'), '-I', str(ROOT / 'Sources/StreamingEngine'), '-I', str(ROOT / 'Sources/DisplayBridge/include')]
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-fblocks', *includes, str(directory / 'video.m'), '-o', str(directory / 'video.o')], check=True)
    binary = directory / 'capture-probe'
    subprocess.run(['xcrun', 'clang++', '-std=c++20', '-fno-objc-arc', '-fblocks', *includes, str(ROOT / 'scripts/tests/stream-native-capture.mm'), str(directory / 'video.o'), '-framework', 'Foundation', '-framework', 'AVFoundation', '-framework', 'CoreGraphics', '-framework', 'CoreMedia', '-framework', 'CoreVideo', '-framework', 'IOKit', '-o', str(binary)], check=True)
    subprocess.run([str(binary), '--require-locked'], check=True)
    if args.sleep_displays:
        try:
            with urllib.request.urlopen('http://127.0.0.1:47989/serverinfo', timeout=2) as response:
                state = ET.fromstring(response.read(65536)).findtext('state')
            if state and state != 'SUNSHINE_SERVER_FREE':
                raise SystemExit('Cannot sleep displays during an active user stream.')
        except OSError:
            pass
    worker = subprocess.Popen([args.worker, '--nocturne-display-worker'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    awake = subprocess.Popen(['caffeinate', '-i', '-t', '60'])
    try:
        command = {'id': str(uuid.uuid4()), 'operation': 'apply', 'disable': False, 'size': {'width': 1920, 'height': 1080, 'frameRate': 60}}
        worker.stdin.write(json.dumps(command) + '\n'); worker.stdin.flush()
        if not select.select([worker.stdout], [], [], 12)[0]:
            raise RuntimeError('Virtual display preparation timed out')
        reply = json.loads(worker.stdout.readline())
        if reply.get('error') or not reply.get('displayID'):
            raise RuntimeError('Virtual display preparation failed')
        print('Prepared isolated virtual display without disabling physical displays', flush=True)
        if args.sleep_displays:
            subprocess.run([str(binary), '--require-locked'], check=True)
            subprocess.run(['pmset', 'displaysleepnow'], check=True)
            time.sleep(1)
        command = [str(binary), str(reply['displayID']), 'nv12', 'raw' if args.raw else 'policy']
        if not args.baseline:
            command.append('wake')
        result = subprocess.run(command, timeout=15)
    finally:
        try:
            worker.stdin.close()
            try:
                worker.wait(timeout=5)
            except subprocess.TimeoutExpired:
                worker.terminate()
                try:
                    worker.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    worker.kill(); worker.wait(timeout=3)
        finally:
            try:
                if args.sleep_displays:
                    subprocess.run(['caffeinate', '-u', '-t', '3'], check=True)
            finally:
                awake.terminate(); awake.wait(timeout=3)
    raise SystemExit(result.returncode)
