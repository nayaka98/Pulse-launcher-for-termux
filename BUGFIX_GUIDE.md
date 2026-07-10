# PULSE_START BUG FIXES & ENVIRONMENT VARIABLE GUIDE

## 1. CRITICAL BUGS FIXED

### BUG #1: Memory Leak (child_envp)
**Original Code:**
```c
static void init_child_env(void) {
    int n = 0;
    while (environ[n]) n++;
    
    child_envp = malloc((size_t)(n + 4) * sizeof(char *));  // ← ALLOCATED
    // ... populate ...
    // ← NEVER FREED
}
```

**Problem:**
- `child_envp` allocated once with malloc
- Never freed, even on error exit paths
- Program exits, OS reclaims memory, but technically a resource leak

**Fix (pulse_start_fixed_v2.c):**
```c
static void cleanup_and_exit(int code) {
    if (child_envp != NULL) {
        free(child_envp);
        child_envp = NULL;
    }
    exit(code);
}
```

**Impact:** All exit paths now call `cleanup_and_exit()` instead of raw `exit()`.

---

### BUG #2: mkdir_p() Ignores Errors
**Original Code:**
```c
static inline void mkdir_p(const char *path) {
    mkdir(path, 0700);  // ← No error check!
}
```

**Problem:**
- `mkdir()` can fail: EACCES (permission), EROFS (read-only), ENOSPC (disk full), etc.
- Log file creation later will fail silently
- Error messages are confusing to user

**Fix:**
```c
static int mkdir_p(const char *path) {
    if (mkdir(path, 0700) == 0) return 0;
    if (errno == EEXIST) return 0;  // OK if already exists
    return -1;
}

// In setup_config():
if (mkdir_p(config.log_dir) < 0) {
    write_colored_msg(2, RED, "ERROR: Cannot create log directory", 1);
    return -1;
}
```

**Impact:** Proper error reporting, program stops early rather than failing mysteriously.

---

### BUG #3: EINTR (Signal Interrupt) Not Handled
**Original Code:**
```c
static int pulseaudio_process_running(void) {
    // ...
    int status = 0;
    waitpid(pid, &status, 0);  // ← Can be interrupted by signal!
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}
```

**Problem:**
- `waitpid()` blocks waiting for child
- If signal (SIGINT, SIGTERM, etc.) arrives, `waitpid()` returns -1 with errno=EINTR
- Function then checks `WIFEXITED()` on uninitialized `status` → undefined behavior
- Rare but possible in interactive use

**Fix:**
```c
// Retry loop on EINTR
while (waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) return 0;
    // errno == EINTR → retry
}
return WIFEXITED(status) && WEXITSTATUS(status) == 0;
```

**Impact:** Robust signal handling, won't crash or hang if interrupted.

---

### BUG #4: write() Errors Silently Ignored
**Original Code:**
```c
static inline void write_str(int fd, const char *s) {
    size_t len = strlen(s);
    ssize_t off = 0;
    while ((size_t)off < len) {
        ssize_t w = write(fd, s + off, len - (size_t)off);
        if (w <= 0) break;  // ← Stops on error, but doesn't report
        off += w;
    }
}
```

**Problem:**
- `write()` can fail: EBADF (bad fd), ENOSPC (disk full), EPIPE (broken pipe)
- Error silently ignored, user thinks message was printed
- Especially problematic if stderr is redirected/closed

**Fix:**
```c
static ssize_t write_str(int fd, const char *s) {
    size_t len = strlen(s);
    ssize_t off = 0, total = 0;
    while ((size_t)off < len) {
        ssize_t w = write(fd, s + off, len - (size_t)off);
        if (w < 0) {
            if (errno == EINTR) continue;  // Retry on signal
            return -1;                      // Report error
        }
        if (w == 0) break;
        off += w;
        total += w;
    }
    return total;
}
```

**Impact:** Callers can now detect write failures and respond appropriately.

---

