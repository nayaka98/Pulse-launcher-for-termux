#!/bin/bash
# =============================================================================
# BUILD_AND_USE.sh — Complete setup for pulse_start_fixed_v2
#
# Usage:
#   bash BUILD_AND_USE.sh           # Build dan run tests
#   bash BUILD_AND_USE.sh install   # Install ke PATH
#   bash BUILD_AND_USE.sh tmux      # Run with tmux
# =============================================================================

set -e

COLOR_RED='\033[1;31m'
COLOR_GREEN='\033[1;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[1;34m'
COLOR_RESET='\033[0m'

echo_info()  { echo -e "${COLOR_BLUE}[*]${COLOR_RESET} $*"; }
echo_ok()   { echo -e "${COLOR_GREEN}[✓]${COLOR_RESET} $*"; }
echo_err()  { echo -e "${COLOR_RED}[!]${COLOR_RESET} $*" >&2; }
echo_warn() { echo -e "${COLOR_YELLOW}[!]${COLOR_RESET} $*"; }

# =============================================================================
# SECTION 1: BUILD
# =============================================================================

build_c_version() {
    local src_file="${1:-pulse_start_fixed_v2.c}"
    local out_file="${2:-pulse_start_fixed_v2}"

    echo_info "Building $src_file..."

    # Check if compiler available
    if ! command -v clang &> /dev/null && ! command -v gcc &> /dev/null; then
        echo_err "clang or gcc not found. Install with:"
        echo "    pkg install clang"
        exit 1
    fi

    # Termux ships clang by default (no gcc package), so prefer clang first
    local compiler="clang"
    if ! command -v clang &> /dev/null; then
        compiler="gcc"
    fi

    echo_info "Using compiler: $compiler"

    # Compile
    $compiler -O2 -s -Wall -Wextra \
        -D_GNU_SOURCE \
        -o "$out_file" \
        "$src_file" \
        -lm 2>&1 || {
        echo_err "Compilation failed!"
        exit 1
    }

    # Check result
    if [ -f "$out_file" ] && [ -x "$out_file" ]; then
        echo_ok "Compiled: $(ls -lh "$out_file" | awk '{print $5 " " $9}')"
        return 0
    else
        echo_err "Binary not created"
        exit 1
    fi
}

# =============================================================================
# SECTION 2: TESTS
# =============================================================================

test_basic_execution() {
    echo_info "TEST 1: Basic execution (check PulseAudio status)..."
    
    ./pulse_start_fixed_v2 2>&1 | head -20 || true
    echo_ok "Test 1 passed"
}

test_env_output() {
    echo_info "TEST 2: Environment variable output..."
    
    local output=$(./pulse_start_fixed_v2 2>/dev/null || true)
    
    if echo "$output" | grep -q "export XDG_RUNTIME_DIR"; then
        echo_ok "XDG_RUNTIME_DIR found"
    else
        echo_err "XDG_RUNTIME_DIR missing"
    fi
    
    if echo "$output" | grep -q "export PULSE_SERVER"; then
        echo_ok "PULSE_SERVER found"
    else
        echo_err "PULSE_SERVER missing"
    fi
    
    if echo "$output" | grep -q "export PULSE_LATENCY_MSEC"; then
        echo_ok "PULSE_LATENCY_MSEC found"
    else
        echo_err "PULSE_LATENCY_MSEC missing"
    fi
    
    echo_ok "Test 2 passed"
}

test_eval_vars() {
    echo_info "TEST 3: Eval environment variables..."
    
    # Save current values
    local old_pulse_server="$PULSE_SERVER"
    local old_latency="$PULSE_LATENCY_MSEC"
    
    # Eval new values
    eval "$(./pulse_start_fixed_v2 2>/dev/null || true)"
    
    if [ -n "$PULSE_SERVER" ]; then
        echo_ok "PULSE_SERVER set: $PULSE_SERVER"
    else
        echo_warn "PULSE_SERVER not set"
    fi
    
    if [ -n "$PULSE_LATENCY_MSEC" ]; then
        echo_ok "PULSE_LATENCY_MSEC set: $PULSE_LATENCY_MSEC"
    else
        echo_warn "PULSE_LATENCY_MSEC not set"
    fi
    
    # Restore
    export PULSE_SERVER="$old_pulse_server"
    export PULSE_LATENCY_MSEC="$old_latency"
    
    echo_ok "Test 3 passed"
}

