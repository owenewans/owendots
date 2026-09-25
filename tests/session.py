#!/usr/bin/env python3
"""Check startup notification and cleanup of session-owned child processes."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time

assert os.geteuid() != 0, 'run as a desktop user'
script = str(pathlib.Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='owendots-session-') as directory:
    root = pathlib.Path(directory)
    binaries = root / 'bin'
    binaries.mkdir()
    fixture = binaries / 'fixture'
    fixture.write_text('''#!/usr/bin/python3
import json,os,pathlib,signal,subprocess,time
root=pathlib.Path(os.environ['OWEN_TEST_ROOT'])
name=pathlib.Path(__import__('sys').argv[0]).name
if name == 'dbus-update-activation-environment':
    (root/'activation.json').write_text(json.dumps(dict(os.environ)))
    raise SystemExit(0)
(root/(name+'-'+str(os.getpid()))).write_text(str(os.getpid()))
signal.signal(signal.SIGTERM,lambda *_:exit(0))
if name == 'niri':
    subprocess.run(['bash',os.environ['OWEN_TEST_SCRIPT'],'ready'],check=True,
      env=dict(os.environ,WAYLAND_DISPLAY='wayland-fixture',NIRI_SOCKET='/tmp/niri-fixture.sock'))
    while not (root/'exit-compositor').exists(): time.sleep(.05)
else:
    while True: time.sleep(.05)
''')
    fixture.chmod(0o755)
    for name in ['niri', 'pipewire', 'pipewire-pulse', 'wireplumber', 'wl-paste',
                 'cliphist', 'waybar', 'dunst', 'elephant', 'dbus-update-activation-environment']:
        (binaries / name).symlink_to('fixture')
    env = dict(os.environ, PATH=str(binaries) + ':' + os.environ['PATH'],
               XDG_RUNTIME_DIR=str(root), DBUS_SESSION_BUS_ADDRESS='unix:path=/fixture',
               OWEN_TEST_ROOT=str(root), OWEN_TEST_SCRIPT=script)
    session = subprocess.Popen(['bash', script, 'niri'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not list(root.glob('waybar-*')):
            assert session.poll() is None, session.communicate()
            time.sleep(.05)
        assert list(root.glob('waybar-*')), 'session services were not started'
        activation = json.loads((root / 'activation.json').read_text())
        assert activation['WAYLAND_DISPLAY'] == 'wayland-fixture'
        assert activation['NIRI_SOCKET'] == '/tmp/niri-fixture.sock'
        assert activation['LANG'] == 'en_US.UTF-8' and activation['TZ'] == 'UTC'
        (root / 'exit-compositor').touch()
        output = session.communicate(timeout=10)
        assert session.returncode == 0, output
        assert not list(root.glob('owendots.*')), 'session runtime directory leaked'
        for path in root.iterdir():
            if path.name.startswith(('niri-', 'pipewire-', 'wireplumber-', 'wl-paste-', 'waybar-', 'dunst-', 'elephant-')):
                try:
                    os.kill(int(path.read_text()), 0)
                except ProcessLookupError:
                    continue
                raise AssertionError('session child leaked: ' + path.name)
    finally:
        if session.poll() is None:
            session.terminate()
            session.communicate(timeout=10)
    print('PASS compositor environment handoff and session child cleanup')
