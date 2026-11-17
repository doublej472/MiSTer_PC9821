#!/usr/bin/env python3
"""check_release_hygiene.py: no machine name or private path in any tracked file.

The tracked tree must not name the machines it was developed and tested on, nor carry a
private absolute path (docs/policies.md, documentation and wording). The names themselves
must not be written into the tree either, so the list lives in an UNTRACKED file:

    .build/hygiene-names.txt     one name per line; '#' starts a comment
    (or the file named by $HYGIENE_NAMES)

Each name is matched case-insensitively as a whole word (letters, digits, '-' and '_' around
it, or a '.' followed by one of those, do not count as a boundary). Independently of the list, an absolute home path
(`/home/<user>/`, `/Users/<user>/`) is always reported.

    python3 tools/check_release_hygiene.py             # exit 0 clean, 1 on a hit, 2 SKIP
    python3 tools/check_release_hygiene.py --selftest

Without a names file the name half is skipped LOUDLY (exit 2), never reported as a pass;
the home-path half still runs and still fails on a hit.
"""
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_NAMES = os.path.join(ROOT, '.build', 'hygiene-names.txt')
HOME_RE = re.compile(r'(?<![\w.])/(?:home|Users)/[A-Za-z0-9_.-]+/')
WORD = r'[A-Za-z0-9_.-]'


def load_names(path):
    names = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.split('#', 1)[0].strip()
            if line:
                names.append(line)
    return names


def name_res(names):
    # a '.' after the name ends a sentence unless a name character follows it (host.domain)
    return [(n, re.compile(r'(?<!%s)%s(?![A-Za-z0-9_-]|\.[A-Za-z0-9])' % (WORD, re.escape(n)), re.I))
            for n in names]


def scan_text(path, text, res, hits):
    for i, line in enumerate(text.splitlines(), 1):
        for n, rx in res:
            if rx.search(line):
                hits.append('%s:%d: machine name %r' % (path, i, n))
        if HOME_RE.search(line):
            hits.append('%s:%d: private home path %r' % (path, i, HOME_RE.search(line).group(0)))


def tracked_files(root):
    out = subprocess.run(['git', '-C', root, 'ls-files', '-z'], capture_output=True, check=True).stdout
    return [p for p in out.decode('utf-8', 'replace').split('\0') if p]


def scan_tree(root, names):
    res = name_res(names)
    hits = []
    for rel in tracked_files(root):
        full = os.path.join(root, rel)
        if not os.path.isfile(full) or os.path.islink(full):
            continue
        with open(full, 'rb') as f:
            data = f.read()
        if b'\0' in data[:8192]:
            continue  # binary
        scan_text(rel, data.decode('utf-8', 'replace'), res, hits)
    return hits


def selftest():
    bad = []
    res = name_res(['box-a', 'hostb'])
    cases = [
        ('ran on box-a today', 1), ('BOX-A', 1), ('box-a.', 1), ('xbox-a', 0), ('box-ab', 0),
        ('box-a_x', 0), ('box-a.lan', 0), ('see hostb:22', 1), ('hostbx', 0), ('path /' + 'home/someone/x', 1),
        ('/' + 'Users/me/x', 1), ('the /home page', 0), ('docs/home/x', 0), ('clean line', 0),
    ]
    for text, want in cases:
        hits = []
        scan_text('t', text, res, hits)
        if len(hits) != want:
            bad.append('%r: %d hit(s), want %d' % (text, len(hits), want))
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, 'n.txt')
        with open(p, 'w') as f:
            f.write('# comment\nbox-a  # trailing\n\nhostb\n')
        if load_names(p) != ['box-a', 'hostb']:
            bad.append('load_names: %r' % load_names(p))
    print('\n'.join(bad) or 'check_release_hygiene selftest: PASS (%d cases)' % len(cases))
    return 1 if bad else 0


def main():
    if '--selftest' in sys.argv:
        return selftest()
    path = os.environ.get('HYGIENE_NAMES', DEFAULT_NAMES)
    names = load_names(path) if os.path.isfile(path) else None
    hits = scan_tree(ROOT, names or [])
    for h in hits:
        print('FAIL ' + h)
    if hits:
        print('RELEASE HYGIENE: FAIL - %d hit(s)' % len(hits))
        return 1
    if names is None:
        print('RELEASE HYGIENE: SKIP (names) - no names file at %s (set $HYGIENE_NAMES); '
              'home paths checked, clean' % os.path.relpath(path, ROOT))
        return 2
    print('RELEASE HYGIENE: PASS - %d name(s) and home paths, %d tracked files clean'
          % (len(names), len(tracked_files(ROOT))))
    return 0


if __name__ == '__main__':
    sys.exit(main())
