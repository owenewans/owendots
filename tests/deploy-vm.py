#!/usr/bin/env python3
"""Deploy all application choices through the TUI in a disposable local VM."""
import argparse
from pathlib import Path
import re
import select
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--port', type=int, required=True)
parser.add_argument('--key', required=True)
parser.add_argument('--known-hosts', required=True)
parser.add_argument('--log', type=Path, required=True)
args = parser.parse_args()
process = subprocess.Popen(['ssh', '-tt', '-i', args.key, '-p', str(args.port),
    '-oUserKnownHostsFile='+args.known_hosts, 'owenewans@127.0.0.1',
    "env TERM=xterm /bin/bash -c 'stty rows 40 cols 120; exec owendots'"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
log = args.log.open('xb')
buffer = b''
ansi = re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]|\x1b[()][A-Z0-9]|\x1b[=>]')

def wait(text, timeout=60):
    global buffer
    deadline = time.monotonic()+timeout
    while time.monotonic() < deadline:
        clean = ansi.sub(b'', buffer)
        if text.lower().encode() in clean.lower():
            buffer = b''
            print('PASS prompt:', text, flush=True)
            return
        if b'owendots: ' in clean or process.poll() is not None:
            raise RuntimeError(clean[-3000:].decode(errors='replace'))
        if select.select([process.stdout], [], [], .5)[0]:
            data = process.stdout.read(65536)
            if not data: raise RuntimeError(clean[-3000:].decode(errors='replace'))
            log.write(data)
            log.flush()
            buffer += data
    raise TimeoutError(text+': '+ansi.sub(b'', buffer[-3000:]).decode(errors='replace'))

def answer(prompt, value=''):
    wait(prompt)
    time.sleep(.2)
    process.stdin.write((value+'\r').encode())

started = time.monotonic()
try:
    answer('Workstation')
    for title in ['Terminals', 'Browsers', 'Telegram clients', 'Compositors']:
        answer(title, 'b')
        answer('Default application / session')
    answer('password:', 'owenewans')
    answer('Install or upgrade the following')
    answer('Apply this desktop plan?', 'i')
    wait('Desktop packages and configuration installed.', timeout=1800)
    process.stdin.write(b'\r')
    assert process.wait(timeout=15) == 0
    print(f'PASS fresh desktop deployment in {time.monotonic()-started:.1f}s')
finally:
    if process.poll() is None:
        process.terminate()
