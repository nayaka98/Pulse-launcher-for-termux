// =============================================================================
// pulse_start_arm64.s — ARM64 (aarch64) Assembly Implementation
//
// TARGET: Android/Termux on ARM64-v8 (Snapdragon, MediaTek, Exynos ARM)
// 
// NOTES:
//   - Full assembly too large; showing KEY FUNCTIONS + CONCEPTS
//   - Calling convention: ARM64 EABI (x0-x7 args, x0 return, x8-x11 scratch)
//   - Stack alignment: 16-byte boundary at function entry (pre-call)
//   - Registers: x0-x30 general, sp/x31, pc
//   - Syscall: svc #0 (exception to EL1)
//
// SYSCALL NUMBERS (arm64-linux):
//   #1   - exit
//   #2   - fork
//   #3   - read
//   #4   - write
//   #5   - open
//   #20  - writev
//   #21  - access
//   #33  - dup2
//   #39  - mkdir
//   #40  - chdir
//   #41  - chmod
//   #56  - clone
//   #57  - fork (modern)
//   #71  - setsid
//   #78  - clone
//   #79  - uname
//   #85  - readlink
//   #114 - wait4
//   #221 - execve
//   #226 - mmap
//   #215 - munmap
//   #267 - getrlimit
//   #281 - nanosleep
//
// =============================================================================

    .text
    .align  4

// -----------------------------------------------------------------------
// FUNCTION: sleep_ms(int ms)
// INPUT:  x0 = milliseconds
// OUTPUT: none (void)
// USES: x0, x1, x2, sp (16-byte aligned)
// -----------------------------------------------------------------------
    .globl sleep_ms
    .type  sleep_ms, @function
