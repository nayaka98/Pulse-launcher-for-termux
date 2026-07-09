# CHANGELOG — pulse_start_fixed_v2.c

## Round 2 Bugfixes (di atas v1 pulse_start_fixed.c)

Setelah review ulang lebih dalam, ditemukan **6 bug tambahan**, termasuk **1 bug kritis**
yang bisa merusak alur `eval "$(pulse_start_fixed)"` yang jadi cara pakai utama tool ini.

---

### 🔴 BUG #9 [CRITICAL] — pactl info bocor ke stdout, merusak `eval`

**Masalah:**
```c
// v1: pactl_info_show()
int rc = posix_spawn(&pid, PACTL_PATH, NULL, NULL, argv, child_envp);
//                                      ^^^^ tidak ada file_actions
//                                      → child WARISI stdout kita apa adanya
```

`print_export_lines()` **juga** menulis ke stdout (fd 1) — ini memang harus,
supaya `eval "$(pulse_start_fixed)"` bisa menangkap `export ...`.

Tapi karena `pactl info` **juga** ditulis ke stdout yang sama, ketika user
menjalankan:
```bash
eval "$(pulse_start_fixed)"
```
Shell akan menangkap SEMUA baris — termasuk output manusia dari `pactl info`
seperti:
```
Server String: /data/data/.../pulse/native
Library Protocol Version: 35
Server Protocol Version: 35
...
```
Lalu `eval` mencoba menjalankan **setiap baris itu sebagai command shell**:
```
bash: Server: command not found
bash: Library: command not found
bash: Server: command not found
...
```

Ini adalah bug yang sudah ada bahkan di kode ASLI (`pulse_start.c`) — didesain
supaya user "melihat output pactl apa adanya di terminal", tapi tidak
mempertimbangkan bahwa fungsi yang sama juga dipakai dalam alur `eval`.

**Fix (v2):**
```c
static int pactl_info_show(void) {
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    // Alihkan stdout CHILD ke stderr KITA (fd 2), bukan stdout kita (fd 1)
    posix_spawn_file_actions_adddup2(&fa, STDERR_FILENO, STDOUT_FILENO);

    char *argv[] = { (char *)"pactl", (char *)"info", NULL };
    pid_t pid;
    int rc = posix_spawn(&pid, PACTL_PATH, &fa, NULL, argv, child_envp);
    posix_spawn_file_actions_destroy(&fa);
    ...
}
```

**Hasil:**
- User tetap **melihat** output `pactl info` di terminal (karena stderr juga
  tampil di terminal secara default) — UX tidak berubah.
- Tapi fd 1 (stdout) sekarang **100% bersih**, hanya berisi `export ...`.
- `eval "$(pulse_start_fixed_v2)"` sekarang aman dijalankan berulang kali
  tanpa spam error "command not found".

---

### 🟠 BUG #10 [HIGH] — Signal handler memanggil fungsi yang tidak async-signal-safe

**Masalah:**
```c
// v1
static void signal_handler(int sig) {
    write_colored_msg(2, RED, "Interrupted!", 1);
    cleanup_and_exit(128 + sig);   // ← memanggil free() lalu exit()
}
```

POSIX hanya menjamin sekumpulan kecil fungsi aman dipanggil dari dalam signal
handler ("async-signal-safe list"): `write()`, `_exit()`, dan beberapa lainnya.
**`free()` dan `exit()` TIDAK termasuk daftar itu.**

Skenario race:
1. Main thread sedang di tengah `malloc()` di `init_child_env()` — allocator
   internal lock sedang dipegang.
2. User menekan Ctrl+C → SIGINT masuk → `signal_handler()` dipanggil.
3. Handler memanggil `free()` → mencoba mengunci lock yang sama →
   **deadlock**. Proses hang selamanya, hanya bisa dihentikan dengan
   `kill -9`.

Ini rare (window kecil), tapi termasuk kelas bug klasik "signal handler
reentrancy" yang sering jadi celah keamanan/stabilitas di tools sistem.