### BUG #5: Race Condition (pgrep → start window)
**Original Code:**
```c
if (pulseaudio_process_running()) {  // T1: Check
    // ...
} else {
    // T2: [WINDOW] Another process could start PA here!
    pid_t pid = start_pulseaudio();   // T3: Start
    // ...
}
```

**Problem:**
- Between T1 and T3, another process (or manual user command) could start PulseAudio
- `start_pulseaudio()` would spawn a second instance
- Race condition on single-user Termux is minimal, but technically unsafe

**Fix (Advanced, not in pulse_start_fixed_v2.c):**
```c
// Use lock file for atomicity
int lockfd = open("/data/data/.../pulse_start.lock", O_CREAT | O_EXCL | O_WRONLY);
if (lockfd < 0 && errno == EEXIST) {
    // Another process holds lock, check if PA running now
    sleep_ms(100);
    if (pulseaudio_process_running()) return 0;
}
// ... start PA ...
unlink("/data/data/.../pulse_start.lock");
```

**Impact:** Prevents race condition in rare concurrent scenarios.

---

### BUG #6: No Signal Handlers for Graceful Cleanup
**Original Code:**
- No signal handlers
- If killed with SIGKILL while holding resources, no cleanup

**Fix:**
```c
static void signal_handler(int sig) {
    write_colored_msg(2, RED, "Interrupted!", 1);
    cleanup_and_exit(128 + sig);
}

// In main():
signal(SIGINT, signal_handler);
signal(SIGTERM, signal_handler);
```

**Impact:** Graceful shutdown, proper resource cleanup on interrupt.

---

### BUG #7: Environment Variables Not Actually Set in Parent Shell
**Original Code:**
```c
static void print_export_lines(void) {
    write_str(1, "export XDG_RUNTIME_DIR=...");
    // ... etc
}
```

**Problem:**
- Output goes to stdout
- **User MUST run with `eval $(pulse_start)`** to actually set env vars
- If user forgets, their child processes don't inherit PULSE_SERVER
- This is actually INTENTIONAL by design, but confusing

**Fix:**
```
// In usage instructions (stderr + stdout):
write_colored_msg(2, GRN, "To apply environment variables, run:", 1);
write_colored_msg(2, GRN, "  eval \"$(pulse_start_fixed_v2)\"", 1);
```

**Impact:** Explicit documentation that output must be eval'd.

---

## 2. ENVIRONMENT VARIABLE HANDLING

### Current Behavior

#### Variables Unset in Parent
```c
unsetenv("PULSE_SERVER");
unsetenv("PULSE_LATENCY_MSEC");
```

**Why?**
- Clear stale env vars that might point to old/dead PulseAudio socket
- If previous instance crashed, PULSE_SERVER could point to invalid port
- `pactl` would try connecting to dead port → "Connection refused"

#### Variables Set in Child Environment
```c
child_envp[0] = "XDG_RUNTIME_DIR=/data/data/.../tmp"
child_envp[1] = "PULSE_SERVER=tcp:127.0.0.1:4713"
child_envp[2] = "PULSE_LATENCY_MSEC=60"
child_envp[3..n] = inherited from parent environ
```

**Why?**
- Only child processes (pgrep, pactl, pulseaudio) need these vars
- Parent process (shell) shouldn't be contaminated

#### Variables Printed to stdout
```
export XDG_RUNTIME_DIR="/data/data/.../tmp"
export PULSE_SERVER="tcp:127.0.0.1:4713"
export PULSE_LATENCY_MSEC=60
```

**Why?**
- User's shell can capture and eval
- Parent shell inherits the exported vars
- Any children spawned from this shell will inherit

---

### HOW TO USE (IMPORTANT)

#### METHOD 1: Direct eval (Recommended)
```bash
eval "$(pulse_start_fixed_v2)"
# Now PULSE_SERVER is set in current shell
pactl info
```

#### METHOD 2: Subshell (Limited scope)
```bash
$(pulse_start_fixed_v2)  # Sets vars, but only for subshell
pactl info            # Won't work! vars not in current shell
```

