#!/usr/bin/env python3
"""Static release-boundary checks; never execute application code or user commands."""
import hashlib
import json
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
def git(*args):
    return subprocess.check_output(['git', '-C', str(root), *args]).decode()

files = git('ls-files').splitlines()
assert (root / 'LICENSE').read_text().startswith('MIT License\n')
assert not any(name.startswith(('ThirdParty/', 'docs/evidence/')) for name in files)
assert not any(pathlib.Path(name).suffix.lower() in ('.png', '.jpg', '.jpeg', '.gif', '.zip', '.exe', '.dll', '.pfx', '.p12') for name in files)
assert not any(pathlib.Path(name).name in ('configuration.json', 'last-run.json', '.env') for name in files)
catalog = json.loads((root / 'Sources/StratagemCore/Resources/builtins.json').read_text())
manifest = json.loads((root / 'Sources/StratagemCore/Artwork/sources.json').read_text())
ids = {entry['id'] for entry in catalog}
assert len(ids) == len(catalog) == 8
assert all(identity.startswith('desk.') for identity in ids)
assert ids == {entry['id'] for entry in manifest['entries']}
for entry in manifest['entries']:
    assert entry['license'] == 'MIT' and entry['origin'] == 'original-public-edition'
    assert 'url' not in entry and pathlib.Path(entry['file']).name == entry['file']
    data = (root / 'Sources/StratagemCore/Artwork' / entry['file']).read_bytes()
    assert hashlib.sha256(data).hexdigest() == entry['sha256']
    assert not re.search(rb'<(?:image|script|foreignObject)\b|(?:href|url\()', data, re.I)
for line in git('log', '--all', '--format=%ae%n%ce').splitlines():
    assert line.endswith('@users.noreply.github.com') or line == 'noreply@github.com', 'Non-private author/committer email in history'
patterns = [re.compile(rb'/' + rb'Users/(?!runner(?:/|$)|Shared(?:/|$))[^\s/]+/'),
            re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----')]
objects = git('rev-list', '--objects', '--all').splitlines()
scanned = 0
for line in objects:
    oid, _, path = line.partition(' ')
    if git('cat-file', '-t', oid).strip() != 'blob': continue
    data = subprocess.check_output(['git', '-C', str(root), 'cat-file', 'blob', oid])
    assert not any(pattern.search(data) for pattern in patterns), 'Privacy/key pattern in history: ' + path
    assert not path.startswith(('ThirdParty/', 'Sources/StratagemCore/GameIcons/', 'docs/evidence/')), 'Excluded historical file: ' + path
    scanned += 1
report = {'passed': True, 'historyBlobsChecked': scanned, 'originalCatalogEntries': len(catalog),
          'originalArtworkHashesChecked': len(manifest['entries']), 'license': 'MIT',
          'scope': 'Static privacy, artwork provenance, history email and distribution-boundary checks; Gitleaks runs separately.'}
out = root / 'build/public-audit'; out.mkdir(parents=True, exist_ok=True)
(out / 'source-audit.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
