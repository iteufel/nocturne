#!/usr/bin/env python3
"""Check distribution signatures without starting the app or touching displays."""
import argparse
from pathlib import Path
import subprocess


def verify(app: Path, team: str) -> None:
    app = app.resolve(strict=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    macho_headers = {
        b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
        b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
        b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
        b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
    }
    binaries = set()
    for candidate in (app / "Contents").rglob("*"):
        if not candidate.is_file():
            continue
        path = candidate.resolve(strict=True)
        if not path.is_relative_to(app):
            raise SystemExit(f"Bundle file points outside the app: {candidate}")
        with path.open("rb") as source:
            if source.read(4) in macho_headers:
                binaries.add(path)
    if not binaries:
        raise SystemExit("No Mach-O binaries found in the app")
    for path in sorted(binaries):
        result = subprocess.run(
            ["codesign", "-d", "--verbose=4", str(path)],
            text=True, capture_output=True, check=True,
        )
        signature = result.stderr.splitlines()
        if f"TeamIdentifier={team}" not in signature:
            raise SystemExit(f"Signing team mismatch: {path.relative_to(app)}")
        if not any(line.startswith("Authority=Developer ID Application:") for line in signature):
            raise SystemExit(f"Missing Developer ID signature: {path.relative_to(app)}")
        if not any(line.startswith("Timestamp=") for line in signature):
            raise SystemExit(f"Missing secure timestamp: {path.relative_to(app)}")
        if path.parent == app / "Contents/MacOS" and not any("runtime" in line for line in signature):
            raise SystemExit(f"Hardened runtime is disabled: {path.relative_to(app)}")
    print(f"Verified {len(binaries)} binaries: matching Developer ID team and secure timestamps.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("team")
    args = parser.parse_args()
    verify(args.app, args.team)
