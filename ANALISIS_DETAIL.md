# ANALISIS MENDALAM pulse_start.c

## 1. HIGH-LEVEL OVERVIEW
Program utility untuk menjalankan PulseAudio di Termux/Android dengan mode TCP networking.

**Flow:**
1. Unset PULSE_SERVER/PULSE_LATENCY_MSEC (environment warisan)
2. Setup paths & parse config dari env
3. Check: apakah pulseaudio sudah jalan? (via `pgrep -x`)
4. JIKA sudah jalan → test `pactl info`, print exports
5. JIKA belum → start pulseaudio (fork+setsid+execve), tunggu 300ms, test pactl

---

## 2. ARCHITECTURE & DATA STRUCTURES

### Global State (Static)
```
runtime_dir[384]         // XDG_RUNTIME_DIR atau /data/data/.../usr/tmp
home_dir[384]            // HOME atau /data/data/.../home
log_dir[400]             // home_dir + "/log"
log_path[420]            // log_dir + "/pulseaudio.pa"
pulse_server_val[64]     // "tcp:127.0.0.1:<port>"
client_latency_ms        // int, dari env PULSE_LATENCY_MSEC
tcp_port                 // int, dari env PULSE_TCP_PORT (default 4713)

child_envp               // char** → environment array untuk child process
env_xdg_line[420]        // "XDG_RUNTIME_DIR=..." (static buffer)
env_pulse_line[96]       // "PULSE_SERVER=..." (static buffer)
env_lat_line[40]         // "PULSE_LATENCY_MSEC=..." (static buffer)
```