**Fix (v2):**
```c
static void signal_handler(int sig) {
    g_last_signal = sig;
    write_str(2, "\n" RED "Interrupted, exiting." RESET "\n");  // write() only
    _exit(128 + sig);   // _exit() only — TIDAK menjalankan atexit handlers,
                         // TIDAK flush stdio buffer, TIDAK panggil free()
}
```

`free(child_envp)` sengaja **tidak** dipanggil di jalur sinyal — OS akan
membebaskan seluruh memori proses saat exit, jadi ini bukan leak beneran,
hanya reclaim yang ditunda (tradeoff yang benar untuk kasus ini).

---

### 🟡 BUG #11 [MEDIUM] — validate_int_range() salah clamp untuk nilai di atas max

**Masalah:**
```c
// v1
static int validate_int_range(int val, int min, int max) {
    return (val >= min && val <= max) ? val : min;
    //                                        ^^^ BUG: selalu balik ke MIN
    //                                        walau val kelewat MAX!
}
```

Contoh nyata:
```bash
export PULSE_LATENCY_MSEC=999999   # user salah ketik / typo
eval "$(pulse_start_fixed)"
```
Yang diharapkan: nilai di-clamp ke maksimum (10000ms).
Yang terjadi: nilai malah jatuh ke **minimum (1ms)** — jauh dari yang
dimaksud, dan bisa bikin audio patah-patah drastis tanpa pesan
error apapun.

**Fix (v2):**
```c
static int clamp_int(int val, int min, int max) {
    if (val < min) return min;
    if (val > max) return max;
    return val;
}
```
Sekarang `999999` → clamp ke `10000` (max), bukan `1` (min). Perilaku sesuai
ekspektasi standar "clamp".

---

### 🟢 BUG #12 [LOW] — tmux_send_info() dead code, tidak pernah eksekusi apapun

**Masalah:**
```c
// v1
static void tmux_send_info(const char *text) {
    if (!config.use_tmux || !tmux_session_exists()) return;

    char cmd[256];
    snprintf(cmd, sizeof cmd, "tmux send-keys -t %s:1 '%s' Enter",
             config.tmux_session, text);

    // Would execute via shell, but keep minimal here
    // Just log to stderr that info was sent
}
```
`cmd` dibangun tapi **tidak pernah dieksekusi** — fungsi terlihat seperti
mengirim pesan ke tmux window 1, tapi sebenarnya no-op total. Bug "silent
dead code" seperti ini berbahaya karena mudah lolos review (terlihat
lengkap, padahal kosong).

**Fix (v2):** diimplementasikan penuh dengan `posix_spawn` + `argv[]`
langsung (tanpa shell), sehingga tidak perlu escaping string dan tidak ada
risiko shell injection dari isi `text`:
```c
static void tmux_send_info(const char *text) {
    if (!config.use_tmux || !tmux_session_exists()) return;

    char target[80];
    snprintf(target, sizeof target, "%s:1", config.tmux_session);

    char *argv[] = {
        (char *)"tmux", (char *)"send-keys",
        (char *)"-t", target,
        (char *)text, (char *)"Enter",
        NULL
    };
    posix_spawn(&pid, TMUX_PATH, &fa, NULL, argv, child_envp);
    ...
}
```

---

### 🟢 BUG #13 [LOW] — unused parameter warnings

**Masalah:** `main(int argc, char *argv[])` tidak pernah memakai `argc`/`argv`,
memicu warning `-Wextra` (`unused parameter`).

**Fix:** ditambahkan `(void)argc; (void)argv;` di awal `main()`.

---

### 🟢 BUG #14 [LOW] — waktu tunggu startup hardcoded & tidak realistis

**Masalah:** v1 menunggu `5 × 200ms = 1000ms` (bukan `300ms` yang disebut di
komentar desain awal), tapi nilai ini hardcoded dan tidak bisa disesuaikan
untuk device Android yang lebih lambat inisialisasi AAudio-nya.

