#!/usr/bin/env bash
# Re-render every diagram: PNG (160 dpi) + SVG next to its .dot source.
set -euo pipefail
cd "$(dirname "$0")"
for f in *.dot; do b="${f%.dot}"; dot -Tpng -Gdpi=160 "$f" -o "$b.png"; dot -Tsvg "$f" -o "$b.svg"; done
