#!/usr/bin/env python3
"""Fail closed on any JessQL strict-check regression.

Usage: python3 scripts/check-strict.py /path/to/jess
Each file is checked independently under the same package plan, avoiding
excessive multi-file checker resource usage. The engine debt can only shrink.
"""
import json
import pathlib
import subprocess
import sys
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASELINE = {'src/engine.jsl': 427}


def check(jess, paths, allowed):
    findings = []
    for path in paths:
        cmd = [jess, 'check', path, '--package', '.', '--format', 'json']
        try:
            result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                                    check=False, timeout=90)
            report = json.loads(result.stdout)
            errors = report['errors']
        except (ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as exc:
            raise RuntimeError(f'checker failed for {path} ({exc})') from exc
        if result.returncode not in (0, 1, 2):
            raise RuntimeError(f'checker exited {result.returncode} for {path}: {result.stderr}')
        findings.extend(errors)
    counts = Counter(item['file'] for item in findings)
    failed = [(path, count, allowed.get(path, 0)) for path, count in sorted(counts.items())
              if count > allowed.get(path, 0)]
    for path, count in sorted(counts.items()):
        print(f'{path}: {count} error(s); permitted <= {allowed.get(path, 0)}')
    if failed:
        for path, count, limit in failed:
            print(f'REGRESSION: {path}: {count} > {limit}', file=sys.stderr)
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
    success = check(jess, ['tests/verification.jsl', 'tests/observability.jsl',
                           'tests/backup.jsl', 'tests/app-experience.jsl'], {}) and success
    return 0 if success else 1


if __name__ == '__main__':
    sys.exit(main())
