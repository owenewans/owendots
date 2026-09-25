#!/usr/bin/env python3
"""Test the download wrapper in a disposable root Slackware container."""
import fcntl
import hashlib
import io
import os
from pathlib import Path
import pty
import re
import select
import subprocess
import sys
import tarfile
import tempfile
import termios
import time

assert os.geteuid() == 0 and Path('/etc/slackware-version').exists()
source = Path(sys.argv[1]).read_text()
marker = Path('/run/owendots-live')
original = marker.read_bytes() if marker.exists() else None
try:
    marker.write_text('slackware64-current\n')
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        mock = root / 'curl'
        mock.write_text('''#!/usr/bin/python3
import os,sys,shutil
assert sys.argv[sys.argv.index('--proto')+1] == '=https'
if os.environ.get('FAIL_DOWNLOAD'): sys.exit(23)
shutil.copyfile(os.environ['BOOTSTRAP_FIXTURE'], sys.argv[sys.argv.index('--output')+1])
''')
        mock.chmod(0o755)

        def archive(name, extra=None):
            path = root / (name+'.tar.xz')
            with tarfile.open(path, 'w:xz') as tar:
                for file, content, mode in [
                    ('bin/owendots', b'#!/bin/sh\n[ "$1" = install ] || exit 9\necho INSTALLER_CALLED\n', 0o755),
                    ('manual.txt', 'Русский / English\n'.encode(), 0o644),
                    ('media/manifest.json', b'{}\n', 0o644)]:
                    item = tarfile.TarInfo('owendots/'+file)
                    item.mode, item.size = mode, len(content)
                    tar.addfile(item, io.BytesIO(content))
                if extra:
                    tar.addfile(extra)
            return path

        good = archive('good')

        def run(name, payload=good, bad_hash=False, fail_download=False, exists=False):
            digest = '0'*64 if bad_hash else hashlib.file_digest(payload.open('rb'), 'sha256').hexdigest()
            script = root / (name+'.sh')
            script.write_text(re.sub(r'^archive_sha256=.*$', 'archive_sha256='+digest, source, flags=re.M))
            dest = root / (name+'-result')
            if exists:
                dest.mkdir()
                (dest/'keep').write_text('original')
            env = dict(os.environ, PATH=str(root)+':'+os.environ['PATH'], BOOTSTRAP_FIXTURE=str(payload))
            if fail_download:
                env['FAIL_DOWNLOAD'] = '1'
            master, slave = pty.openpty()
            def terminal():
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            piped = name == 'pipe'
            command = ['bash', '-s', '--', str(dest)] if piped else ['bash', str(script), str(dest)]
            child = subprocess.Popen(command, env=env,
                stdin=subprocess.PIPE if piped else slave, stdout=slave, stderr=slave, preexec_fn=terminal)
            if piped:
                child.stdin.write(script.read_bytes())
                child.stdin.close()
            os.close(slave)
            output = b''
            deadline = time.monotonic()+30
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        data = os.read(master, 65536)
                        if not data: break
                        output += data
                    except OSError: break
                elif child.poll() is not None: break
            else:
                child.kill()
                raise AssertionError('bootstrap timed out')
            code = child.wait(timeout=5)
            os.close(master)
            if name in ['success', 'pipe']:
                assert code == 0 and b'INSTALLER_CALLED' in output, output
                assert (dest/'manual.txt').read_text() == 'Русский / English\n'
            else:
                assert code != 0 and b'INSTALLER_CALLED' not in output, output
                if exists: assert (dest/'keep').read_text() == 'original'
                else: assert not dest.exists()
            assert not list(root.glob('.owendots-download.*'))

        run('success')
        run('pipe')
        run('checksum', bad_hash=True)
        run('download', fail_download=True)
        run('existing', exists=True)
        bad = tarfile.TarInfo('../escaped')
        run('traversal', archive('traversal', bad))
        link = tarfile.TarInfo('owendots/link')
        link.type, link.linkname = tarfile.SYMTYPE, '/etc/passwd'
        run('link', archive('link', link))
        marker.unlink()
        run('wrong-environment')
    print('PASS bootstrap launch, manual, checksum, failed download, archive paths, links and environment guard')
finally:
    if original is None: marker.unlink(missing_ok=True)
    else: marker.write_bytes(original)
