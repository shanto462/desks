#!/bin/bash
# Regenerates docs/images/*.png from the app's offscreen render mode.
#
# Render mode draws Settings pages, the bar and the move overlay with built-in sample
# data into PNG files, then exits. It never starts the engine, never moves a window and
# never asks for a permission. No real window titles or display names are used.
#
# Usage: scripts/screenshots.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/docs/images"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift build -c release --product Desks
BIN="$(swift build -c release --show-bin-path)/Desks"
# Settings pages are drawn as a normal-sized window (820 x 660 points), showing the top of the page.
DESKS_RENDER_HEIGHT=660 "$BIN" --render-settings "$WORK/raw" >/dev/null

mkdir -p "$OUT"
rm -f "$OUT"/*.png

# name  source file  max width (images are only scaled, never cropped)
shots=(
    "bar                 bar                       800"
    "bar-hover-delete    anim-hoverdelete          800"
    "move-overlay        overlay                   640"
    "settings-layouts    settings-layouts-details  1200"
    "settings-shortcuts  settings-shortcuts        1200"
    "settings-rules      settings-rules            1200"
    "settings-appearance settings-appearance       1200"
    "settings-general    settings-general          1200"
    "settings-about      settings-about            1200"
)

for mode in light dark; do
    for line in "${shots[@]}"; do
        read -r name src maxw <<<"$line"
        dst="$OUT/$name-$mode.png"
        cp "$WORK/raw/$src-$mode.png" "$dst"
        # Scale wide images down to keep the files small. Never scale up, never crop.
        width="$(sips -g pixelWidth "$dst" | awk '/pixelWidth/ {print $2}')"
        if (( width > maxw )); then
            sips --resampleWidth "$maxw" "$dst" >/dev/null
        fi
    done
done

ls -l "$OUT"