#### METHOD 3: Source in script
```bash
#!/bin/bash
eval "$(pulse_start_fixed_v2)"
# Variables now available for entire script
```

#### METHOD 4: Export manually
```bash
pulse_start_fixed_v2 > /tmp/pa_exports.sh
source /tmp/pa_exports.sh
# Or: . /tmp/pa_exports.sh (POSIX)
```

---

### ENVIRONMENT VARIABLE REFERENCE

#### PULSE_SERVER
```
Format: tcp:IP:PORT or unix:/path/to/socket
Example: tcp:127.0.0.1:4713

Purpose:
  - Tells pactl where to connect
  - TCP allows remote access (with auth)
  - Unix socket is local only but faster

Default: tcp:127.0.0.1:4713 (for Termux networking)
```

#### PULSE_LATENCY_MSEC
```
Range: 1-10000 (milliseconds)
Example: 60 (60 ms latency)

Purpose:
  - Target latency for audio I/O
  - Lower = more responsive but higher CPU usage
  - Higher = less responsive but more stable

Default: 60 ms (from PULSE_AAUDIO_LATENCY_MS)
Android AAudio latency is typically 50-200ms
```

#### XDG_RUNTIME_DIR
```
Purpose: Directory for runtime sockets/files
Example: /data/data/com.termux/files/usr/tmp

PulseAudio uses this for:
  - /run/user/UID/pulse/socket (main socket)
  - PID files, lock files
  - Temporary configuration

Default: /data/data/com.termux/files/usr/tmp
```

#### PULSE_TCP_PORT (Environment Input)
```
Accepted: 1024-65535
Default: 4713

Purpose:
  - Which port PulseAudio TCP module listens on
  - Set BEFORE calling pulse_start_fixed_v2

Example:
  export PULSE_TCP_PORT=4720
  eval "$(pulse_start_fixed_v2)"
```

---

## 3. IMPROVED FEATURES IN pulse_start_fixed_v2.c

### Feature 1: Colored Output
```c
#define RED   "\033[1;31m"
#define GRN   "\033[1;32m"
#define YEL   "\033[1;33m"
#define RESET "\033[0m"

// Usage:
write_colored_msg(2, GRN, "PulseAudio ready!", 1);
```

**Benefit:** Easy visual scanning, clear status.

### Feature 2: Input Validation
```c
static int validate_int_range(int val, int min, int max) {
    return (val >= min && val <= max) ? val : min;
}

// Usage:
config.tcp_port = validate_int_range(port, TCP_PORT_MIN, TCP_PORT_MAX);
config.client_latency_ms = validate_int_range(latency, 1, 10000);
```

**Benefit:** Prevents invalid ports/latencies from reaching PulseAudio.

### Feature 3: Tmux Integration
```c
if (config.use_tmux && !tmux_session_exists()) {
    tmux_create_session();
    // Window 0: tail -f log
    // Window 1: ready for user
}
```

**Benefit:**
- Real-time log viewing without separate terminal
- Session persists across connections
- Multiple users can view logs simultaneously

**Usage:**
```bash
eval "$(pulse_start_fixed_v2)"
# In another terminal:
tmux attach -t pulse_session
# Shows PulseAudio output in real-time
```

### Feature 4: Better Error Messages
```c
write_colored_msg(2, RED, "ERROR: Cannot create log directory", 1);
write_colored_msg(2, YEL, "Check logs at: ", 0);
write_str(2, config.log_path);
```

**Benefit:** Users know exactly where to look for logs.

### Feature 5: Graceful Shutdown
```c
static void signal_handler(int sig) {
    write_colored_msg(2, RED, "Interrupted!", 1);
    cleanup_and_exit(128 + sig);
}

signal(SIGINT, signal_handler);
signal(SIGTERM, signal_handler);
```

**Benefit:** Proper resource cleanup on Ctrl+C.

---

## 4. ASSEMBLY-LEVEL NOTES (ARM64)

### Key Syscalls Used

