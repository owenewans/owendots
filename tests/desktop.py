#!/usr/bin/env python3
"""Run as an unprivileged user after installing owendots and its templates."""
import json
import os
import pathlib
import subprocess
import tempfile
import tomllib

assert os.geteuid() != 0, 'run this test as a desktop user'
with tempfile.TemporaryDirectory(prefix='owendots-desktop-') as directory:
    root = pathlib.Path(directory)
    config = root / 'config'
    (config / 'owendots').mkdir(parents=True)
    (config / 'foot').mkdir()
    (config / 'foot/foot.ini').write_text('original terminal configuration\n')
    (config / 'owendots/apps.json').write_text(json.dumps(dict(
        terminal='foot', browser='firefox', telegram='tele', compositor='scroll')))
    env = dict(os.environ, XDG_CONFIG_HOME=str(config))

    def run(*args, ok=True):
        result = subprocess.run(['owendots', *args], env=env, capture_output=True, text=True)
        assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
        return result

    run('theme', 'apply')
    assert (config / 'owendots/backup/foot/foot.ini').read_text() == 'original terminal configuration\n'
    assert 'sway/workspaces' in (config / 'waybar/config.jsonc').read_text()
    assert 'niri/workspaces' in (config / 'waybar/niri.jsonc').read_text()
    assert 'sway/workspaces' in (config / 'waybar/scroll.jsonc').read_text()
    assert not (config / 'firefox').exists()
    assert (config / 'owendots/firefox/chrome/userChrome.css').is_file()
    assert (config / 'owendots/palemoon/user.js').is_file()
    for path in config.rglob('*'):
        if not path.is_file() or '/backup/' in str(path):
            continue
        text = path.read_text()
        assert '{{' not in text, path
        if path.suffix in ['.json', '.jsonc']:
            json.loads(text)
        if path.suffix == '.toml':
            tomllib.loads(text)
    before = (config / 'foot/foot.ini').read_text()
    palette = config / 'owendots/palette.toml'
    original_palette = palette.read_text()
    palette.write_text(original_palette + '\nunknown = "#123456"\n')
    run('theme', 'apply', ok=False)
    assert (config / 'foot/foot.ini').read_text() == before
    palette.write_text(original_palette)
    run('theme', 'apply')
    assert (config / 'owendots/backup/foot/foot.ini').read_text() == 'original terminal configuration\n'

    display = config / 'owendots/display.json'
    settings = dict(output='DP-1', width=1920, height=1080, refresh=59940, scale=125)
    display.write_text(json.dumps(settings))
    run('theme', 'apply')
    assert 'mode "1920x1080@59.940"' in (config / 'niri/config.kdl').read_text()
    assert 'output DP-1 mode 1920x1080@59.940Hz scale 1.25 force' in (config / 'scroll/config').read_text()
    before = (config / 'niri/config.kdl').read_text()
    display.write_text(json.dumps(dict(settings, output='DP-1; exec id')))
    run('theme', 'apply', ok=False)
    assert (config / 'niri/config.kdl').read_text() == before
    display.unlink()

    binaries = root / 'bin'
    binaries.mkdir()
    for program in ['foot', 'firefox']:
        path = binaries / program
        path.write_text('#!/usr/bin/python3\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
        path.chmod(0o755)
    env['PATH'] = str(binaries) + ':' + os.environ['PATH']
    literal = 'https://example.org/$(touch SHOULD_NOT_EXIST); x'
    args = json.loads(run('launch', 'browser', literal).stdout)
    assert args == ['--no-remote', '--profile', str(config / 'owendots/firefox'), literal]
    assert json.loads(run('launch', 'editor', 'a file.txt').stdout) == ['-e', 'micro', 'a file.txt']
    run('launch', 'not-an-app', ok=False)
    print('PASS palette transaction, original backups, browser isolation and literal application arguments')
