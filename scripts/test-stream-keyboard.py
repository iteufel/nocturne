#!/usr/bin/env python3
"""Replay real client/server keyboard code without posting input or changing layouts."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def block(source: str, marker: str) -> str:
    if source.count(marker) != 1:
        raise SystemExit(f"Pinned keyboard test seam changed: {marker}")
    begin = source.index(marker)
    opening = source.index("{", begin)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[begin:end]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", action="store_true")
    args = parser.parse_args()
    engine = Path(os.environ.get("NOCTURNE_ENGINE_SOURCE", ROOT / ".build/SunshinePerformanceSource"))
    build = Path(os.environ.get("NOCTURNE_ENGINE_BUILD", ROOT / ".build/SunshinePerformanceBuild"))
    lvh = build / "_deps/libvirtualhid-src"
    with tempfile.TemporaryDirectory(prefix="nocturne-keyboard-") as directory:
        work = Path(directory)
        backend = lvh / "src/platform/macos/macos_backend.cpp"
        adapter = engine / "src/platform/virtualhid_input.cpp"
        if not args.baseline:
            generation = work / "generate.cmake"
            generation.write_text(
                f'include("{ROOT}/scripts/cmake/NocturneMacOSKeyboard.cmake")\n'
                f'nocturne_macos_keyboard_backend("{lvh}" "{work}/backend.cpp")\n'
                f'nocturne_macos_keyboard_adapter("{engine}" "{work}/adapter.cpp")\n'
            )
            subprocess.run(["cmake", "-P", str(generation)], check=True)
            backend, adapter = work / "backend.cpp", work / "adapter.cpp"
        source = backend.read_text()
        helpers = source[source.index("    struct KeyCodeMap"):source.index("    inline int scroll_lines_per_detent")]
        native = helpers + "\n" + block(source, "    inline CGEventRef create_keyboard_event")
        native += "\n" + block(source, "    class MacosKeyboard") + ";\n"
        (work / "backend.inc").write_text(native)
        (work / "adapter.inc").write_text(block(adapter.read_text(), "    lvh::KeyboardEvent keyboard_event("))
        client = (ROOT / "Vendor/moonlight-ios/Limelight/Input/KeyboardSupport.m").read_text()
        (work / "client.inc").write_text(client[client.index("+ (struct KeyEvent)translateKeyEvent:"):client.rindex("@end")])
        view = (ROOT / "Vendor/moonlight-ios/Limelight/Input/StreamView.m").read_text()
        (work / "text-entry.inc").write_text(
            block(view, "- (void)onKeyboardPressed:") + "\n"
            + block(view, "- (void)sendLowLevelEvent:") + "\n"
            + block(view, "- (BOOL)textFieldShouldReturn:")
        )
        common = build / "_deps/moonlight-common-c-src/src/Limelight.h"
        (work / "protocol.inc").write_text("\n".join(
            line for line in common.read_text().splitlines()
            if line.startswith(("#define SS_KBE_FLAG_NON_NORMALIZED ", "#define MODIFIER_", "#define KEY_ACTION_"))
        ))
        subprocess.run([
            "xcrun", "clang++", "-std=c++20", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
            "-Wno-deprecated-declarations", "-Wno-unused-parameter", "-Wno-unused-function",
            "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
            "-I" + str(lvh / "src"), "-I" + str(lvh / "src/include"),
            "-I" + str(ROOT / "Sources/StreamingEngine"), "-I" + str(work),
            str(ROOT / "scripts/tests/stream-keyboard.mm"),
            str(build / "_deps/libvirtualhid-build/src/libvirtualhid.a"),
            "-framework", "Foundation", "-framework", "Carbon", "-framework", "ApplicationServices",
            "-o", str(work / "stream-keyboard"),
        ], check=True)
        return subprocess.run([str(work / "stream-keyboard")]).returncode


if __name__ == "__main__":
    raise SystemExit(main())