| Syscall | Number | Purpose |
|---------|--------|---------|
| clone/fork | 220/57 | Create child process |
| execve | 221 | Replace process with new program |
| exit | 1 | Terminate process |
| wait4 | 114 | Wait for child, get status |
| setsid | 71 | New session group |
| dup2 | 33 | Duplicate file descriptor |
| open | 56 | Open file |
| close | 3 | Close file descriptor |
| nanosleep | 101 | Sleep with nanosecond precision |

### ARM64 ABI Calling Convention
```
Argument passing (first 8 args):
  x0, x1, x2, x3, x4, x5, x6, x7

Return value:
  x0 (and x1 for 128-bit results)

Caller-saved (volatile):
  x0-x11, x13-x15, sp, pc

Callee-saved (must preserve):
  x19-x30 (x31 is sp)

Stack alignment:
  16-byte boundary at function entry (pre-call)
```

### Key Instructions
```asm
svc #0          ; Supervisor call (syscall)
stp x0, x1, [sp, #0]  ; Store pair (atomic 16-byte)
ldr x0, [x1, x2, lsl #3]  ; Load with index (offset = x2 << 3)
str x0, [x1]    ; Store
cbz x0, label   ; Compare with zero, branch if zero
cmp x0, x1      ; Compare (sets flags)
b.eq label      ; Branch if equal
b.lt label      ; Branch if less than
mul x0, x1, x2  ; Multiply
div x0, x1, x2  ; Divide
msub x0, x1, x2, x3  ; Multiply-subtract: x0 = x3 - x1*x2
```

---

## 5. BUILD INSTRUCTIONS

### C Version (Fixed)
```bash
# Termux:
cd /data/data/com.termux/files/home
gcc -O2 -s -Wall -o pulse_start_fixed_v2 pulse_start_fixed_v2.c

# Or with clang:
clang -O2 -s -Wall -o pulse_start_fixed_v2 pulse_start_fixed_v2.c

# Make executable:
chmod +x pulse_start_fixed_v2
```

### Assembly Version (ARM64)
```bash
# Assemble (requires proper linking):
as -o pulse_start_arm64.o pulse_start_arm64.s

# Link (with C runtime):
gcc -o pulse_start_arm64 pulse_start_arm64.o -lc

# Note: Assembly version is PARTIAL (showing key functions only)
# Full assembly would require complete rewrite of all C logic
```

### Testing
```bash
# Test 1: Check if executable works
./pulse_start_fixed_v2

# Test 2: Check output formatting
./pulse_start_fixed_v2 2>&1 | head -20

# Test 3: Eval environment variables
eval "$(./pulse_start_fixed_v2)"
echo $PULSE_SERVER

# Test 4: Connect to PulseAudio
pactl info

# Test 5: Check tmux session (if available)
tmux list-sessions
tmux attach -t pulse_session
```

---

## 6. SUMMARY TABLE

| Issue | Original | Fixed | Impact |
|-------|----------|-------|--------|
| Memory leak | free() missing | cleanup_and_exit() | Resource cleanup |
| mkdir errors | Ignored | Checked, reported | Early error detection |
| EINTR handling | Missing | Retry loop | Signal safety |
| write() errors | Ignored | Reported | Robustness |
| Race condition | Yes | Minimal (design) | Rare case fix |
| Signal handlers | None | SIGINT/SIGTERM | Graceful shutdown |
| Colored output | None | RED/GRN/YEL | Better UX |
| Validation | None | Range checks | Prevents invalid config |
| Tmux support | None | Integrated | Real-time logs |
| Error messages | Generic | Specific paths | Better debugging |

---

## 7. FUTURE IMPROVEMENTS

1. **Lock file race prevention** - atomic file creation
2. **Config file support** - ~/.pulseaudio.rc
3. **Systemd socket activation** - if running under systemd
4. **PulseAudio monitoring** - restart if crashes
5. **Network bridging** - allow remote clients via firewall rules
6. **Audio device selection** - auto-detect speaker/mic
7. **Performance profiling** - measure latency
8. **Crash dump analysis** - parse coredumps

