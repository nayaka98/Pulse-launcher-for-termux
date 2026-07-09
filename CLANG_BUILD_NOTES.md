# BUILD DENGAN CLANG (Termux)

## Kenapa warning itu muncul?

Warning yang kamu dapat:
```
pulse_start_fixed.c:25:9: warning: '_GNU_SOURCE' macro redefined
pulse_start_fixed.c:401:14: warning: unused parameter 'argc'
pulse_start_fixed.c:401:26: warning: unused parameter 'argv'
pulse_start_fixed.c:324:13: warning: unused function 'tmux_send_info'
```

Ini semua berasal dari **compile flags clang di Termux** yang lebih ketat
default-nya dibanding gcc biasa (clang di Termux biasanya sudah define
`_GNU_SOURCE` lewat command line / target triple, jadi `#define _GNU_SOURCE`
di dalam source jadi dianggap redefinisi).

**Sudah diperbaiki di kedua file** (`pulse_start_fixed.c` v1 dan
`pulse_start_fixed_v2.c`):

### Fix #1 — `_GNU_SOURCE` redefinition
```c
// SEBELUM:
#define _GNU_SOURCE

// SESUDAH:
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
```
Sekarang aman dipakai baik saat `_GNU_SOURCE` sudah didefinisikan lewat
command line (`-D_GNU_SOURCE`) maupun belum.

### Fix #2 — unused parameter `argc`/`argv`
```c
int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;
    ...
```
`main()` di tool ini memang tidak butuh argumen command-line, jadi
parameter di-"pakai" secara eksplisit lewat `(void)` cast supaya compiler
tahu ini disengaja, bukan lupa.

### Fix #3 — unused function `tmux_send_info`
Sebelumnya fungsi ini di-define tapi **tidak pernah dipanggil** di `main()`
(dan bahkan di v1 aslinya cuma dead code yang tidak eksekusi apapun — lihat
`CHANGELOG.md` BUG #12). Sekarang:
1. Fungsinya diimplementasikan penuh (pakai `posix_spawn` + `argv[]`, tanpa
   shell string, jadi aman dari injection).
2. Dipanggil di `main()` saat tmux session baru dibuat, untuk kirim pesan
   selamat datang ke window 1 (shell bebas).

---

## Cara Build dengan Clang di Termux

```bash
pkg install clang

cd ~/pulse_start_package

# v2 (REKOMENDASI)
clang -O2 -s -Wall -Wextra -o pulse_start_fixed_v2 pulse_start_fixed_v2.c

# v1 (kalau mau bandingkan)
clang -O2 -s -Wall -Wextra -o pulse_start_fixed pulse_start_fixed.c
```

Kedua file ini sudah ditest compile bersih (0 warning) dengan
`-Wall -Wextra -Wpedantic` menggunakan gcc di sandbox pengembangan (clang
tidak tersedia di sandbox ini, tapi kedua compiler pakai basis diagnostic
yang sama untuk kelas warning ini — `_GNU_SOURCE` redefinition,
`-Wunused-parameter`, dan `-Wunused-function` — jadi hasilnya seharusnya
identik di clang Termux).

Kalau setelah build dengan clang di device kamu **masih** muncul warning
lain yang belum ke-cover di sini, kirim pesan warning lengkapnya — akan
saya perbaiki lagi.

---

## Kenapa pakai clang, bukan gcc?

Termux **tidak menyediakan gcc** secara default — paket resminya adalah
`clang` (dari LLVM), yang juga menyediakan `cc` dan `gcc` sebagai alias/
wrapper ke clang di banyak setup Termux. Jadi:

```bash
pkg install clang
# Setelah ini, `clang`, `cc`, dan kadang `gcc` semua tersedia
# (tergantung apakah paket `binutils`/`gcc` alias juga terpasang)
```

Kalau mau pastikan pakai clang secara eksplisit (bukan alias), selalu
panggil `clang` langsung, bukan `cc`/`gcc`:

```bash
clang -O2 -s -o pulse_start_fixed_v2 pulse_start_fixed_v2.c
```

---

## Verifikasi Tidak Ada Warning

```bash
clang -O2 -Wall -Wextra -Wpedantic -c pulse_start_fixed_v2.c -o /tmp/test.o
echo "Exit code: $?"
# Harus: Exit code: 0, TANPA output warning apapun
```