sleep_ms:
    // Prologue: push x29, x30 (frame pointer + return address)
    sub     sp, sp, #32           // Allocate 32 bytes on stack (16-aligned)
    stp     x29, x30, [sp, #0]    // Save FP + LR
    mov     x29, sp               // FP = SP

    // Convert ms to nanoseconds: ns = ms * 1_000_000
    // Input x0 = milliseconds
    mov     x1, #1000000          // Multiplier for conversion
    mul     x1, x0, x1            // x1 = ms * 1_000_000 (nanoseconds)

    // Store timespec structure on stack:
    //   struct timespec {
    //       time_t tv_sec;       // 8 bytes
    //       long tv_nsec;        // 8 bytes
    //   };
    // tv_sec = ns / 1_000_000_000
    // tv_nsec = ns % 1_000_000_000

    mov     x0, #1000000000       // Nanoseconds per second
    div     x2, x1, x0            // x2 = tv_sec
    msub    x3, x2, x0, x1        // x3 = ns - (sec * 1e9) = tv_nsec

    // Store in stack:
    stp     x2, x3, [sp, #16]     // timespec at sp+16

    // nanosleep(&ts, NULL)
    // ARM64 ABI: x0=ts, x1=rem
    add     x0, sp, #16           // x0 = &timespec
    mov     x1, #0                // x1 = NULL (rem)
    mov     x8, #101              // Syscall nanosleep
    svc     #0

    // Epilogue
    ldp     x29, x30, [sp, #0]
    add     sp, sp, #32
    ret
    .size sleep_ms, .-sleep_ms


// -----------------------------------------------------------------------
// FUNCTION: init_child_env()
// CONCEPT: Build child_envp array, malloc + copy environ
// 
// KEY STEPS:
//   1. Count environ entries
//   2. malloc((n+4) * sizeof(char*))
//   3. Copy custom vars [0..2]
//   4. Copy environ [3..3+n-1]
//   5. Null terminate
//
// REGISTERS:
//   x0  = return val (child_envp pointer)
//   x8  = environ base address
//   x9  = loop counter (environ)
//   x10 = count (n)
//   x11 = temporary
// -----------------------------------------------------------------------
    .globl init_child_env
    .type  init_child_env, @function
init_child_env:
    // Prologue: preserve callee-saved regs
    sub     sp, sp, #48
    stp     x29, x30, [sp, #0]
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    mov     x29, sp

    // Load environ base address (from GOT or PC-relative)
    adrp    x8, :got:environ
    ldr     x8, [x8, :got_lo12:environ]
    ldr     x8, [x8]              // x8 = &environ[0]

    // COUNT: loop until environ[n] == NULL
    mov     x10, #0               // n = 0
.count_loop:
    ldr     x11, [x8, x10, lsl #3]  // Load environ[n]
    cbz     x11, .count_done       // If NULL, exit loop
    add     x10, x10, #1           // n++
    b       .count_loop

.count_done:
    // Now x10 = count
    // Allocate: malloc((n+4) * sizeof(char*)) = (n+4)*8 bytes
    add     x0, x10, #4           // x0 = n+4
    mov     x1, #8                // sizeof(char*)
    mul     x0, x0, x1            // x0 = (n+4)*8

    // Call malloc(size)
    bl      malloc                // x0 = allocated pointer

    mov     x19, x0               // x19 = child_envp (save across calls)
    mov     x20, x10              // x20 = n (save count)

    // COPY: custom vars [0..2]
    // child_envp[0] = env_xdg_line
    adrp    x0, env_xdg_line
    add     x0, x0, :lo12:env_xdg_line
    str     x0, [x19, #0]         // child_envp[0] = &env_xdg_line

    // child_envp[1] = env_pulse_line
    adrp    x0, env_pulse_line
    add     x0, x0, :lo12:env_pulse_line
    str     x0, [x19, #8]         // child_envp[1]

    // child_envp[2] = env_lat_line
    adrp    x0, env_lat_line
    add     x0, x0, :lo12:env_lat_line
    str     x0, [x19, #16]        // child_envp[2]

    // COPY: inherited environ [3..3+n-1]
    mov     x21, #0               // i = 0
    ldr     x22, [x8]             // x22 = environ base (for loop)
.copy_loop:
    cmp     x21, x20              // i < n ?
    b.ge    .copy_done
    ldr     x0, [x22, x21, lsl #3] // Load environ[i]
    str     x0, [x19, #24], x21, lsl #3  // Store child_envp[3+i]
    add     x21, x21, #1
    b       .copy_loop

.copy_done:
    // NULL-terminate: child_envp[3+n] = NULL
    add     x0, x19, #24
    add     x0, x0, x20, lsl #3   // x0 = &child_envp[3+n]
    str     xzr, [x0]             // Store NULL

    // Update global child_envp pointer
    adrp    x0, child_envp
    add     x0, x0, :lo12:child_envp
    str     x19, [x0]             // child_envp = allocated buffer

    // Return x19 (child_envp)
    mov     x0, x19

    // Epilogue
    ldp     x29, x30, [sp, #0]
    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    add     sp, sp, #48
    ret
    .size init_child_env, .-init_child_env


// -----------------------------------------------------------------------
// FUNCTION: pulseaudio_running()
// EXECUTES: posix_spawn(pgrep -x pulseaudio) + waitpid
// RETURNS: 1 if running, 0 if not
//
// KEY SYSCALL: waitpid(pid, &status, flags)
//   x0 = pid
//   x1 = &status
//   x2 = flags
//   svc #114 = wait4 (arm64 equivalent)
// -----------------------------------------------------------------------
    .globl pulseaudio_running
    .type  pulseaudio_running, @function
pulseaudio_running:
    sub     sp, sp, #48
    stp     x29, x30, [sp, #0]
    stp     x19, x20, [sp, #16]
    mov     x29, sp

    // posix_spawn_file_actions_init(&fa)
    // ... (C library call)
    
    // posix_spawn(&pid, "/path/to/pgrep", &fa, NULL, argv, envp)
    // ... (C library call, x0 = pid after spawn)
    
    mov     x19, x0               // x19 = child pid
    mov     x20, #0               // x20 = status (uninitialized OK)

    // waitpid(pid, &status, 0)
    mov     x0, x19               // x0 = pid
    add     x1, sp, #32           // x1 = &status (on stack)
    mov     x2, #0                // x2 = flags (WNOHANG=0, blocking)
    mov     x8, #114              // Syscall wait4
    svc     #0

    // Check return value of waitpid
    cmp     x0, #0
    b.le    .wait_error           // if (rc <= 0) error

    // Load status
    ldr     x0, [sp, #32]

    // WIFEXITED(status) = ((status & 0xFF) == 0)
    and     x1, x0, #0xFF
    cbnz    x1, .exit_false       // if not zero, not normal exit

    // WEXITSTATUS(status) = ((status >> 8) & 0xFF)
    lsr     x0, x0, #8
    and     x0, x0, #0xFF         // Extract exit code

    // Return 1 if exit code == 0, else 0
    cmp     x0, #0
    b.eq    .exit_true
    mov     x0, #0
    b       .exit_done

.exit_true:
    mov     x0, #1
    b       .exit_done

.exit_false:
.wait_error:
    mov     x0, #0

.exit_done:
    ldp     x29, x30, [sp, #0]
    ldp     x19, x20, [sp, #16]
    add     sp, sp, #48
    ret
    .size pulseaudio_running, .-pulseaudio_running


// -----------------------------------------------------------------------
// FUNCTION: start_pulseaudio()
// LOW-LEVEL FORK+SETSID+EXECVE
//
// SYSCALL SEQUENCE:
//   1. open(log_path) → logfd
//   2. fork()
//      ├─ Child (pid==0):  setsid + dup2 + execve
//      └─ Parent (pid>0):  return pid
// -----------------------------------------------------------------------
    .globl start_pulseaudio
    .type  start_pulseaudio, @function
start_pulseaudio:
    sub     sp, sp, #64
    stp     x29, x30, [sp, #0]
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    mov     x29, sp

    // STEP 1: open(log_path, O_CREAT | O_WRONLY | O_APPEND, 0644)
    adrp    x0, log_path
    add     x0, x0, :lo12:log_path
    mov     x1, #0x642           // O_CREAT(0x40) | O_WRONLY(0x1) | O_APPEND(0x400)
    mov     x2, #0644            // mode
    mov     x8, #56              // Syscall openat (newer) or open
    svc     #0

    cmp     x0, #0
    b.lt    .open_failed
    mov     x19, x0              // x19 = logfd

    // STEP 2: fork()
    mov     x8, #220             // Syscall clone (ARM64 fork equivalent)
    // Actually use raw fork if available: mov x8, #57  (SYS_clone)
    svc     #0

    cmp     x0, #0
    b.lt    .fork_failed         // fork error
    b.eq    .fork_child          // x0==0 → child process

    // PARENT PROCESS
    // Close logfd, return pid
    mov     x1, x0               // x1 = child pid
    mov     x0, x19              // x0 = logfd
    mov     x8, #3               // Syscall close
    svc     #0
    
    mov     x0, x1               // Return child pid
    b       .exit_func

.fork_child:
    // CHILD PROCESS: x19 = logfd

    // setsid() → create new session
    mov     x8, #71              // Syscall setsid
    svc     #0
    // Ignore result

    // open(/dev/null, O_RDONLY)
    adrp    x0, devnull_str
    add     x0, x0, :lo12:devnull_str
    mov     x1, #0               // O_RDONLY
    mov     x8, #56              // openat
    svc     #0
    cmp     x0, #0
    b.lt    .child_skip_devnull
    mov     x20, x0              // x20 = devnull fd

    // dup2(devnull, STDIN_FILENO=0)
    mov     x0, x20              // oldfd
    mov     x1, #0               // newfd (stdin)
    mov     x8, #33              // dup2
    svc     #0
    
    // Close devnull if > STDIN
    cmp     x20, #0
    b.le    .child_skip_devnull
    mov     x0, x20
    mov     x8, #3               // close
    svc     #0

.child_skip_devnull:
    // dup2(logfd, STDOUT_FILENO=1)
    mov     x0, x19              // logfd
    mov     x1, #1               // STDOUT
    mov     x8, #33              // dup2
    svc     #0

    // dup2(logfd, STDERR_FILENO=2)
    mov     x0, x19
    mov     x1, #2               // STDERR
    mov     x8, #33              // dup2
    svc     #0

    // Close logfd if > STDERR
    cmp     x19, #2
    b.le    .child_skip_close
    mov     x0, x19
    mov     x8, #3
    svc     #0

.child_skip_close:
    // Now execve(PULSEAUDIO_PATH, argv, child_envp)
    adrp    x0, pulseaudio_path
    add     x0, x0, :lo12:pulseaudio_path
    
    // x1 = argv (array of pointers to args)
    adrp    x1, argv_array
    add     x1, x1, :lo12:argv_array
    
    // x2 = envp (child_envp)
    adrp    x2, child_envp
    add     x2, x2, :lo12:child_envp
    ldr     x2, [x2]             // Dereference child_envp
    
    mov     x8, #221             // Syscall execve
    svc     #0
    
    // If execve failed, exit with code 127
    mov     x0, #127
    mov     x8, #1               // Syscall exit
    svc     #0

.fork_failed:
    mov     x0, #-1
    b       .exit_func

.open_failed:
    mov     x0, #-1

.exit_func:
    ldp     x29, x30, [sp, #0]
    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    add     sp, sp, #64
    ret
    .size start_pulseaudio, .-start_pulseaudio


// -----------------------------------------------------------------------
// DATA SECTION
// -----------------------------------------------------------------------
    .data
    .align  8

    .globl child_envp
child_envp:
    .quad   0                     // Pointer to allocated env array

    .globl env_xdg_line
env_xdg_line:
    .space  420                   // Static buffer

    .globl env_pulse_line
env_pulse_line:
    .space  96

    .globl env_lat_line
env_lat_line:
    .space  40

devnull_str:
    .asciz  "/dev/null"

pulseaudio_path:
    .asciz  "/data/data/com.termux/files/usr/bin/pulseaudio"

argv_array:
    // Array of string pointers for execve
    .quad   pulse_cmd           // argv[0] = "pulseaudio"
    .quad   arg_n                // argv[1] = "-n"
    .quad   arg_vvv              // argv[2] = "-vvv"
    .quad   0                     // argv[3] = NULL (terminator)

pulse_cmd:
    .asciz  "pulseaudio"
arg_n:
    .asciz  "-n"
arg_vvv:
    .asciz  "-vvv"

// -----------------------------------------------------------------------
// END OF ASSEMBLY
// =============================================================================
