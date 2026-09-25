#!/usr/bin/env python3
"""Run in a disposable Slackware container with a TTY and /media mounted read-only."""
import json
import os
import pathlib
import subprocess

assert os.geteuid() == 0
assert pathlib.Path('/etc/slackware-version').exists()
manifest = json.loads(pathlib.Path('/media/manifest.json').read_text())
cache = pathlib.Path('/var/cache/owendots/packages')
state = pathlib.Path('/var/lib/owendots')
cache.mkdir(parents=True)
state.mkdir(parents=True)
for package in manifest['packages']:
    if package['role'] == 'desktop':
        (cache / package['file']).symlink_to('/media/packages/' + package['file'])
        if package['name'] == 'yazi':
            package['sha256'] = '0' * 64
(state / 'media.json').write_text(json.dumps(manifest))
dialog = pathlib.Path('/usr/local/bin/dialog')
dialog.parent.mkdir(parents=True, exist_ok=True)
dialog.write_text('#!/bin/sh\nfor arg; do [ "$arg" != --menu ] || printf install; done\nexit 0\n')
dialog.chmod(0o755)
env = dict(os.environ, PATH='/usr/local/bin:' + os.environ['PATH'])
selection = dict(launch=dict(terminal='foot', browser='firefox', telegram='tele', compositor='niri'))
database = pathlib.Path('/var/lib/pkgtools/packages')
before = {p.name: p.read_bytes() for p in database.iterdir()}
result = subprocess.run(['/owendots', 'deploy-system', json.dumps(selection)], env=env,
                        capture_output=True, text=True)
assert result.returncode == 1, result
assert 'PackageChecksumMismatch' in result.stderr, result
assert {p.name: p.read_bytes() for p in database.iterdir()} == before
print('PASS corrupted desktop archive rejected before pkgtools modified the database')
