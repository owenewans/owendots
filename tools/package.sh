#!/bin/sh
set -eu
: "${OUTPUT:?output directory}"
: "${WORK:?empty staging directory}"
[ -f /etc/slackware-version ] || exit 1
[ ! -e "$WORK" ] || exit 1
project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$OUTPUT" "$WORK"
OUTPUT=$(realpath "$OUTPUT")
WORK=$(realpath "$WORK")
install -Dm755 "$project/zig-out/bin/owendots" "$WORK/usr/bin/owendots"
install -d "$WORK/usr/share/owendots" "$WORK/usr/doc/owendots" "$WORK/install"
cp -R "$project/templates" "$WORK/usr/share/owendots/"
cp "$project/palette.toml" "$WORK/usr/share/owendots/"
cp "$project/LICENSE" "$WORK/usr/doc/owendots/"
cat > "$WORK/install/slack-desc" <<'EOF'
owendots: owendots (Slackware workstation configuration)
owendots:
owendots: Manual installer and workstation configuration tools.
owendots: Palette templates and the static Zig executable.
owendots:
owendots:
owendots:
owendots:
owendots:
owendots:
owendots:
EOF
cd "$WORK"
TAR_OPTIONS='--owner=0 --group=0 --numeric-owner' makepkg -l n -c n "$OUTPUT/owendots-0.1.0-x86_64-1_owen.txz"
