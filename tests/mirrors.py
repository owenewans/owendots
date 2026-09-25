#!/usr/bin/env python3
"""Run as root in a disposable Slackware container."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

assert os.geteuid() == 0 and Path('/etc/slackware-version').exists()
paths = [Path('/etc/slackpkg/mirrors'), Path('/var/lib/owendots/media.json'),
         Path('/var/lib/owendots/backup/slackpkg-mirrors')]
original = {p: p.read_bytes() if p.exists() else None for p in paths}
try:
    for p in paths:
        p.parent.mkdir(parents=True, exist_ok=True)
    paths[1].write_text(json.dumps(dict(schema=1, distribution='slackware64-current',
        architecture='x86_64', kernel='7.2.7', packages=[dict(name='fixture',
        file='fixture-1-x86_64-1.txz', sha256='0'*64, source=None, role='base')])))
    paths[0].write_text('# original mirror list\n')
    paths[2].unlink(missing_ok=True)
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        mock = root / 'mock'
        mock.write_text('''#!/usr/bin/python3
import os,sys
from pathlib import Path
mode=os.environ['MIRROR_TEST']
if Path(sys.argv[0]).name.startswith('gpg'):
    if '--show-keys' in sys.argv:
        key='0'*40 if mode == 'badkey' else 'EC5649DA401E22ABFA6736EF6A4463C040102233'
        print('pub:-:1024:17:key:\\nfpr:::::::::'+key+':')
elif Path(sys.argv[0]).name == 'ping':
    if mode != 'ping': sys.exit(1)
    delay={'fast.example':1,'next.example':2,'slow.example':9}[sys.argv[-1]]
    print(f'rtt min/avg/max/mdev = {delay}/{delay}/{delay}/0 ms')
elif '--output' in sys.argv:
    Path(sys.argv[sys.argv.index('--output')+1]).write_text(
        'Available https mirrors: '+''.join(f'<a href="https://{host}/">mirror</a>'
        for host in ['slow.example','fast.example','next.example'])+'Available http mirrors:')
else:
    sys.exit(1 if mode == 'fail' or 'fast.example' in sys.argv[-1] else 0)
''')
        mock.chmod(0o755)
        for name in ['curl', 'ping', 'gpg1', 'gpg2']:
            (root / name).symlink_to(mock)
        for mode, expected in [('ping', 'next.example'), ('https', 'slow.example'), ('fail', None), ('badkey', None)]:
            before = paths[0].read_text()
            env = dict(os.environ, PATH=directory+':'+os.environ['PATH'], MIRROR_TEST=mode)
            result = subprocess.run([sys.argv[1], 'mirror'], env=env, capture_output=True, text=True)
            if expected:
                assert result.returncode == 0, result
                assert paths[0].read_text() == f'https://{expected}/slackware64-current/\n'
            else:
                error = 'InvalidSigningKey' if mode == 'badkey' else 'MirrorUnavailable'
                assert result.returncode != 0 and error in result.stderr, result
                assert paths[0].read_text() == before
            assert paths[2].read_text() == '# original mirror list\n'
    print('PASS mirror latency, HTTPS fallback, pinned key, backup and failure preservation')
finally:
    for path, data in original.items():
        if data is None:
            path.unlink(missing_ok=True)
        else:
            path.write_bytes(data)
