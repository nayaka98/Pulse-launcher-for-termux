# pulse_start_fixed_v2

A hardened, bug-fixed PulseAudio startup utility for Termux/Android — with
automatic tmux integration for real-time log viewing.

![Showcase](showcase.gif)


---

## What This Is

`pulse_start_fixed_v2.c` replaces a fragile, bug-riddled PulseAudio startup
script with a single, dependency-free C binary that:

- Detects whether PulseAudio is already running (via `pgrep`)
- Starts it cleanly if not (fork + `setsid` + `execve`, detached, logged)
- Verifies the connection with `pactl info`
- Prints `export PULSE_SERVER=...` lines you can `eval` into your shell
- Optionally creates a **tmux session** with a live log window, so you can
  watch PulseAudio's output in real time without a second terminal app
- Resolves all binary paths dynamically via `$PREFIX`, so it works across
  different Termux variants (not just the stock `com.termux` install)

16 bugs were found and fixed across three review rounds — see
[`CHANGELOG.md`](CHANGELOG.md) for the full list with before/after code.

---

## Quick Start

```bash
# 1. Build (Termux ships clang by default, not gcc)
clang -O2 -s -Wall -Wextra -o pulse_start_fixed_v2 pulse_start_fixed_v2.c

# 2. Run it and load the exported env vars into your current shell
eval "$(./pulse_start_fixed_v2)"

# 3. Verify
pactl info
```

### With tmux (real-time logs)

```bash
pkg install tmux   # if not already installed
eval "$(./pulse_start_fixed_v2)"
tmux attach -t pulse_session
```

- **Window 0** (`pulseaudio-log`) — live `tail -f` of the PulseAudio log
- **Window 1** (`shell`) — a free shell for your own commands

---

## Persisting It: `.bashrc` Integration

**Don't hardcode static `export PULSE_SERVER=...` lines into `.bashrc`.**
That value goes stale the moment PulseAudio restarts on a different port,
or if PulseAudio isn't reachable yet — with zero indication anything is
wrong.

Instead, use the provided installer, which re-runs the tool via `eval` on
every new shell so the exported values are always freshly validated:

```bash
clang -O2 -s -o pulse_start_fixed_v2 pulse_start_fixed_v2.c
bash install_bashrc_hook.sh
```

What it does:
- Copies the binary to `~/bin/`
- Adds **one** idempotent, marker-guarded block to `~/.bashrc`
- Redirects startup messages to `~/log/pulse_start_hook.log` instead of
  printing on every new terminal tab
- Respects `PULSE_START_SKIP=1` to skip the hook for a single shell
- Safe to re-run (replaces the existing block instead of duplicating it)

```bash
# Skip it for one shell (e.g. inside a script, or when you don't need audio):
PULSE_START_SKIP=1 bash

# Remove the hook entirely:
bash install_bashrc_hook.sh --remove
```

**Trade-off:** every new terminal takes roughly 100–500ms longer to start,
since the detection/start logic runs once per shell. If that's not
acceptable, skip the hook and just run `eval "$(pulse_start_fixed_v2)"`
manually when you need audio.

---

## Environment Variables

| Variable | Purpose | Default |
|---|---|---|
| `PULSE_TCP_PORT` | TCP port for PulseAudio's native protocol module | `4713` |
| `PULSE_LATENCY_MSEC` | Client-side latency target (1–10000ms) | `60` |
| `PULSE_AAUDIO_LATENCY_MS` | Fallback default for the above | `60` |
| `PULSE_START_WAIT_MS` | How long to wait after starting PulseAudio before testing the connection (50–5000ms) | `600` |
| `XDG_RUNTIME_DIR` | Runtime socket/lock directory | `$PREFIX/tmp` |
| `PREFIX` | Termux install prefix (set automatically by Termux) | — |

Set any of these **before** running the tool:

```bash
export PULSE_TCP_PORT=4720
export PULSE_LATENCY_MSEC=100
eval "$(./pulse_start_fixed_v2)"
```

---

## Files in This Package

| File | Purpose |
|---|---|
| `pulse_start_fixed_v2.c` | The tool itself — build and use this |
| `install_bashrc_hook.sh` | Safe, idempotent `.bashrc` installer (see above) |
| `BUILD_AND_USE.sh` | Interactive build/test/install helper script |
| `pulse_start_arm64.s` | Annotated ARM64 assembly reference (educational) |
| `CHANGELOG.md` | All 16 bugs found & fixed, with before/after code |
| `ANALISIS_DETAIL.md` | Deep technical analysis (architecture, memory model, syscalls) |
| `BUGFIX_GUIDE.md` | Bug-by-bug explanations |
| `QUICK_REFERENCE.md` | Troubleshooting & cheat sheet |
| `VISUAL_GUIDE.md` | Flowcharts and diagrams |
| `CLANG_BUILD_NOTES.md` | Notes on building cleanly with `clang` (0 warnings) |
| `SUMMARY.txt` | Plain-text project overview |
| `img/` | Showcase GIF + instructions for recording a real one |

> Older documentation files still reference a "v1" for historical bug
> comparison purposes (what was broken, what changed). The actual v1
> source file has been removed from this package — **`pulse_start_fixed_v2.c`
> is the only version you need.**

---

## Building

```bash
# Recommended (Termux default compiler)
clang -O2 -s -Wall -Wextra -o pulse_start_fixed_v2 pulse_start_fixed_v2.c

# Verify zero warnings
clang -O2 -Wall -Wextra -Wpedantic -c pulse_start_fixed_v2.c -o /tmp/check.o
echo "Exit code: $?"   # should be 0, with no warning output
```

Or use the interactive helper:
```bash
chmod +x BUILD_AND_USE.sh
./BUILD_AND_USE.sh
```

---

## Troubleshooting

### `$PULSE_SERVER` is empty after running the tool

1. **Did you `eval` it?** Running `./pulse_start_fixed_v2` directly only
   prints to the screen — a subprocess can never modify its parent
   shell's environment. You must:
   ```bash
   eval "$(./pulse_start_fixed_v2)"
   ```
2. **Check `$PREFIX`** — if your Termux variant uses a non-standard
   install path, the tool now resolves binaries dynamically from
   `$PREFIX`, but will print a clear error if `pactl`/`pulseaudio`/`pgrep`
   aren't found there:
   ```bash
   echo $PREFIX
   ls -la $PREFIX/bin/pactl $PREFIX/bin/pulseaudio $PREFIX/bin/pgrep
   ```
3. **Run without swallowing stderr** to see the actual diagnostic
   messages:
   ```bash
   eval "$(./pulse_start_fixed_v2)"   # don't add 2>/dev/null while debugging
   ```

### "PulseAudio started but failed to connect"

Check the log:
```bash
cat ~/log/pulseaudio.log | tail -50
```

Try a different port if there's a conflict:
```bash
export PULSE_TCP_PORT=4720
eval "$(./pulse_start_fixed_v2)"
```

Give it more time to initialize on slower devices:
```bash
export PULSE_START_WAIT_MS=1500
eval "$(./pulse_start_fixed_v2)"
```

See [`QUICK_REFERENCE.md`](QUICK_REFERENCE.md) for more.

---

## License & Disclaimer

Educational project, free to use and modify. No warranty. Audio may be
loud on first start — set your volume before testing.
