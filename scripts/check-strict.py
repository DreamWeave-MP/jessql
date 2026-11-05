#!/usr/bin/env python3
"""Zero-tolerance strict release gate for every shipped JessQL JSL file.

Usage: python3 scripts/check-strict.py /path/to/jess

The native package checker resolves the complete JessQL package plan and checks
all JSL sources, tests, and benchmarks in strict mode. Unlike the former debt
regression gate, there are no exception lists or allowed diagnostics.
"""

import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE_DIRS = ("src", "tests", "bench")


def check(jess: str) -> bool:
    scripts = sorted(
        file.relative_to(ROOT).as_posix()
        for folder in SOURCE_DIRS
        for file in (ROOT / folder).rglob("*.jsl")
    )
    if not scripts:
        raise RuntimeError("no shipped JSL files found")

    missing_directive = [
        name for name in scripts
        if not (ROOT / name).read_text(encoding="utf-8").startswith("--!strict\n")
    ]
    if missing_directive:
        for name in missing_directive:
            print(f"ERROR: missing --!strict directive: {name}", file=sys.stderr)
        return False

    command = [jess, "package", "check", ".", "--format", "json"]
    try:
        completed = subprocess.run(
            command, cwd=ROOT, capture_output=True, text=True,
            timeout=180, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"Jess package checker unavailable: {exc}") from exc

    try:
        report = json.loads(completed.stdout)
        diagnostics = report["errors"]
        checked = report["files"]
    except (ValueError, TypeError, KeyError) as exc:
        raise RuntimeError(
            f"Jess package check produced an invalid report: {completed.stderr.strip()}"
        ) from exc

    if not isinstance(diagnostics, list) or not isinstance(checked, int):
        raise RuntimeError("unexpected Jess package check report shape")

    for diagnostic in diagnostics:
        print(
            f"{diagnostic.get('file', '?')}:{diagnostic.get('line', '?')}:"
            f"{diagnostic.get('column', '?')}: {diagnostic.get('message', '?')}",
            file=sys.stderr,
        )

    success = completed.returncode == 0 and checked == len(scripts) and not diagnostics
    if not success:
        print(
            f"FAIL: Jess checked {checked}/{len(scripts)} JSL files; "
            f"{len(diagnostics)} strict errors (exit {completed.returncode})",
            file=sys.stderr,
        )
        return False

    print(f"PASS: {checked} shipped JSL files, zero strict diagnostics")
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    jess = str(pathlib.Path(sys.argv[1]).resolve())
    try:
        return 0 if check(jess) else 1
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