### Memory Model
- **Stack**: Function local vars (argv[], status, fd, etc.)
- **Static BSS**: Global arrays (pre-zeroed, safe)
- **Heap**: child_envp (malloc'd once, NEVER freed ← LEAK)
- **Data Segment**: String literals, ANSI codes

---

## 3. EXECUTION FLOW

### main()
```
1. unsetenv("PULSE_SERVER", "PULSE_LATENCY_MSEC")
   ├─ Buang inherited env vars
   └─ Ini PENTING: kalau PulseAudio lama masih jalan, pactl bisa
      connect ke socket port lama yang sudah mati

2. setup_paths()
   ├─ Read env: XDG_RUNTIME_DIR, HOME, PULSE_TCP_PORT
   ├─ mkdir_p(log_dir) - TANPA ERROR CHECK ← BUG
   └─ Construct pulse_server_val = "tcp:127.0.0.1:PORT"

3. parse_latency()
   └─ Read env: PULSE_LATENCY_MSEC, default PULSE_AAUDIO_LATENCY_MS=60

4. init_child_env()
   ├─ Allocate child_envp = malloc(sizeof(char*) * (n+4))
   │  dimana n = count(environ)
   ├─ Copy custom vars + inherit environ
   ├─ Leak: child_envp NEVER freed ← MEMORY LEAK
   └─ Strategy: custom vars di [0..2], inherited di [3..3+n-1]

5. if (pulseaudio_process_running())  [via pgrep]
   ├─ YES → if (pactl_info_show())
   │         ├─ SUCCESS → print_export_lines(), return 0
   │         └─ FAIL → error RED, return 1
   │
   └─ NO → pid_t pid = start_pulseaudio()
           ├─ fork() → child: setsid(), dup2(logfile), execve(pulseaudio)
           ├─ parent: sleep_ms(300)
           ├─ if (pactl_info_show())
           │   ├─ SUCCESS → print_export_lines(), return 0
           │   └─ FAIL → error RED + log path, return 1
           └─ RACE CONDITION: antara pgrep & start, proc lain bisa start PA
```

### Fungsi Kritis

#### pulseaudio_process_running()
```
posix_spawn(pgrep -x pulseaudio, redirect stdout/stderr to /dev/null)
→ waitpid()
→ return (WIFEXITED && WEXITSTATUS == 0)
```
**Issues:**
- Tidak handle EINTR pada waitpid() ← rare but could hang
- Race window sebelum start_pulseaudio()

#### pactl_info_show()
```
posix_spawn(pactl info, no file_actions → inherit parent's fd)
→ waitpid()
→ return WEXITSTATUS == 0
```
**Output langsung ke terminal**, bukan /dev/null ✓

#### start_pulseaudio()
```
pid = fork()

CHILD (pid == 0):
  1. setsid()            → new session group (detach dari parent)
  2. open(log_path)      → logfd
  3. dup2(devnull, 0)    → stdin = /dev/null
  4. dup2(logfd, 1)      → stdout = logfile
  5. dup2(logfd, 2)      → stderr = logfile
  6. snprintf(tcp_module_arg) ← buffer overflow risk!
  7. snprintf(aaudio_arg)     ← buffer overflow risk!
  8. execve(pulseaudio, argv, child_envp)
  9. _exit(127) [if execve fails]

PARENT (pid > 0):
  close(logfd)
  return pid
```

**Buffer Issues di child:**
```c
char tcp_module_arg[96];
snprintf(tcp_module_arg, 96,
         "module-native-protocol-tcp auth-anonymous=1 port=%d", tcp_port);

Worst case (tcp_port = 65535):
  "module-native-protocol-tcp auth-anonymous=1 port=65535"
  = 56 chars ✓ safe (fits in 96)

char aaudio_arg[64];
snprintf(aaudio_arg, 64,
         "module-aaudio-sink latency=%d", client_latency_ms);

Worst case (latency_ms = 2147483647):
  "module-aaudio-sink latency=2147483647"
  = 38 chars ✓ safe (fits in 64)
```

Buffer sizes ARE adequate untuk expected values, tapi tidak future-proof.

---

## 4. BUG INVENTORY

### CRITICAL BUGS

#### BUG #1: Memory Leak (child_envp)
```c
// Line 137: malloc dalam init_child_env()
child_envp = malloc((size_t)(n + 4) * sizeof(char *));

// NEVER freed. Program exits, OS reclaims, tapi termasuk memory leak category.
// Fix: atexit() atau free() sebelum return di main()
```

#### BUG #2: mkdir_p() Error Ignored
```c
// Line 115: mkdir tanpa check return value
static inline void mkdir_p(const char *path) {
    mkdir(path, 0700);  // Ignore EEXIST, EACCES, EROFS, etc.
}
```
Kalau `/data/data/.../home/log` tidak bisa dibuat (permission, disk full):
- snprintf(log_path) tetap berjalan
- start_pulseaudio() akan gagal open(log_path)
- Error message kurang jelas

#### BUG #3: Race Condition (pgrep → start)
```
Time T1: pgrep -x pulseaudio → return 1 (not running)
Time T2: [WINDOW] Another process starts pulseaudio
Time T3: start_pulseaudio() → attempt fork/execve, bisa conflict
Time T4: sleep_ms(300), pactl_info_show()
```
Mitigasi: minimal, karena Termux single-user. Tapi technically unsafe.

#### BUG #4: EINTR Not Handled
```c
// Line 174: waitpid() bisa return -1 dengan errno=EINTR
int status = 0;
waitpid(pid, &status, 0);  // Signal interrupt?
return WIFEXITED(status) && WEXITSTATUS(status) == 0;
```
Kalau signal datang selama waitpid(), function bisa return 0 (false negative).

#### BUG #5: Buffer Overflow Risk (env_xdg_line)
```c
// Line 130: snprintf ke env_xdg_line[420]
snprintf(env_xdg_line, sizeof env_xdg_line, "XDG_RUNTIME_DIR=%s", runtime_dir);
// runtime_dir[384] → max snprintf output = 19 + 384 = 403 chars
// Buffer 420 is adequate, but TIGHT. No validation on runtime_dir content.
```

#### BUG #6: write_red_err() Doesn't Check write() Returns
```c
// Line 103-106: write() bisa return 0 atau -1
static void write_red_err(const char *msg) {
    write_str(2, RED);      // write_str() ignores write() failures
    write_str(2, msg);
    write_str(2, RESET "\n");
}
```
Kalau stderr penuh/closed → silent failure.

#### BUG #7: PULSE_SERVER Not Actually Set in Current Shell
```c
// print_export_lines() outputs:
// export XDG_RUNTIME_DIR=...
// export PULSE_SERVER=...
// Tapi ini STDOUT → caller harus eval!
```
Users bisa lupa eval, tapi ini design intention jadi tidak bug sebenarnya.

#### BUG #8: No Signal Handler for Cleanup
```c
// Kalau pulse_start diterima SIGKILL:
// - fork() child pulseaudio tetap jalan (good)
// - tapi tidak ada graceful shutdown handler
// - Jika start_pulseaudio() returns, parent don't track child
```
Not a critical bug untuk use-case ini, tapi good practice.

---

## 5. ENVIRONMENT VARIABLE HANDLING ISSUES

### Issue #1: Exported Vars Not in Parent Shell
```c
// main() unsets:
unsetenv("PULSE_SERVER");
unsetenv("PULSE_LATENCY_MSEC");

// setup builds:
child_envp[1] = "PULSE_SERVER=tcp:127.0.0.1:4713"
child_envp[2] = "PULSE_LATENCY_MSEC=60"

// Tapi hanya untuk CHILD processes.
// Parent shell (caller) masih tidak tau PULSE_SERVER!
// 
// FIX: print_export_lines() diminta user untuk eval()
//      eval "$(pulse_start)"
```

### Issue #2: XDG_RUNTIME_DIR Validation Missing
```c
// Tidak ada check apakah XDG_RUNTIME_DIR accessible/writable
// Kalau corrupted permissions → silent fail di execve
```

### Issue #3: PULSE_LATENCY_MSEC Not In Parent
```c
// Client programs yang dijalankan parent process tidak akan
// inherit PULSE_LATENCY_MSEC kecuali parent shell eval exports
```

---

## 6. SECURITY ISSUES

### Low Priority
1. **Path Traversal**: Hard-coded paths, aman
2. **Buffer Overflow**: Mitigated oleh snprintf, tapi tight margins
3. **Privilege Escalation**: None (single-user Termux)
4. **Command Injection**: argv[] hard-coded, aman
5. **Log File Permissions**: 0644 (world-readable) → INFORMATIONAL

### Medium Priority
1. **Unvalidated env vars**: PULSE_TCP_PORT, XDG_RUNTIME_DIR tidak di-sanitize
   - Fix: Add range checks & path validation

---

## 7. PERFORMANCE ANALYSIS

### Timing Breakdown (Normal Case - Pulseaudio Already Running)
```
1. unsetenv():           < 0.1ms
2. setup_paths():        < 0.5ms (getenv, snprintf)
3. parse_latency():      < 0.2ms
4. init_child_env():     < 1ms (malloc + copy)
5. pgrep (posix_spawn):  15-50ms (spawn + wait)
6. pactl info (if yes):  20-100ms (spawn + wait)
7. print_export_lines(): < 0.5ms

Total BEST CASE:  ~40ms
Total WORST CASE: ~160ms
```

### Timing Breakdown (Start New - Pulseaudio Not Running)
```
1-4. Same setup:         ~2ms
5. pgrep (not running):  ~30ms
6. start_pulseaudio():   ~5ms (fork + dup2 + execve)
7. sleep_ms(300):        300ms
8. pactl info:           20-100ms
9. print_export_lines(): ~0.5ms

Total BEST CASE:  ~360ms
Total WORST CASE: ~440ms
```

**Bottleneck utama: 300ms sleep + posix_spawn latency**

---

## 8. ASSEMBLY-LEVEL BEHAVIOR (ARM64/aarch64)

### Key Functions Breakdown

#### init_child_env() Assembly Concept
```asm
; Pseudocode equivalent
; rdi = pointer to environ (x8 for arm64)

init_child_env:
    ; Count environ entries
    mov     x9, x8          ; x8 = environ
    mov     x10, #0
.count_loop:
    ldr     x11, [x9, x10, lsl #3]  ; Load environ[i]
    cbz     x11, .count_done        ; If NULL, done
    add     x10, x10, #1            ; ++i
    b       .count_loop
.count_done:
    ; Now x10 = count (n)
    ; malloc((n+4)*sizeof(char*))
    add     x0, x10, #4     ; x0 = n+4
    mov     x1, #8          ; size per pointer (64-bit)
    mul     x0, x0, x1      ; x0 = (n+4)*8
    bl      malloc          ; x0 = pointer to allocated mem
    
    ; child_envp[0] = env_xdg_line
    adrp    x1, env_xdg_line        ; Load address
    add     x1, x1, :lo12:env_xdg_line
    str     x1, [x0]        ; Store at [child_envp+0]
    
    ; child_envp[1] = env_pulse_line
    adrp    x2, env_pulse_line
    add     x2, x2, :lo12:env_pulse_line
    str     x2, [x0, #8]    ; Store at [child_envp+8]
    
    ; child_envp[2] = env_lat_line
    adrp    x3, env_lat_line
    add     x3, x3, :lo12:env_lat_line
    str     x3, [x0, #16]   ; Store at [child_envp+16]
    
    ; Copy inherited environ (offset by 24 bytes = 3 pointers)
    mov     x4, #0          ; i = 0
.copy_loop:
    cmp     x4, x10         ; i < n ?
    b.ge    .copy_done
    ldr     x5, [x8, x4, lsl #3]   ; Load environ[i]
    str     x5, [x0, #24], x4, lsl #3   ; Store at [child_envp+3+i]
    add     x4, x4, #1
    b       .copy_loop
.copy_done:
    ; child_envp[3+n] = NULL
    str     xzr, [x0, #24], x10, lsl #3  ; Store 0
    ret
```

#### start_pulseaudio() Assembly Concept
```asm
start_pulseaudio:
    ; Fork
    mov     x0, #SYS_fork
    svc     #0              ; syscall fork()
    cbz     x0, .child      ; x0 == 0 → child
    ; Parent: close logfd, return pid
    mov     x1, x0          ; Save pid
    mov     x0, x19         ; logfd (if cached in x19)
    mov     x0, #SYS_close
    svc     #0
    mov     x0, x1          ; Return pid
    ret
    
.child:
    ; Child process
    mov     x0, #SYS_setsid
    svc     #0              ; setsid()
    
    ; open /dev/null
    adrp    x0, devnull_str
    add     x0, x0, :lo12:devnull_str
    mov     x1, #O_RDONLY
    mov     x0, #SYS_openat
    svc     #0              ; fd = open("/dev/null")
    
    ; dup2(devnull, STDIN_FILENO)
    mov     x1, #0          ; STDIN
    mov     x0, #SYS_dup2
    svc     #0
    
    ; dup2(logfd, STDOUT_FILENO)
    mov     x0, x19         ; logfd (saved)
    mov     x1, #1          ; STDOUT
    mov     x0, #SYS_dup2
    svc     #0
    
    ; dup2(logfd, STDERR_FILENO)
    mov     x0, x19
    mov     x1, #2          ; STDERR
    mov     x0, #SYS_dup2
    svc     #0
    
    ; execve(PULSEAUDIO_PATH, argv, envp)
    adrp    x0, pulseaudio_path
    add     x0, x0, :lo12:pulseaudio_path
    adrp    x1, argv_array
    add     x1, x1, :lo12:argv_array
    adrp    x2, child_envp
    add     x2, x2, :lo12:child_envp
    mov     x0, #SYS_execve
    svc     #0
    
    ; If execve fails:
    mov     x0, #127
    mov     x0, #SYS_exit
    svc     #0
```

### Fork/Exec Semantics at ABI Level
- **fork()**: new process context, all parent memory copied
- **execve()**: replace text+data segments, heap/stack reallocated
- **setsid()**: new session leader (detach from terminal)
- **Signal handlers**: reset in child after fork() (safely ignored in case execve)

---

## 9. IMPROVEMENTS NEEDED

1. **FREE child_envp** ← Critical
2. **Handle mkdir_p() errors** ← Important
3. **Retry waitpid() on EINTR** ← Important
4. **Validate environment variables** ← Important
5. **Add signal handlers** ← Nice-to-have
6. **Integrate with tmux for logging** ← User request
7. **Better error messages** ← UX improvement

---

## 10. SUMMARY TABLE

| Issue | Severity | Type | Fixed? |
|-------|----------|------|--------|
| Memory leak (child_envp) | HIGH | Resource | No |
| mkdir_p error ignored | HIGH | Logic | No |
| EINTR not handled | MEDIUM | Concurrency | No |
| write() errors ignored | MEDIUM | Robustness | No |
| Buffer overflow risk | LOW | Safety | Mitigated |
| Race condition | LOW | Concurrency | Design |
| No signal handlers | LOW | Robustness | Design |
| Env vars not exported to parent | MEDIUM | Design | Intentional |

