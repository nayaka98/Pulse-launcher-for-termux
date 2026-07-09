// =============================================================================
// pulse_start_fixed_v2.c — BUGFIX ROUND 2 (Critical eval-safety + signal-safety)
//
// NEW FIXES IN v2 (on top of v1 pulse_start_fixed.c):
//
//   BUG #9  [CRITICAL] pactl_info_show() polluted stdout with human-readable
//           `pactl info` text. Because print_export_lines() ALSO writes to
//           stdout, running `eval "$(pulse_start_fixed)"` would try to
//           shell-execute every line of pactl's output ("Server String: ...")
//           as a COMMAND -> tons of "command not found" errors, and worse,
//           may silently break the eval entirely.
//           FIX: pactl's child stdout is now dup2'd to OUR stderr (fd 2),
//           so the user still sees `pactl info` on screen, but stdout
//           stays 100% clean for `eval`.
//
//   BUG #10 [HIGH] Signal handler called free() and exit() — NEITHER is
//           async-signal-safe. If SIGINT arrives while malloc()'s internal
//           lock is held (e.g. mid-init_child_env), calling free() from the
//           handler can deadlock the process forever (classic reentrancy bug).
//           FIX: handler now only calls write() (async-signal-safe) and
//           _exit() (async-signal-safe). No free(), no exit(), no snprintf.
//
//   BUG #11 [MEDIUM] validate_int_range() clamped BOTH out-of-range directions
//           down to `min`. Example: PULSE_LATENCY_MSEC=999999 (above max
//           10000) silently became 1ms instead of being clamped to 10000ms.
//           FIX: proper two-sided clamp (val < min -> min, val > max -> max).
//
//   BUG #12 [LOW] tmux_send_info() built a shell command string with
//           snprintf() but NEVER executed it — dead code that looked
//           functional but did nothing (silent no-op).
//           FIX: implemented properly using posix_spawn with a real argv[]
//           (no shell string interpolation needed, so no injection risk).
//
//   BUG #13 [LOW] main(int argc, char *argv[]) parameters unused ->
//           -Wextra warning noise.
//           FIX: explicit (void)argc; (void)argv;
//
//   BUG #14 [LOW] Fixed 1000ms (5x200ms) busy-wait replaced original 300ms
//           without being configurable, silently making every "cold start"
//           run ~700ms slower than v1 pretended. Made configurable via
//           PULSE_START_WAIT_MS env var, default kept at original 300ms
//           value re-justified (600ms, since real-world AAudio init is
//           frequently >300ms on slower devices) — documented, not silent.
//
// Build (Termux):
//   cc -O2 -s -o pulse_start_fixed_v2 pulse_start_fixed_v2.c
//
// Usage:
//   eval "$(pulse_start_fixed_v2)"
// =============================================================================

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <spawn.h>
#include <time.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <errno.h>
#include <signal.h>

extern char **environ;

#define DEFAULT_PREFIX       "/data/data/com.termux/files/usr"
#define DEFAULT_RUNTIME_DIR_SUFFIX "/tmp"
#define DEFAULT_HOME_DIR     "/data/data/com.termux/files/home"
#define DEVNULL_PATH         "/dev/null"

#define TCP_PORT_MIN        1024
#define TCP_PORT_MAX        65535
#define TCP_PORT_DEFAULT    4713
#define WAIT_MS_DEFAULT     600

#define RED   "\033[1;31m"
#define GRN   "\033[1;32m"
#define YEL   "\033[1;33m"
#define RESET "\033[0m"

typedef struct {
    char runtime_dir[384];
    char home_dir[384];
    char log_dir[400];
    char log_path[420];
    char tmux_session[64];
    char pulse_server_val[64];
    int  client_latency_ms;
    int  tcp_port;
    int  use_tmux;
    int  wait_ms;

    // BUG #16 FIX: resolved at runtime via $PREFIX instead of hardcoded,
    // so this works regardless of which Termux variant/app-id is installed
    // (com.termux, com.termux.nightly, F-Droid vs old Play Store builds,
    // custom $PREFIX in proot-distro setups, etc.)
    char prefix[300];
    char pactl_path[340];
    char pulseaudio_path[340];
    char pgrep_path[340];
    char tmux_path[340];
} config_t;