test_pactl_connection() {
    echo_info "TEST 4: Try pactl connection..."
    
    if ! command -v pactl &> /dev/null; then
        echo_warn "pactl not found, skipping test"
        return 0
    fi
    
    eval "$(./pulse_start_fixed_v2 2>/dev/null || true)"
    
    if pactl info &>/dev/null; then
        echo_ok "Connected to PulseAudio"
    else
        echo_warn "PulseAudio not running (expected first run)"
    fi
    
    echo_ok "Test 4 passed"
}

# =============================================================================
# SECTION 3: INSTALLATION
# =============================================================================

install_binary() {
    echo_info "Installing pulse_start_fixed_v2 to ~/bin..."
    
    mkdir -p ~/bin
    
    if [ ! -f pulse_start_fixed_v2 ]; then
        echo_err "pulse_start_fixed_v2 not found. Run build first."
        exit 1
    fi
    
    cp pulse_start_fixed_v2 ~/bin/
    chmod 755 ~/bin/pulse_start_fixed_v2
    
    echo_ok "Installed to ~/bin/pulse_start_fixed_v2"
    
    # Check if ~/bin in PATH
    if echo "$PATH" | grep -q "$HOME/bin"; then
        echo_ok "~/bin is in PATH"
    else
        echo_warn "~/bin not in PATH. Add to ~/.bashrc:"
        echo "    export PATH=\$HOME/bin:\$PATH"
    fi
}

# =============================================================================
# SECTION 4: TMUX INTEGRATION
# =============================================================================

run_with_tmux() {
    echo_info "Starting PulseAudio with tmux session..."
    
    if ! command -v tmux &> /dev/null; then
        echo_err "tmux not installed. Install with:"
        echo "    pkg install tmux"
        exit 1
    fi
    
    # Kill existing session if any
    tmux kill-session -t pulse_session 2>/dev/null || true
    
    # Run pulse_start_fixed_v2, which will create tmux session
    echo_info "Executing: eval \"\$(./pulse_start_fixed_v2)\""
    eval "$(./pulse_start_fixed_v2 2>&1)"
    
    # Give tmux time to start
    sleep 1
    
    # Check if session exists
    if tmux has-session -t pulse_session 2>/dev/null; then
        echo_ok "Tmux session created!"
        echo_info "Commands:"
        echo "    tmux attach -t pulse_session   # Connect to session"
        echo "    tmux kill-session -t pulse_session  # Stop session"
        
        # Optionally attach
        read -p "Attach to session now? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            tmux attach -t pulse_session
        fi
    else
        echo_warn "Tmux session not created (tmux might not be available in pulse_start_fixed_v2)"
    fi
}

# =============================================================================
# SECTION 5: CONFIGURATION
# =============================================================================

show_env_config() {
    echo_info "Current PulseAudio configuration:"
    echo "    XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-not set}"
    echo "    PULSE_SERVER: ${PULSE_SERVER:-not set}"
    echo "    PULSE_LATENCY_MSEC: ${PULSE_LATENCY_MSEC:-not set}"
    echo "    PULSE_TCP_PORT: ${PULSE_TCP_PORT:-4713}"
    echo "    PULSE_AAUDIO_LATENCY_MS: ${PULSE_AAUDIO_LATENCY_MS:-60}"
}

