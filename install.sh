#!/bin/bash
set -euo pipefail

release=2026.09.25-preview1
archive_sha256=004a42827c7f691824d6e93c9baa2b75462014805f631a039881bb27d25dd9fd
archive_url="https://github.com/owenewans/owendots/releases/download/$release/owendots-x86_64.tar.xz"

fail() { printf 'owendots: %s\n' "$*" >&2; exit 1; }
if [[ ${1:-} == --help ]]; then
    printf 'Usage: bash install.sh [NEW_DIRECTORY]\nRun from the owendots Slackware-current installer ISO.\n'
    exit
fi
(( $# <= 1 )) || fail 'expected one destination directory at most'
[[ $(uname -m) == x86_64 ]] || fail 'x86_64 is required'
(( EUID == 0 )) || fail 'run as root in the installer environment'
[[ -r /run/owendots-live && $(</run/owendots-live) == slackware64-current ]] ||
    fail 'boot the owendots current installer ISO from Ventoy first; see manual.txt'
[[ $archive_sha256 =~ ^[a-f0-9]{64}$ ]] || fail 'this checkout has no published bundle yet'
[[ -r /dev/tty && -w /dev/tty ]] || fail 'an interactive terminal is required'
for program in curl tar xz sha256sum awk mktemp; do
    command -v "$program" >/dev/null || fail "missing program: $program"
done
destination=${1:-"$PWD/owendots-install"}
[[ $destination == /* ]] || destination="$PWD/$destination"
[[ ! -e $destination && ! -L $destination ]] || fail "destination already exists: $destination"
parent=$(dirname -- "$destination")
[[ -d $parent ]] || fail "parent directory does not exist: $parent"
work=$(mktemp -d "$parent/.owendots-download.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
printf 'Downloading owendots %s into %s\n' "$release" "$destination"
curl --fail --location --proto '=https' --proto-redir '=https' \
    --retry 3 --retry-connrefused --connect-timeout 20 --output "$work/bundle.tar.xz" "$archive_url"
printf '%s  %s\n' "$archive_sha256" "$work/bundle.tar.xz" | sha256sum --check --status ||
    fail 'archive checksum mismatch'
tar -tJf "$work/bundle.tar.xz" > "$work/files"
awk '
    $0 !~ /^owendots\// || $0 ~ /(^|\/)\.\.(\/|$)/ || $0 ~ /\\/ { exit 1 }
' "$work/files" || fail 'invalid archive path'
tar -tvJf "$work/bundle.tar.xz" | awk 'substr($0,1,1) !~ /[-d]/ { exit 1 }' ||
    fail 'archive contains links or special files'
tar -xJf "$work/bundle.tar.xz" --no-same-owner --no-same-permissions -C "$work"
[[ -x $work/owendots/bin/owendots && -f $work/owendots/media/manifest.json &&
   -f $work/owendots/manual.txt ]] || fail 'incomplete installer archive'
mv -T -- "$work/owendots" "$destination"
printf 'Manual: %s/manual.txt\nStarting the installer; review its disk plan before confirming.\n' "$destination"
rm -rf -- "$work"
trap - EXIT INT TERM HUP
exec "$destination/bin/owendots" install "$destination/media" </dev/tty