static config_t config = {0};
static char **child_envp = NULL;
static char env_xdg_line[420];
static char env_pulse_line[96];
static char env_lat_line[40];

// -----------------------------------------------------------------------
// UTILITY FUNCTIONS
// -----------------------------------------------------------------------

static inline void sleep_ms(int ms) {
    struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

static int mkdir_p(const char *path) {
    if (mkdir(path, 0700) == 0) return 0;
    if (errno == EEXIST) return 0;
    return -1;
}

static const char *env_or(const char *name, const char *fallback) {
    const char *v = getenv(name);
    return (v && v[0] != '\0') ? v : fallback;
}

static int env_int_or(const char *name, int fallback) {
    const char *v = getenv(name);
    if (v && v[0] != '\0') {
        char *end;
        long n = strtol(v, &end, 10);
        if (end != v && n > 0) return (int)n;
    }
    return fallback;
}

// BUG #11 FIX: proper two-sided clamp instead of collapsing to `min`
// whenever the value is out of range in EITHER direction.
static int clamp_int(int val, int min, int max) {
    if (val < min) return min;
    if (val > max) return max;
    return val;
}

static ssize_t write_str(int fd, const char *s) {
    size_t len = strlen(s);
    ssize_t off = 0, total = 0;
    while ((size_t)off < len) {
        ssize_t w = write(fd, s + off, len - (size_t)off);
        if (w < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (w == 0) break;
        off += w;
        total += w;
    }
    return total;
}

static void write_colored_msg(int fd, const char *color, const char *msg, int nl) {
    write_str(fd, color);
    write_str(fd, msg);
    write_str(fd, RESET);
    if (nl) write_str(fd, "\n");
}

static void cleanup_and_exit(int code) {
    // Safe to call free() here: this path is ONLY reached from normal
    // (non-signal-handler) control flow in main(), never from the signal
    // handler itself. See BUG #10 fix below for why the signal handler
    // must NOT call this function.
    if (child_envp != NULL) {
        free(child_envp);
        child_envp = NULL;
    }
    exit(code);
}

// -----------------------------------------------------------------------
// BUG #10 FIX: async-signal-safe signal handler.
//
// POSIX only guarantees a small set of functions are safe to call from a
// signal handler (the "async-signal-safe" list): write(), _exit(), and a
// few others. free(), exit(), snprintf(), and anything that touches
// malloc's internal arena locks are NOT on that list.
//
// The ORIGINAL v1 handler called write_colored_msg() (safe: only write())
// followed by cleanup_and_exit() -> free() + exit(). If the signal arrives
// while the main thread is inside malloc()/free() (e.g. during
// init_child_env()), the handler's free() call can try to re-lock an
// already-held internal allocator lock -> deadlock, process hangs forever
// waiting on a signal that already fired (has to be SIGKILL'd manually).
//
// FIX: the handler now does the absolute minimum: one raw write() (no
// snprintf/no strlen composition beyond what write_str already does, which
// is safe), then _exit() directly. We deliberately skip free(child_envp) —
// the OS reclaims all process memory on exit anyway, so this is not a real
// leak, just a deferred reclaim, which is the correct tradeoff here.
// -----------------------------------------------------------------------
static volatile sig_atomic_t g_last_signal = 0;

static void signal_handler(int sig) {
    g_last_signal = sig;
    // write() and _exit() are async-signal-safe; nothing else is called.
    write_str(2, "\n" RED "Interrupted, exiting." RESET "\n");
    _exit(128 + sig);
}

// -----------------------------------------------------------------------
// CONFIGURATION SETUP
// -----------------------------------------------------------------------

static int setup_config(void) {
    // BUG #16 FIX: Termux ALWAYS exports $PREFIX (e.g.
    // /data/data/com.termux/files/usr) pointing at the actual install
    // location. Using it instead of a hardcoded path means this binary
    // keeps working even on Termux variants with a different app id
    // (com.termux.nightly, F-Droid builds, custom proot-distro layouts,
    // etc.) where /data/data/com.termux/... simply does not exist.
    snprintf(config.prefix, sizeof config.prefix, "%s",
             env_or("PREFIX", DEFAULT_PREFIX));

    snprintf(config.runtime_dir, sizeof config.runtime_dir, "%s",
             env_or("XDG_RUNTIME_DIR", ""));
    if (config.runtime_dir[0] == '\0') {
        snprintf(config.runtime_dir, sizeof config.runtime_dir, "%s%s",
                 config.prefix, DEFAULT_RUNTIME_DIR_SUFFIX);
    }

    // Derive HOME fallback from $PREFIX too (standard Termux layout is
    // .../files/usr for PREFIX and .../files/home for HOME — siblings
    // under the same app data dir). Falls back to the historical hardcoded
    // path only if $PREFIX doesn't match the expected "/usr" suffix.
    char home_fallback[300];
    size_t plen = strlen(config.prefix);
    if (plen > 4 && strcmp(config.prefix + plen - 4, "/usr") == 0) {
        snprintf(home_fallback, sizeof home_fallback, "%.*s/home",
                 (int)(plen - 4), config.prefix);
    } else {
        snprintf(home_fallback, sizeof home_fallback, "%s", DEFAULT_HOME_DIR);
    }
    snprintf(config.home_dir, sizeof config.home_dir, "%s",
             env_or("HOME", home_fallback));

    // Build resolved binary paths from $PREFIX
    snprintf(config.pactl_path, sizeof config.pactl_path, "%s/bin/pactl", config.prefix);
    snprintf(config.pulseaudio_path, sizeof config.pulseaudio_path, "%s/bin/pulseaudio", config.prefix);
    snprintf(config.pgrep_path, sizeof config.pgrep_path, "%s/bin/pgrep", config.prefix);
    snprintf(config.tmux_path, sizeof config.tmux_path, "%s/bin/tmux", config.prefix);

    // BUG #16 FIX (part 2): validate the two REQUIRED binaries actually
    // exist before doing anything else. Previously, a missing binary
    // caused posix_spawn() to fail silently (rc != 0), which every caller
    // treated identically to "the command ran and exited nonzero" — so
    // the user got a generic "cannot connect" error with zero indication
    // that the real problem was a wrong/missing path.
    if (access(config.pactl_path, X_OK) != 0) {
        write_colored_msg(2, RED, "ERROR: pactl not found at: ", 0);
        write_str(2, config.pactl_path);
        write_str(2, "\n");
        write_colored_msg(2, YEL,
            "Hint: install with 'pkg install pulseaudio', or if $PREFIX is "
            "non-standard, make sure it's exported correctly.", 1);
        return -1;
    }
    if (access(config.pulseaudio_path, X_OK) != 0) {
        write_colored_msg(2, RED, "ERROR: pulseaudio not found at: ", 0);
        write_str(2, config.pulseaudio_path);
        write_str(2, "\n");
        write_colored_msg(2, YEL, "Hint: install with 'pkg install pulseaudio'.", 1);
        return -1;
    }
    if (access(config.pgrep_path, X_OK) != 0) {
        write_colored_msg(2, RED, "ERROR: pgrep not found at: ", 0);
        write_str(2, config.pgrep_path);
        write_str(2, "\n");
        write_colored_msg(2, YEL, "Hint: install with 'pkg install procps'.", 1);
        return -1;
    }
    // tmux is OPTIONAL — missing tmux should never be a hard failure.

    snprintf(config.log_dir, sizeof config.log_dir, "%s/log", config.home_dir);
    if (mkdir_p(config.log_dir) < 0) {
        write_colored_msg(2, RED, "ERROR: Cannot create log directory: ", 0);
        write_str(2, config.log_dir);
        write_str(2, "\n");
        return -1;
    }

    snprintf(config.log_path, sizeof config.log_path, "%s/pulseaudio.log", config.log_dir);

    int port = env_int_or("PULSE_TCP_PORT", TCP_PORT_DEFAULT);
    config.tcp_port = clamp_int(port, TCP_PORT_MIN, TCP_PORT_MAX);

    snprintf(config.pulse_server_val, sizeof config.pulse_server_val,
             "tcp:127.0.0.1:%d", config.tcp_port);

    int base_default = env_int_or("PULSE_AAUDIO_LATENCY_MS", 60);
    config.client_latency_ms = env_int_or("PULSE_LATENCY_MSEC", base_default);
    config.client_latency_ms = clamp_int(config.client_latency_ms, 1, 10000);

    config.wait_ms = clamp_int(env_int_or("PULSE_START_WAIT_MS", WAIT_MS_DEFAULT), 50, 5000);

    snprintf(config.tmux_session, sizeof config.tmux_session, "pulse_session");
    config.use_tmux = (access(config.tmux_path, X_OK) == 0) ? 1 : 0;

    return 0;
}

static void init_child_env(void) {
    snprintf(env_xdg_line, sizeof env_xdg_line, "XDG_RUNTIME_DIR=%s", config.runtime_dir);
    snprintf(env_pulse_line, sizeof env_pulse_line, "PULSE_SERVER=%s", config.pulse_server_val);
    snprintf(env_lat_line, sizeof env_lat_line, "PULSE_LATENCY_MSEC=%d", config.client_latency_ms);

    int n = 0;
    while (environ[n]) n++;

    child_envp = malloc((size_t)(n + 4) * sizeof(char *));
    if (child_envp == NULL) {
        write_colored_msg(2, RED, "ERROR: malloc failed for child_envp", 1);
        exit(1);
    }

    child_envp[0] = env_xdg_line;
    child_envp[1] = env_pulse_line;
    child_envp[2] = env_lat_line;
    for (int i = 0; i < n; i++) child_envp[3 + i] = environ[i];
    child_envp[3 + n] = NULL;
}

static void print_export_lines(void) {
    char lat_buf[16];
    snprintf(lat_buf, sizeof lat_buf, "%d", config.client_latency_ms);

    // stdout MUST stay clean here — this is the ONLY thing that should
    // ever be written to fd 1, so that `eval "$(pulse_start_fixed_v2)"`
    // works reliably. See BUG #9 fix in pactl_info_show().
    write_str(1, "export XDG_RUNTIME_DIR=\"");
    write_str(1, config.runtime_dir);
    write_str(1, "\"\n");
    write_str(1, "export PULSE_SERVER=\"");
    write_str(1, config.pulse_server_val);
    write_str(1, "\"\n");
    write_str(1, "export PULSE_LATENCY_MSEC=");
    write_str(1, lat_buf);
    write_str(1, "\n");
}

// -----------------------------------------------------------------------
// PROCESS MANAGEMENT
// -----------------------------------------------------------------------

static int pulseaudio_running(void) {
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, DEVNULL_PATH, O_WRONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, STDOUT_FILENO, STDERR_FILENO);

    char *argv[] = { (char *)"pgrep", (char *)"-x", (char *)"pulseaudio", NULL };
    pid_t pid;
    int rc = posix_spawn(&pid, config.pgrep_path, &fa, NULL, argv, child_envp);
    posix_spawn_file_actions_destroy(&fa);

    if (rc != 0) return 0;

    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return 0;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

// -----------------------------------------------------------------------
// BUG #9 FIX (CRITICAL): pactl's child stdout is redirected to OUR stderr
// (fd 2), instead of being inherited straight through to OUR stdout (fd 1).
//
// WHY THIS MATTERS:
//   main() always writes the `export ...` lines to fd 1 (stdout) at the
//   very end, specifically so the user can do:
//       eval "$(pulse_start_fixed_v2)"
//   For that to work, fd 1 must contain ONLY valid shell syntax.
//   The v1 code spawned `pactl info` with posix_spawn(..., NULL, ...),
//   which means the child inherits OUR fd 1 AS-IS. Since `pactl info`
//   prints human-readable lines like:
//       Server String: /data/data/.../pulse/native
//       Library Protocol Version: 35
//   ... those lines would ALSO land in the captured `$(...)` output,
//   and eval would try to run "Server" as a command, "Library" as a
//   command, etc. -> a wall of "command not found" errors, and in the
//   worst case a stray line could be interpreted as a shell command with
//   side effects.
//
// FIX: dup2 the child's stdout onto OUR stderr fd before spawning, so the
// user still SEES pactl's output on the terminal (unchanged UX), but it
// physically cannot reach fd 1 / the `eval` capture.
// -----------------------------------------------------------------------
static int pactl_info_show(void) {
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, STDERR_FILENO, STDOUT_FILENO);

    char *argv[] = { (char *)"pactl", (char *)"info", NULL };
    pid_t pid;
    int rc = posix_spawn(&pid, config.pactl_path, &fa, NULL, argv, child_envp);
    posix_spawn_file_actions_destroy(&fa);

    if (rc != 0) return 0;

    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return 0;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static int tmux_session_exists(void) {
    if (!config.use_tmux) return 0;

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, DEVNULL_PATH, O_WRONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, STDOUT_FILENO, STDERR_FILENO);

    char *argv[] = { (char *)"tmux", (char *)"has-session", (char *)"-t",
                     (char *)config.tmux_session, NULL };
    pid_t pid;
    int rc = posix_spawn(&pid, config.tmux_path, &fa, NULL, argv, child_envp);
    posix_spawn_file_actions_destroy(&fa);

    if (rc != 0) return 0;

    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return 0;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static void tmux_create_session(void) {
    if (!config.use_tmux) return;

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, DEVNULL_PATH, O_WRONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, STDOUT_FILENO, STDERR_FILENO);

    // Window 0: live log tail
    char *argv[] = {
        (char *)"tmux",
        (char *)"new-session", (char *)"-d",
        (char *)"-s", (char *)config.tmux_session,
        (char *)"-x", (char *)"160", (char *)"-y", (char *)"40",
        (char *)"-n", (char *)"pulseaudio-log",
        (char *)"tail", (char *)"-f", (char *)config.log_path,
        NULL
    };

    pid_t pid;
    if (posix_spawn(&pid, config.tmux_path, &fa, NULL, argv, child_envp) == 0) {
        int status = 0;
        while (waitpid(pid, &status, 0) < 0) {
            if (errno != EINTR) break;
        }
    }
    posix_spawn_file_actions_destroy(&fa);
    sleep_ms(100);

    // Window 1: free shell for the user (pactl, htop, whatever)
    posix_spawn_file_actions_t fa2;
    posix_spawn_file_actions_init(&fa2);
    posix_spawn_file_actions_addopen(&fa2, STDOUT_FILENO, DEVNULL_PATH, O_WRONLY, 0);
    posix_spawn_file_actions_adddup2(&fa2, STDOUT_FILENO, STDERR_FILENO);

    char win_name[80];
    snprintf(win_name, sizeof win_name, "%s:", config.tmux_session);

    char *argv2[] = {
        (char *)"tmux", (char *)"new-window",
        (char *)"-t", win_name,
        (char *)"-n", (char *)"shell",
        NULL
    };
    pid_t pid2;
    if (posix_spawn(&pid2, config.tmux_path, &fa2, NULL, argv2, child_envp) == 0) {
        int status = 0;
        while (waitpid(pid2, &status, 0) < 0) {
            if (errno != EINTR) break;
        }
    }
    posix_spawn_file_actions_destroy(&fa2);
}

// -----------------------------------------------------------------------
// BUG #12 FIX: tmux_send_info() previously built a command string with
// snprintf() and never executed it (dead code, silent no-op). Now it
// actually spawns `tmux send-keys` directly with a real argv[] (no shell
// involved, so there's no need to shell-escape `text` and no injection
// risk from special characters in it).
// -----------------------------------------------------------------------
static void tmux_send_info(const char *text) {
    if (!config.use_tmux || !tmux_session_exists()) return;

    char target[80];
    snprintf(target, sizeof target, "%s:1", config.tmux_session);

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, DEVNULL_PATH, O_WRONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, STDOUT_FILENO, STDERR_FILENO);

    char *argv[] = {
        (char *)"tmux", (char *)"send-keys",
        (char *)"-t", target,
        (char *)text, (char *)"Enter",
        NULL
    };
    pid_t pid;
    if (posix_spawn(&pid, config.tmux_path, &fa, NULL, argv, child_envp) == 0) {
        int status = 0;
        while (waitpid(pid, &status, 0) < 0) {
            if (errno != EINTR) break;
        }
    }
    posix_spawn_file_actions_destroy(&fa);
}

