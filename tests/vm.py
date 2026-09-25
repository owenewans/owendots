#!/usr/bin/env python3
"""Exercise the real installer TUI over a disposable QEMU serial socket."""
import argparse
import pathlib
import re
import socket
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--serial', type=pathlib.Path, required=True)
parser.add_argument('--log', type=pathlib.Path, required=True)
parser.add_argument('--firmware', choices=['bios', 'uefi'], required=True)
parser.add_argument('--filesystem', choices=['ext4', 'xfs', 'f2fs'], default='ext4')
parser.add_argument('--erase-qemu-vda', action='store_true', required=True)
args = parser.parse_args()
connection = socket.socket(socket.AF_UNIX)
connection.connect(str(args.serial))
connection.settimeout(1)
log = args.log.open('xb')
ansi = re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]|\x1b[()][A-Z0-9]|\x1b[=>]')
buffer = b''


def send(text):
    # Wait for dialog to finish drawing before feeding its next answer.
    time.sleep(0.15)
    connection.sendall(text.encode())


def wait(text, timeout=60):
    global buffer
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        clean = ansi.sub(b'', buffer)
        if text.encode() in clean:
            buffer = b''
            print('PASS prompt:', text, flush=True)
            return clean.decode(errors='replace')
        if b'owendots: ' in clean or b'Kernel panic' in clean:
            raise RuntimeError(clean[-4096:].decode(errors='replace'))
        try:
            chunk = connection.recv(65536)
        except TimeoutError:
            continue
        if not chunk:
            raise RuntimeError('QEMU serial connection closed')
        log.write(chunk)
        log.flush()
        buffer += chunk
    raise TimeoutError('waiting for ' + text + ': ' + ansi.sub(b'', buffer[-4096:]).decode(errors='replace'))


def answer(prompt, value):
    wait(prompt)
    send(value + '\r')


started = time.monotonic()
send('\r')
wait('root@darkstar:', timeout=180)
send('export TERM=xterm; stty rows 40 cols 120; echo OWEN_READY\r')
wait('OWEN_READY')
send('owendots install /media/owendots\r')
menu = wait('Target disk')
# This test fixture must contain one writable disk. Select it by its /dev/vda tag.
send('\r')
answer('Firmware and partition table', 'b' if args.firmware == 'bios' else 'u')
layout = wait('Manual layout;')
if '/dev/vda:' not in layout:
    raise RuntimeError('test requires /dev/vda; no disk writes authorized')
send('a\r')
answer('Mount point', '')
answer('Filesystem', {'ext4': 'e', 'xfs': 'x', 'f2fs': 'f'}[args.filesystem])
answer('Partition start in MiB', '1025')
answer('Partition size in MiB', '25000')
answer('Manual layout;', 'a')
answer('Mount point', '\x1bOB')
answer('Partition start in MiB', '1')
answer('Partition size in MiB', '1024')
answer('Manual layout;', 'a')
answer('Mount point', '\x1bOB\x1bOB')
answer('Filesystem', 'e')
answer('Partition start in MiB', '26025')
answer('Partition size in MiB', '6700')
answer('Manual layout;', 'd')
answer('Hostname (FQDN)', '')
answer('Root password (required)', 'root')
answer('Repeat password', 'root')
answer('First user', '')
answer('Password for owenewans', 'owenewans')
answer('Repeat password', 'owenewans')
answer('Private SSH key on USB', '')
answer('USB directory to copy', '')
answer('Next username', '')
answer('SSH server', 'p')
answer('doas password cache', '5')
wait('ERASE /dev/vda')
send('\r')
answer('Type the full disk path', '/dev/vda')
wait('Base installation complete.', timeout=1200)
send('\r')
wait('root@darkstar:')
print(f'PASS {args.firmware}/{args.filesystem} base installation in {time.monotonic() - started:.1f}s')
