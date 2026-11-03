#!/bin/sh
# Links scripts/desks to ~/.local/bin/desks. No sudo.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$HOME/.local/bin"

mkdir -p "$BIN_DIR"
ln -sfn "$ROOT/scripts/desks" "$BIN_DIR/desks"
echo "Linked $BIN_DIR/desks -> $ROOT/scripts/desks"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        echo "$BIN_DIR is not in your PATH. Add this line to ~/.zshrc:"
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        ;;
esac