**Fix:** ditambahkan env var `PULSE_START_WAIT_MS` (default `600ms`, di-clamp
`50–5000ms`), dengan jumlah "tick" progress dot mengikuti nilai ini secara
proporsional (per 100ms).

```bash
# Device lambat? Perpanjang waktu tunggu:
export PULSE_START_WAIT_MS=1500
eval "$(pulse_start_fixed_v2)"
```

---

## Round 3 Bugfixes — "PULSE_SERVER tetap kosong"

Ini bug yang dilaporkan langsung dari pemakaian nyata: setelah `eval "$(pulse_start_fixed_v2)"`, `$PULSE_SERVER` tetap kosong. Root-cause-nya **dua bug independen**, keduanya sudah diperbaiki:

---

### 🔴 BUG #15 [CRITICAL] — Export lines hanya dicetak kalau koneksi sukses

**Masalah:**
```c
if (pactl_info_show()) {
    print_export_lines();   // ← HANYA di sini
    cleanup_and_exit(0);
}
// Kalau gagal: langsung error + exit(1), TIDAK PERNAH panggil print_export_lines()
```

Kalau `pactl info` gagal connect karena **alasan apapun** — port konflik,
PulseAudio belum selesai init, timing terlalu cepat, dll — maka stdout
program **kosong total**. Akibatnya:
```bash
eval "$(pulse_start_fixed_v2)"   # stdout kosong → eval tidak set apa-apa
echo $PULSE_SERVER               # kosong, TANPA petunjuk kenapa
```
Padahal nilai `PULSE_SERVER` yang *seharusnya* di-export itu tetap valid
dan berguna untuk debug manual (`pactl info` sendiri, atau retry setelah
PulseAudio benar-benar siap).

**Fix:** dibuat fungsi `finish(int success)` yang **SELALU** memanggil
`print_export_lines()` sebelum keluar, apapun hasilnya. Exit code (`$?`)
tetap mencerminkan sukses/gagal (0/1) supaya script yang cek `$?` tidak
terpengaruh — hanya variabel yang di-export sekarang selalu tersedia.

```c
static void finish(int success) {
    print_export_lines();   // SELALU jalan
    cleanup_and_exit(success ? 0 : 1);
}
```

Satu-satunya kasus yang legitimately tidak print apapun: `setup_config()`
gagal total (misal gagal bikin folder log) — di titik itu memang belum
ada config valid untuk di-export.

---

### 🔴 BUG #16 [CRITICAL] — Path binary hardcoded ke `com.termux`, gagal diam-diam di variant lain

**Masalah:**
```c
#define PACTL_PATH      "/data/data/com.termux/files/usr/bin/pactl"
#define PULSEAUDIO_PATH "/data/data/com.termux/files/usr/bin/pulseaudio"
#define PGREP_PATH      "/data/data/com.termux/files/usr/bin/pgrep"
```

Path ini **hanya benar** kalau Termux ter-install dengan app-id persis
`com.termux`. Tapi banyak variant punya app-id/prefix beda:
- Termux:Nightly → `com.termux.nightly`
- proot-distro / chroot custom → prefix custom sepenuhnya
- Beberapa fork/build custom lain

Kalau path ini salah, `posix_spawn()` gagal dengan `rc != 0` (binary tidak
ketemu) — dan **kode lama menganggap ini sama saja dengan "command
dijalankan tapi exit code nonzero"**. Hasilnya: pesan generik
"PulseAudio running but cannot connect" atau "failed to connect", padahal
masalah sebenarnya adalah **binary-nya tidak pernah kejalanin sama
sekali** karena path salah.

**Fix:**
1. Semua path sekarang **di-resolve dari `$PREFIX`** (env var yang SELALU
   di-set otomatis oleh Termux, contoh: `/data/data/com.termux/files/usr`),
   bukan hardcoded:
   ```c
   snprintf(config.pactl_path, ..., "%s/bin/pactl", config.prefix);
   ```
