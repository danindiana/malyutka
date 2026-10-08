#!/usr/bin/env bash
# Builds a source release from the committed tree and refuses to ship any
# generated binary. Usage: tools/release.sh OUTDIR
set -euo pipefail
OUT=$(realpath "${1:?usage: tools/release.sh OUTDIR}")
cd "$(dirname "$0")/.."
ver=$(sed -n 's/^version *= *"\(.*\)"/\1/p' malyutka.nimble)
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "error: uncommitted changes" >&2; exit 1; }
tar_path="$OUT/malyutka-$ver.tar.gz"
git archive --format=tar.gz --prefix=malyutka/ -o "$tar_path" HEAD
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tar xzf "$tar_path" -C "$tmp"
bad=0
while IFS= read -r -d '' f; do
  if [ "$(head -c4 "$f" | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
    echo "error: ELF binary in release: ${f#$tmp/}" >&2; bad=1
  fi
  if [ -x "$f" ] && [[ "$f" != *.sh && "$f" != *.py ]]; then
    echo "error: unexpected executable in release: ${f#$tmp/}" >&2; bad=1
  fi
done < <(find "$tmp" -type f -print0)
[ $bad -eq 0 ] || { rm -f "$tar_path"; exit 1; }
echo "$tar_path"
sha256sum "$tar_path"