static pid_t start_pulseaudio(void) {
    int logfd = open(config.log_path, O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (logfd < 0) {
        write_colored_msg(2, RED, "ERROR: Cannot open log file", 1);
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(logfd);
        write_colored_msg(2, RED, "ERROR: fork() failed", 1);
        return -1;
    }

    if (pid == 0) {
        setsid();

        int devnull = open(DEVNULL_PATH, O_RDONLY);
        if (devnull >= 0) {
            dup2(devnull, STDIN_FILENO);
            if (devnull != STDIN_FILENO) close(devnull);
        }
        dup2(logfd, STDOUT_FILENO);
        dup2(logfd, STDERR_FILENO);
        if (logfd > STDERR_FILENO) close(logfd);

        char tcp_module_arg[96];
        snprintf(tcp_module_arg, sizeof tcp_module_arg,
                 "module-native-protocol-tcp auth-anonymous=1 port=%d", config.tcp_port);

        char aaudio_arg[64];
        snprintf(aaudio_arg, sizeof aaudio_arg,
                 "module-aaudio-sink latency=%d", config.client_latency_ms);

        char *argv[] = {
            (char *)"pulseaudio",
            (char *)"-n",
            (char *)"-vvv",
            (char *)"--daemonize=no",
            (char *)"--exit-idle-time=-1",
            (char *)"--disallow-exit",
            (char *)"--high-priority=yes",
            (char *)"--realtime=no",
            (char *)"-L", (char *)"module-device-restore",
            (char *)"-L", (char *)"module-stream-restore",
            (char *)"-L", (char *)"module-card-restore",
            (char *)"-L", tcp_module_arg,
            (char *)"-L", (char *)"module-default-device-restore",
            (char *)"-L", aaudio_arg,
            NULL
        };

        execve(config.pulseaudio_path, argv, child_envp);
        _exit(127);
    }

    close(logfd);
    return pid;
}

// -----------------------------------------------------------------------
// BUG #15 FIX [CRITICAL]: env vars were only printed to stdout when
// `pactl info` succeeded. If the connection test failed for ANY reason
// (wrong binary path for a non-standard Termux install, PulseAudio taking
// longer than PULSE_START_WAIT_MS to come up, port conflict, etc.), stdout
// stayed COMPLETELY EMPTY. That means `eval "$(pulse_start_fixed_v2)"`
// would set NOTHING — $PULSE_SERVER stays unset/empty with zero
// indication why, unless the user happens to also be watching stderr.
//
// This is exactly the symptom reported: "PULSE_SERVER tetap kosong" even
// after running the tool — the connection test was silently failing, and
// the (correct) config values that WOULD have been exported were thrown
// away instead of being handed to the user for their own debugging
// (e.g. running `pactl info` manually, or waiting a bit and retrying).
//
// FIX: env vars are now exported unconditionally, exactly once, right
// before the process exits — regardless of whether the connection test
// passed. The exit CODE still reflects success/failure (0 vs 1), so
// scripts checking `$?` still work correctly; only the exported variables
// are now always available.
// -----------------------------------------------------------------------
static void finish(int success) {
    print_export_lines();   // ALWAYS runs — stdout always gets the exports
    cleanup_and_exit(success ? 0 : 1);
}

// -----------------------------------------------------------------------
int main(int argc, char *argv[]) {
    (void)argc;  // BUG #13 fix: silence -Wextra unused-parameter warning
    (void)argv;

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    unsetenv("PULSE_SERVER");
    unsetenv("PULSE_LATENCY_MSEC");

    if (setup_config() < 0) {
        // No valid config at all (e.g. can't create log dir) — genuinely
        // nothing sane to export, so this remains a hard failure with no
        // export lines. This is the ONLY path that legitimately prints
        // nothing to stdout.
        cleanup_and_exit(1);
    }

    init_child_env();

    if (pulseaudio_running()) {
        write_colored_msg(2, GRN, "PulseAudio is already running", 1);

        if (pactl_info_show()) {          // stderr-only output (BUG #9 fix)
            finish(1);
        }

        write_colored_msg(2, RED,
            "ERROR: PulseAudio running but cannot connect (connection refused)", 1);
        write_colored_msg(2, YEL,
            "Exported vars below are the INTENDED config — try `pactl info` "
            "manually after eval to debug.", 1);
        finish(0);   // still export vars so user can debug manually
    }

    write_colored_msg(2, YEL, "Starting PulseAudio...", 1);

    if (config.use_tmux && !tmux_session_exists()) {
        tmux_create_session();
        write_colored_msg(2, GRN, "Tmux session created: ", 0);
        write_str(2, config.tmux_session);
        write_str(2, "\n");
        write_colored_msg(2, GRN, "Connect with: tmux attach -t ", 0);
        write_str(2, config.tmux_session);
        write_str(2, "\n");
        tmux_send_info("echo 'PulseAudio starting... use this window freely.'");
    }

    pid_t daemon_pid = start_pulseaudio();
    if (daemon_pid < 0) {
        write_colored_msg(2, RED, "ERROR: Failed to start PulseAudio", 1);
        // Even here: export the intended config. PULSE_SERVER wasn't the
        // problem, starting the daemon was — but there's no reason to
        // withhold the (still valid) exports for a fork()/open() failure.
        finish(0);
    }

    write_str(2, "Waiting for PulseAudio to initialize");
    int ticks = config.wait_ms / 100;
    if (ticks < 1) ticks = 1;
    for (int i = 0; i < ticks; i++) {
        sleep_ms(100);
        write_str(2, ".");
    }
    write_str(2, "\n");

    if (pactl_info_show()) {
        write_colored_msg(2, GRN, "PulseAudio ready!", 1);
        finish(1);
    }

    write_colored_msg(2, RED, "ERROR: PulseAudio started but failed to connect", 1);
    write_colored_msg(2, YEL, "Check logs at: ", 0);
    write_str(2, config.log_path);
    write_str(2, "\n");
    write_colored_msg(2, YEL,
        "Exported vars below are the INTENDED config — try `pactl info` "
        "manually after eval; PulseAudio may still be starting up.", 1);

    if (config.use_tmux && tmux_session_exists()) {
        write_colored_msg(2, GRN, "View logs in tmux: tmux attach -t ", 0);
        write_str(2, config.tmux_session);
        write_str(2, "\n");
    }

    finish(0);
}
