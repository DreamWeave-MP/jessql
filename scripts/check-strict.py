#!/usr/bin/env python3
"""Fail on new JessQL strict errors; do not hide inherited engine debt.

Usage: python3 scripts/check-strict.py /path/to/jess
The baseline is intentionally narrow and must only move downward.
"""
import json
import pathlib
import subprocess
import sys
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASELINE = {'src/engine.jsl': 453}


def check(jess, paths, allowed):
    cmd = [jess, 'check', *paths, '--package', '.', '--format', 'json']
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=False)
    try:
        report = json.loads(result.stdout)
        findings = report['errors']
    except (ValueError, KeyError, TypeError) as exc:
        raise RuntimeError(f'checker did not return valid JSON ({exc}): {result.stderr}') from exc
    counts = Counter(item['file'] for item in findings)
    failed = [(path, count, allowed.get(path, 0)) for path, count in sorted(counts.items())
              if count > allowed.get(path, 0)]
    for path, count in sorted(counts.items()):
        print(f'{path}: {count} error(s); permitted <= {allowed.get(path, 0)}')
    if failed:
        for path, count, limit in failed:
            print(f'REGRESSION: {path}: {count} > {limit}', file=sys.stderr)
        return False
    if result.returncode not in (0, 1, 2):
        print(f'Checker crashed (exit={result.returncode}): {result.stderr}', file=sys.stderr)
        return False
    print(f'PASS: {len(findings)} known strict diagnostics, no new errors')
    return True


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    jess = str(pathlib.Path(sys.argv[1]).resolve())
    src = [str(p.relative_to(ROOT)) for p in sorted((ROOT / 'src').glob('*.jsl'))]
    success = check(jess, src, BASELINE)
    # These tests are small enough to check separately, independent of the legacy suites.
    success = check(jess, ['tests/verification.jsl', 'tests/observability.jsl'], {}) and success
    return 0 if success else 1


if __name__ == '__main__':
    sys.exit(main())