set_custom_port() {
    echo_info "Setting custom TCP port..."
    read -p "Enter port number (1024-65535): " port
    
    if [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
        export PULSE_TCP_PORT="$port"
        echo_ok "PULSE_TCP_PORT set to $port"
        eval "$(./pulse_start_fixed_v2 2>/dev/null || true)"
        echo_ok "You can now use: eval \"\$(./pulse_start_fixed_v2)\""
    else
        echo_err "Invalid port number"
        exit 1
    fi
}

set_custom_latency() {
    echo_info "Setting custom latency..."
    read -p "Enter latency in ms (1-10000): " latency
    
    if [ "$latency" -ge 1 ] && [ "$latency" -le 10000 ]; then
        export PULSE_LATENCY_MSEC="$latency"
        echo_ok "PULSE_LATENCY_MSEC set to ${latency}ms"
        eval "$(./pulse_start_fixed_v2 2>/dev/null || true)"
        echo_ok "You can now use: eval \"\$(./pulse_start_fixed_v2)\""
    else
        echo_err "Invalid latency value"
        exit 1
    fi
}

# =============================================================================
# SECTION 6: DIAGNOSTICS
# =============================================================================

diagnose_system() {
    echo_info "System diagnostics..."
    echo ""
    
    echo "Compiler:"
    if command -v gcc &>/dev/null; then
        gcc --version | head -1
    elif command -v clang &>/dev/null; then
        clang --version | head -1
    else
        echo "  No compiler found"
    fi
    
    echo ""
    echo "Required binaries:"
    for bin in pgrep pactl pulseaudio tmux; do
        if command -v $bin &>/dev/null; then
            echo "  ✓ $bin"
        else
            echo "  ✗ $bin (missing)"
        fi
    done
    
    echo ""
    echo "Directories:"
    echo "  HOME: $HOME"
    echo "  XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-not set}"
    
    echo ""
    echo "Process status:"
    if pgrep -x pulseaudio &>/dev/null; then
        echo "  ✓ PulseAudio is running (PID: $(pgrep -x pulseaudio))"
    else
        echo "  ✗ PulseAudio is not running"
    fi
    
    echo ""
    echo "Network:"
    echo "  TCP port availability:"
    for port in 4713 4714 4715; do
        if ! nc -z 127.0.0.1 $port 2>/dev/null; then
            echo "    Port $port: available ✓"
        else
            echo "    Port $port: in use ✗"
        fi
    done 2>/dev/null || echo "    (nc not available, skipping test)"
}

# =============================================================================
# MAIN MENU
# =============================================================================

show_menu() {
    echo ""
    echo -e "${COLOR_BLUE}=== pulse_start_fixed_v2 Setup ===${COLOR_RESET}"
    echo ""
    echo "1. Build (compile C code)"
    echo "2. Run basic tests"
    echo "3. Install to ~/bin"
    echo "4. Start with tmux"
    echo "5. Show environment config"
    echo "6. Set custom port"
    echo "7. Set custom latency"
    echo "8. System diagnostics"
    echo "9. Quick setup (build + test + show config)"
    echo "0. Exit"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    case "${1:-}" in
        build)
            build_c_version
            ;;
        test)
            test_basic_execution
            test_env_output
            test_eval_vars
            ;;
        install)
            install_binary
            ;;
        tmux)
            run_with_tmux
            ;;
        diagnose)
            diagnose_system
            ;;
        *)
            # Interactive menu
            while true; do
                show_menu
                read -p "Choose option: " choice
                
                case "$choice" in
                    1) build_c_version ;;
                    2) test_basic_execution; test_env_output; test_eval_vars ;;
                    3) install_binary ;;
                    4) run_with_tmux ;;
                    5) show_env_config ;;
                    6) set_custom_port ;;
                    7) set_custom_latency ;;
                    8) diagnose_system ;;
                    9)
                        build_c_version
                        test_basic_execution
                        test_env_output
                        show_env_config
                        ;;
                    0) 
                        echo_ok "Exiting"
                        exit 0
                        ;;
                    *)
                        echo_err "Invalid option"
                        ;;
                esac
                
                echo ""
                read -p "Press Enter to continue..."
            done
            ;;
    esac
}

# Auto-build if no args
if [ $# -eq 0 ]; then
    build_c_version
    test_basic_execution
    test_env_output
    show_env_config
fi

main "$@"
