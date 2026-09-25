#!/usr/bin/env python3
"""Prepare an explicit Slackware-current package set for the installer medium."""
import argparse
import concurrent.futures
import hashlib
import json
import pathlib
import re
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--mirror', default='https://slackware.osuosl.org/slackware64-current')
parser.add_argument('--profile', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent / 'profiles/base.txt')
parser.add_argument('--native-manifest', type=pathlib.Path)
parser.add_argument('--role', choices=['base', 'desktop'], default='base')
args = parser.parse_args()
root = args.output.resolve()
root.mkdir(parents=True, exist_ok=True)
packages = root / 'packages'
packages.mkdir(exist_ok=True)
metadata = root / 'metadata'
metadata.mkdir(exist_ok=True)
base = args.mirror.rstrip('/')


def run(*command, **kw):
    return subprocess.run(command, check=True, **kw)


def download(url, path):
    run('curl', '-fsSL', '--proto', '=https', '--proto-redir', '=https', '--retry', '3', '--connect-timeout', '20', url, '-o', str(path))


for filename in ['GPG-KEY', 'CHECKSUMS.md5', 'CHECKSUMS.md5.asc', 'PACKAGES.TXT']:
    download(base + '/' + filename, metadata / filename)
keyhome = metadata / 'gnupg'
keyhome.mkdir(mode=0o700, exist_ok=True)
listing = run('gpg', '--homedir', str(keyhome), '--batch', '--with-colons', '--show-keys', str(metadata / 'GPG-KEY'), capture_output=True, text=True).stdout
primary = False
keys = []
for line in listing.splitlines():
    if line.startswith('pub:'):
        primary = True
    elif primary and line.startswith('fpr:'):
        keys.append(line.split(':')[9])
        primary = False
if keys != ['EC5649DA401E22ABFA6736EF6A4463C040102233']:
    raise SystemExit('unexpected Slackware signing key')
run('gpg', '--batch', '--yes', '--dearmor', '--output', str(metadata / 'slackware.gpg'), str(metadata / 'GPG-KEY'))
run('gpgv', '--keyring', str(metadata / 'slackware.gpg'), str(metadata / 'CHECKSUMS.md5.asc'), str(metadata / 'CHECKSUMS.md5'))
checksums = {}
for line in (metadata / 'CHECKSUMS.md5').read_text().splitlines():
    match = re.match(r'^([a-f0-9]{32})\s+\*?(?:\./)?(.+)$', line)
    if match:
        checksums[match[2]] = match[1]
if hashlib.md5((metadata / 'PACKAGES.TXT').read_bytes()).hexdigest() != checksums['PACKAGES.TXT']:
    raise SystemExit('index checksum mismatch; current changed, retry')
catalog = {}
for record in (metadata / 'PACKAGES.TXT').read_text().split('PACKAGE NAME:  ')[1:]:
    filename = record.splitlines()[0]
    location = re.search(r'PACKAGE LOCATION:  (.+)', record)[1].removeprefix('./')
    catalog[filename.rsplit('-', 3)[0]] = location + '/' + filename
names = [line.strip() for line in args.profile.read_text().splitlines() if line.strip() and not line.startswith('#')]
if len(names) != len(set(names)) or set(names) - catalog.keys():
    raise SystemExit('duplicate or unknown profile packages: ' + str(sorted(set(names) - catalog.keys())))


def fetch(name):
    path = catalog[name]
    output = packages / pathlib.Path(path).name
    digest = checksums[path]
    if not output.exists() or hashlib.md5(output.read_bytes()).hexdigest() != digest:
        partial = output.with_suffix('.part')
        download(base + '/' + path, partial)
        if hashlib.md5(partial.read_bytes()).hexdigest() != digest:
            raise RuntimeError('checksum mismatch: ' + path)
        partial.rename(output)
    print('verified', output.name, flush=True)
    return dict(name=name, file=output.name, sha256=hashlib.sha256(output.read_bytes()).hexdigest(), source=base + '/' + path, role=args.role)


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    entries = list(pool.map(fetch, names))
if args.native_manifest:
    for entry in json.loads(args.native_manifest.read_text()):
        if entry['name'] in names or pathlib.Path(entry['file']).name != entry['file'] or not entry['file'].endswith('.txz'):
            raise SystemExit('invalid or duplicate native package')
        source = args.native_manifest.parent / entry['file']
        if hashlib.sha256(source.read_bytes()).hexdigest() != entry['sha256']:
            raise SystemExit('native checksum mismatch')
        shutil.copyfile(source, packages / entry['file'])
        names.append(entry['name'])
        entries.append(entry)
kernel = pathlib.Path(catalog['kernel-generic']).name.rsplit('-', 3)[1]
manifest = dict(schema=1, distribution='slackware64-current', architecture='x86_64', kernel=kernel, packages=entries)
partial = root / 'manifest.json.part'
partial.write_text(json.dumps(manifest, indent=2) + '\n')
partial.replace(root / 'manifest.json')
print('Prepared', len(entries), 'explicit packages; kernel', kernel)
print('This package directory is input to ISO assembly, not a bootable ISO.')
