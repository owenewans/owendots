#!/usr/bin/env python3
"""Bundle an already verified package medium and the static installer."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--media', type=Path, required=True)
parser.add_argument('--binary', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
project = Path(__file__).resolve().parent.parent
manifest = json.loads((args.media / 'manifest.json').read_text())
assert manifest['distribution'] == 'slackware64-current'
assert manifest['architecture'] == 'x86_64' and manifest['schema'] == 1
names = set()
for package in manifest['packages']:
    name, file = package['name'], package['file']
    assert name not in names and Path(file).name == file and file.endswith('.txz')
    names.add(name)
    assert hashlib.file_digest((args.media / 'packages' / file).open('rb'), 'sha256').hexdigest() == package['sha256'], file
for profile in ['base', 'desktop']:
    required = {s.strip() for s in (project / 'profiles' / (profile+'.txt')).read_text().splitlines()
                if s.strip() and not s.startswith('#')}
    assert required <= names, sorted(required - names)
assert not args.output.exists(), 'output already exists'
args.output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(dir=args.output.parent) as directory:
    root = Path(directory) / 'owendots'
    (root / 'bin').mkdir(parents=True)
    shutil.copy2(args.binary, root / 'bin/owendots')
    shutil.copy2(project / 'manual.txt', root / 'manual.txt')
    shutil.copy2(project / 'LICENSE', root / 'LICENSE')
    shutil.copytree(args.media, root / 'media', copy_function=shutil.copyfile)
    for p in root.rglob('*'):
        assert not p.is_symlink() and (p.is_file() or p.is_dir()), p
    subprocess.run(['tar', '--sort=name', '--mtime=@0', '--owner=0', '--group=0',
                    '--numeric-owner', '-c', '-I', 'xz -T2 -0', '-f', str(args.output.resolve()),
                    '-C', directory, 'owendots'], check=True)
digest = hashlib.file_digest(args.output.open('rb'), 'sha256').hexdigest()
args.output.with_suffix(args.output.suffix+'.sha256').write_text(f'{digest}  {args.output.name}\n')
print(digest, args.output)
