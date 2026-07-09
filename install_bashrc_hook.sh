#!/bin/bash
# =============================================================================
# install_bashrc_hook.sh — Safely add pulse_start_fixed_v2 to .bashrc
#
# WHY NOT just hardcode `export PULSE_SERVER=...` into .bashrc:
#   - Stale if PulseAudio restarts on a different port / after a reboot
#   - No validation that PulseAudio is actually reachable
#   - Requires manual re-editing whenever config changes
#
# WHAT THIS SCRIPT DOES INSTEAD:
#   - Installs pulse_start_fixed_v2 to ~/bin
#   - Adds ONE idempotent line to ~/.bashrc that re-runs the tool via eval
#     on every new shell, so state is always fresh
#   - Guards against duplicate insertion (safe to re-run this script)
#   - Redirects stderr to a log file instead of spamming every new terminal
#   - Provides an opt-out env var (PULSE_START_SKIP=1) for fast shells
#     (e.g. inside scripts, CI, or when you don't need audio)
#
# Usage:
#   bash install_bashrc_hook.sh          # install the hook
#   bash install_bashrc_hook.sh --remove # remove the hook cleanly
# =============================================================================

set -e

BASHRC="$HOME/.bashrc"
BIN_DIR="$HOME/bin"
BIN_NAME="pulse_start_fixed_v2"
MARKER_START="# >>> pulse_start_fixed_v2 hook >>>"
MARKER_END="# <<< pulse_start_fixed_v2 hook <<<"

COLOR_GREEN='\033[1;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[1;31m'
COLOR_RESET='\033[0m'

log_ok()   { echo -e "${COLOR_GREEN}[OK]${COLOR_RESET} $*"; }
log_warn() { echo -e "${COLOR_YELLOW}[!]${COLOR_RESET} $*"; }
log_err()  { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2; }

remove_hook() {
    if [ -f "$BASHRC" ] && grep -q "$MARKER_START" "$BASHRC"; then
        # Delete everything between the markers (inclusive), in-place
        sed -i "/$MARKER_START/,/$MARKER_END/d" "$BASHRC"
        log_ok "Hook removed from $BASHRC"
    else
        log_warn "No hook found in $BASHRC (nothing to remove)"
    fi
}

install_hook() {
    mkdir -p "$BIN_DIR"

    if [ ! -f "$BIN_NAME" ]; then
        log_err "$BIN_NAME not found in current directory. Build it first:"
        echo "    clang -O2 -s -o $BIN_NAME pulse_start_fixed_v2.c"
        exit 1
    fi

    cp "$BIN_NAME" "$BIN_DIR/"
    chmod 755 "$BIN_DIR/$BIN_NAME"
    log_ok "Installed binary to $BIN_DIR/$BIN_NAME"

    # Idempotency: remove any previous hook before re-adding
    if [ -f "$BASHRC" ] && grep -q "$MARKER_START" "$BASHRC"; then
        log_warn "Existing hook found — replacing it (not duplicating)"
        remove_hook
    fi

    touch "$BASHRC"
    {
        echo ""
        echo "$MARKER_START"
        echo "# Auto-starts/detects PulseAudio and exports PULSE_SERVER etc."
        echo "# on every new interactive shell. Safe to re-run install script."
        echo "# Set PULSE_START_SKIP=1 before opening a shell to skip this."
        echo 'if [ -z "$PULSE_START_SKIP" ] && [ -x "$HOME/bin/'"$BIN_NAME"'" ]; then'
        echo '    eval "$("$HOME/bin/'"$BIN_NAME"'" 2>"$HOME/log/pulse_start_hook.log")"'
        echo 'fi'
        echo "$MARKER_END"
    } >> "$BASHRC"

    log_ok "Hook added to $BASHRC"
    echo ""
    echo "Open a NEW terminal (or run: source ~/.bashrc) to activate it."
    echo "Startup messages/errors go to: ~/log/pulse_start_hook.log"
    echo ""
    echo "To temporarily skip it in one shell:"
    echo "    PULSE_START_SKIP=1 bash"
    echo ""
    echo "To remove the hook later:"
    echo "    bash install_bashrc_hook.sh --remove"
}

case "${1:-}" in
    --remove|-r)
        remove_hook
        ;;
    *)
        install_hook
        ;;
esac
