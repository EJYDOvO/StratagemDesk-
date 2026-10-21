#!/usr/bin/env python3
"""Static provenance/privacy checks for a private candidate, not public-rights clearance."""
import hashlib
import json
import pathlib
import re
import subprocess
from collections import Counter
from urllib.parse import urlparse

root = pathlib.Path(__file__).resolve().parents[1]
def git(*args):
    return subprocess.check_output(['git', '-C', str(root), *args]).decode()
def read(path):
    return json.loads((root / path).read_text())
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

files = git('ls-files').splitlines()
assert (root / 'LICENSE').read_text().startswith('MIT License\n')
assert not any(name.startswith(('ThirdParty/', 'docs/evidence/')) for name in files)
assert not any(pathlib.Path(name).suffix.lower() in ('.png', '.jpg', '.jpeg', '.gif', '.zip', '.exe', '.dll', '.pfx', '.p12') for name in files)
assert not any(pathlib.Path(name).name in ('configuration.json', 'last-run.json', '.env') for name in files)
resources = 'Sources/StratagemCore/Resources/'
art = root / 'Sources/StratagemCore/Artwork'
games = read(resources + 'builtins.json')
originals = read(resources + 'desktop-examples.json')
assert len(games) == 115 and all(e['id'].startswith('zero.') for e in games)
assert len(originals) == 8 and all(e['id'].startswith('desk.') for e in originals)
all_entries = games + originals
ids = {e['id'] for e in all_entries}
assert len(ids) == len(all_entries) == 123
assert all(not e['enabled'] and e['confirmation'] and not e['steps'] for e in all_entries)

# Verify each name and direction against the pinned raw source, not just a count.
data_source = read('Sources/StratagemCore/Artwork/game-data/sources.json')
assert data_source['revision'] == 'c6654bacff48373214e6136ecc7a1269daefaae2'
assert data_source['projectMitApplies'] is False
assert data_source['upstreamSha256'] == sha(art / 'game-data/stratagems-upstream.json')
assert data_source['catalogSha256'] == sha(root / resources / 'builtins.json')
upstream = read('Sources/StratagemCore/Artwork/game-data/stratagems-upstream.json')
assert len(upstream) == 115
for entry, raw in zip(games, upstream):
    assert entry['name'] == raw['name']
    assert entry['sequence'] == [d.lower() for d in raw['sequence']]
    assert entry['id'] == 'zero.' + re.sub('[^a-z0-9]+', '-', raw['name'].lower()).strip('-')
license_text = (art / 'game-data/StratagemZero-LICENSE.txt').read_text()
assert 'subject to sunshine conditions' in license_text and 'Copyright (a)' in license_text
assert (art / 'ORIGINAL-DESKTOP-LICENSE.txt').read_bytes() == (root / 'LICENSE').read_bytes()
for name in ('THIRD_PARTY.md', 'Sources/StratagemCore/Artwork/LICENSE.txt',
             'Sources/StratagemCore/Artwork/NOTICE.txt', 'Sources/StratagemCore/Artwork/GAME_CONTENT_NOTICE.md'):
    text = (root / name).read_text()
    assert 'MIT' in text and ('excluded' in text.lower() or '不覆盖' in text)

manifest = read('Sources/StratagemCore/Artwork/sources.json')
game_sources = read('Sources/StratagemCore/Artwork/game-icons-sources.json')
assert game_sources['revision'] == '69f5cd62ad4b815a0eeb04bab672e1731ed95aa5'
assert len(game_sources['entries']) == 115
assert {e['id'] for e in game_sources['entries']} == {e['id'] for e in games}
assert Counter(e['origin'] for e in game_sources['entries']) == {'nvigneux-svg': 109, 'helldivers-wiki-svg': 6}
assert len(manifest['entries']) == len(ids) and ids == {e['id'] for e in manifest['entries']}
index = read('Sources/StratagemCore/Artwork/index.json')
assert ids == set(index['icons'])
for entry in manifest['entries']:
    filename = entry['file']
    assert pathlib.Path(filename).name == filename
    assert index['icons'][entry['id']] == filename
    data = (art / filename).read_bytes()
    assert hashlib.sha256(data).hexdigest() == entry['sha256']
    assert not re.search(rb'<(?:script|foreignObject)\b', data, re.I)
    # Upstream Wiki SVGs contain embedded PNGs; allow those but no remote references.
    for href in re.findall(rb'(?:xlink:)?href=[\"\x27]([^\"\x27]+)', data, re.I):
        assert href.startswith((b'#', b'data:image/png;base64,'))
    if entry['id'].startswith('desk.'):
        assert entry['license'] == 'MIT' and entry['origin'] == 'original-public-edition'
        assert 'url' not in entry
        assert not re.search(rb'<image\b|url\(', data, re.I)
    else:
        assert entry['projectMitApplies'] is False and entry['license'] == 'LicenseRef-ThirdParty-Game-Content'
        assert entry in game_sources['entries']
        url = urlparse(entry['url'])
        assert url.scheme == 'https' and not url.username and not url.query
        if entry['origin'] == 'nvigneux-svg':
            assert entry['url'].startswith('https://raw.githubusercontent.com/nvigneux/Helldivers-2-Stratagems-icons-svg/69f5cd62ad4b815a0eeb04bab672e1731ed95aa5/')
        else:
            assert url.hostname == 'helldivers.wiki.gg' and url.path.startswith('/images/')

for line in git('log', '--all', '--format=%ae%n%ce').splitlines():
    assert line.endswith('@users.noreply.github.com') or line == 'noreply@github.com', 'Private email in history'
patterns = [re.compile(rb'/' + rb'Users/(?!runner(?:/|$)|Shared(?:/|$))[^\s/]+/'),
            re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----')]
scanned = 0
for line in git('rev-list', '--objects', '--all').splitlines():
    oid, _, path = line.partition(' ')
    if git('cat-file', '-t', oid).strip() != 'blob': continue
    data = subprocess.check_output(['git', '-C', str(root), 'cat-file', 'blob', oid])
    assert not any(pattern.search(data) for pattern in patterns), 'Privacy/key pattern in history: ' + path
    assert not path.startswith(('ThirdParty/', 'Sources/StratagemCore/GameIcons/', 'docs/evidence/')), 'Excluded historical file: ' + path
    scanned += 1
report = {'passed': True, 'historyBlobsChecked': scanned, 'originalCatalogEntries': len(originals),
          'gameCatalogEntries': len(games), 'originalArtworkHashesChecked': 8, 'gameArtworkHashesChecked': 115,
          'projectLicense': 'MIT for project-owned content only', 'gameContentExcludedFromProjectMit': True,
          'upstreamGameLicensingResolved': False, 'publicationApproved': False,
          'scope': 'Private-candidate static privacy, provenance and license-boundary checks. Not rights clearance; Gitleaks runs separately.'}
out = root / 'build/public-audit'; out.mkdir(parents=True, exist_ok=True)
(out / 'source-audit.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