2. `HOME` fallback juga di-derive dari `$PREFIX` (ganti akhiran `/usr` jadi
   `/home`), bukan hardcode `com.termux`.
3. **Validasi eksplisit** sebelum jalan apapun — kalau binary yang wajib
   (`pactl`, `pulseaudio`, `pgrep`) tidak ketemu di path yang di-resolve,
   program **langsung berhenti dengan pesan JELAS**:
   ```
   ERROR: pactl not found at: /data/data/com.termux/files/usr/bin/pactl
   Hint: install with 'pkg install pulseaudio', or if $PREFIX is
   non-standard, make sure it's exported correctly.
   ```
   (sebelumnya: silent failure, pesan generik "connection refused")

**Hasil test:**
```bash
# Path Termux normal tidak ketemu (mis. di container non-Termux):
$ ./pulse_start_fixed_v2
ERROR: pactl not found at: /data/data/com.termux/files/usr/bin/pactl
Hint: install with 'pkg install pulseaudio', or if $PREFIX is non-standard...

# Dengan PREFIX custom yang valid:
$ PREFIX=/custom/prefix ./pulse_start_fixed_v2
# → resolve ke /custom/prefix/bin/pactl dkk, jalan normal
```

---

## Ringkasan Semua Bug (v1 + v2 + v3)

| # | Bug | Severity | Fix Round |
|---|-----|----------|-----------|
| 1 | Memory leak (child_envp) | CRITICAL | v1 |
| 2 | mkdir_p error ignored | CRITICAL | v1 |
| 3 | EINTR tidak ditangani | HIGH | v1 |
| 4 | write() error diabaikan | HIGH | v1 |
| 5 | Race condition pgrep→start | MEDIUM | v1 (mitigated) |
| 6 | Tidak ada signal handler | MEDIUM | v1 |
| 7 | Buffer overflow risk | LOW | v1 |
| 8 | Env vars tidak masuk parent shell | LOW | v1 (by design) |
| 9 | pactl info bocor ke stdout → rusak eval | CRITICAL | v2 |
| 10 | Signal handler pakai free()/exit() (unsafe) | HIGH | v2 |
| 11 | Clamp salah arah (max jadi min) | MEDIUM | v2 |
| 12 | tmux_send_info() dead code | LOW | v2 |
| 13 | Unused parameter warning | LOW | v2 |
| 14 | Wait time hardcoded, tidak proporsional | LOW | v2 |
| **15** | **Export lines cuma print kalau sukses → PULSE_SERVER kosong saat gagal** | **CRITICAL** | **v3** |
| **16** | **Path binary hardcoded ke `com.termux`, gagal diam-diam di variant lain** | **CRITICAL** | **v3** |

**Total: 16 bug ditemukan & diperbaiki across v1 + v2 + v3.**

---

## Env var baru di v3

```bash
# Kalau Termux kamu punya PREFIX non-standard, ini sudah otomatis
# terdeteksi dari env var PREFIX yang di-set Termux sendiri — biasanya
# tidak perlu diutak-atik manual. Tapi bisa override manual kalau perlu:
export PREFIX=/data/data/com.termux.nightly/files/usr
eval "$(./pulse_start_fixed_v2)"
```


---

## Build & Pakai (v2)

```bash
gcc -O2 -s -Wall -Wextra -o pulse_start_fixed_v2 pulse_start_fixed_v2.c
eval "$(./pulse_start_fixed_v2)"
pactl info
```

Compile bersih dengan `-Wall -Wextra`, **0 warning**.

### Env vars baru di v2
```bash
export PULSE_START_WAIT_MS=1500   # perpanjang waktu tunggu init (default 600)
```

Semua env var lama (`PULSE_TCP_PORT`, `PULSE_LATENCY_MSEC`, `XDG_RUNTIME_DIR`)
tetap berfungsi sama seperti v1.
