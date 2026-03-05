# AGENT.md — UML arm64 Port (DevBox Project)

> **Baca file ini dulu sebelum menyentuh apapun.**
> File ini adalah "otak" project. Berisi semua konteks, keputusan desain,
> kesalahan yang sudah terjadi, dan status terkini.

---

## 1. Tujuan Project

**DevBox** — Android APK yang menjalankan distro Linux lengkap (Debian/Ubuntu)
di atas device Android **tanpa root** menggunakan **User Mode Linux (UML)**
yang di-port ke **ARM64**.

Target: alternatif lebih ringan dari QEMU, tanpa butuh KVM/root.

**Stack:**
```
Android App (Java/Kotlin)
    └── fork/exec → linux (UML binary, compiled ARCH=um SUBARCH=aarch64)
                        └── jalankan guest Linux di atas ptrace
```

---

## 2. Constraint Kritis (JANGAN DILANGGAR)

| Constraint | Alasan |
|---|---|
| **NO root** | Target: user biasa di Play Store |
| **NO KVM** | Tidak tersedia tanpa root |
| **NO PTRACE_SYSEMU** | Android SELinux blokir di non-root |
| **NO PTRACE_GETREGS/SETREGS** | Tidak ada di arm64 kernel |
| **NO symlink di /sdcard** | FAT/exFAT tidak support symlink |

---

## 3. Keputusan Desain Utama

### 3.1 Kenapa UML bukan QEMU?
- QEMU butuh KVM untuk performa acceptable → butuh root
- UML jalan murni di userspace via ptrace → no root needed
- UML sudah ada di kernel mainline, tinggal port ke arm64

### 3.2 PTRACE_SYSCALL Trick (pengganti PTRACE_SYSEMU)

Ini **inti dari seluruh port**. PTRACE_SYSEMU tidak ada di arm64 dan diblokir
SELinux. Solusinya tirukan proot:

```
PTRACE_SYSCALL → stop di syscall ENTRY
  → UML ganti syscall number ke __NR_getpid (harmless)
  → host kernel eksekusi → dapat ENOSYS (aman)
  → stop di syscall EXIT
  → UML inject return value yang benar
  → guest resume dengan hasil yang benar
```

State tracking pakai `at_syscall_entry` boolean (toggle entry/exit).

### 3.3 Register Access arm64

arm64 TIDAK punya `PTRACE_GETREGS`/`PTRACE_SETREGS`. Harus pakai:
- GP regs: `PTRACE_GETREGSET` dengan `NT_PRSTATUS` → `struct user_pt_regs`
- FP/SIMD: `PTRACE_GETREGSET` dengan `NT_PRFPREG` → `struct user_fpsimd_state`

### 3.4 arm64 Register Layout (gp[] array)

```
gp[0]  .. gp[30]  = x0 .. x30
gp[31]            = sp
gp[32]            = pc
gp[33]            = pstate

HOST_SP    = 31
HOST_PC    = 32
HOST_PSTATE = 33

Syscall: x8 = nr, x0-x5 = args, x0 = return value
```

### 3.5 FP/SIMD Layout (fp[] array)

```
struct user_fpsimd_state:
  __uint128_t vregs[32]  → 64 unsigned long (512 bytes)
  __u32 fpsr             → dalam ulong ke-64 (low 32 bit)
  __u32 fpcr             → dalam ulong ke-65 (low 32 bit)
  __u32 __reserved[2]

FP_SIZE = 66  (total unsigned long dalam array)
```

---

## 4. Struktur Patch (URUTAN PENTING!)

Semua patch ada di `scripts/patches/uml-arm64/`. Apply dengan `apply.sh`.

```
0001  arch/arm64/Makefile.um
        → Entry point build system. Defines START, ELF_ARCH, ELF_FORMAT,
          KBUILD_CFLAGS, STUB_START/END.
        → HARUS pakai variabel yang sama dengan x86/Makefile.um.
        → JANGAN pakai SUBARCH_CFLAGS atau START_ADDR (salah!).

0002  arch/arm64/um/Makefile (+ user-offsets.c rule)
      arch/arm64/um/os-Linux/Makefile
        arch/arm64/um/user-offsets.c  <- generates user_constants.h via offsets mechanism
      arch/arm64/um/asm/ptrace.h
      arch/arm64/um/asm/archparam.h
      arch/arm64/um/asm/thread_info.h (stub)
        → Build makefiles + arch headers utama.

0003b arch/arm64/um/stub_segv.c
        → Stub trampoline yang di-mmap ke setiap proses guest.
        → Handle SIGSEGV di dalam stub, kirim ke UML kernel thread via SVC.

0003c arch/arm64/um/asm/mmu_context.h
        → TASK_SIZE untuk arm64 UML (39-bit VA = 512GB).

0004  arch/arm64/um/sys_call_table.c
        → Syscall table untuk arm64 guest.

0005  arch/arm64/um/shared/sysdep/faultinfo.h
      arch/arm64/um/shared/sysdep/stub.h
      arch/arm64/um/shared/sysdep/ptrace_user.h
      arch/arm64/um/shared/sysdep/archsetjmp.h
        → sysdep headers: fault info, stub inline syscalls,
          ptrace offsets (HOST_SP=31, HOST_PC=32, HOST_PSTATE=33),
          jmp_buf layout (JB_IP=11, JB_SP=12).

0006  arch/arm64/um/os-Linux/registers.c
        → FULL register access implementation:
          save_registers/restore_registers (GETREGSET NT_PRSTATUS)
          get_fp_registers/put_fp_registers (GETREGSET NT_PRFPREG)
          ptrace_getregs/ptrace_setregs wrappers
          arch_init_registers (no-op, NEON always present)
          get_thread_reg (jmp_buf accessor)

0007  arch/um/os-Linux/skas/process.c  [MODIFIKASI FILE KERNEL ASLI]
        → Tambah #ifdef __aarch64__ guards:
          - include <registers.h> dan <sys/uio.h>
          - extern int sysemu_supported
          - ptrace_dump_regs: pakai GETREGSET di arm64
          - userspace(): PTRACE_SETREGS → restore_registers() di arm64
          - userspace(): PTRACE_SYSEMU → cek sysemu_supported dulu
          - userspace(): PTRACE_GETREGS → save_registers() di arm64
          - SIGTRAP+0x80 handler: dua-stop logic kalau !sysemu_supported
          - Tambah at_syscall_entry + arm64_neutralize_syscall()

0008  arch/um/os-Linux/start_up.c  [MODIFIKASI FILE KERNEL ASLI]
        → check_sysemu() jadi non-fatal:
          - Tambah global: int sysemu_supported = 0
          - Kalau SYSEMU gagal: print warning, set flag = 0 (JANGAN fatal!)
          - Kalau SYSEMU berhasil: set flag = 1

0009  arch/um/os-Linux/registers.c  [MODIFIKASI FILE KERNEL ASLI]
        → init_pid_registers(): pakai ptrace_getregs() di arm64
          (bukan ptrace(PTRACE_GETREGS) langsung)

0010  arch/arm64/um/signal.c
        → FULL rt_sigframe untuk arm64:
          - struct arm64_rt_sigframe { siginfo + ucontext }
          - setup_signal_stack_si(): build frame, save FP ke __reserved[]
            sebagai fpsimd_context (FPSIMD_MAGIC)
          - sys_rt_sigreturn(): restore regs + FP dari frame
          - SP harus 16-byte aligned (AAPCS64)

0011  arch/arm64/um/shared/sysdep/ptrace.h
      arch/arm64/um/shared/sysdep/syscalls.h
        → UPT_* accessor macros, PT_REGS_* wrappers
        → EXECUTE_SYSCALL macro
        → PT_REGS_RESTART_SYSCALL: PC -= 4 (ukuran SVC instruction)

0012  arch/arm64/um/asm/processor.h
      arch/arm64/um/Kconfig
      arch/um/configs/arm64_defconfig
        → arch_thread struct (minimal, no debug regs)
        → cpu_relax() pakai YIELD instruction
        → Kconfig: 64BIT, MODULES_USE_ELF_RELA, no ARCH_HAS_SC_SIGNALS
        → defconfig: HOSTFS, UBD, slirp networking

0013  arch/arm64/um/os-Linux/signal.c   ← set_sigstack, arch_do_signal
      arch/arm64/um/os-Linux/prctl.c    ← arch_prctl_defaults (disable PAC)
      arch/arm64/um/os-Linux/uaccess.c  ← arch_fixup stub
```

---

## 5. File yang DIHAPUS (jangan di-add balik!)

| File lama | Alasan dihapus | Diganti oleh |
|---|---|---|
| `0003a-arm64-um-signal.patch` | Stub kosong signal.c | patch 0010 |
| `0003d-arm64-um-os-linux-registers.patch` | Stub kosong registers.c | patch 0006 |
| `0003e-arm64-um-os-linux-misc.patch` | Stub signal/prctl/uaccess | patch 0013 |

**Kalau semua 3 patch lama ini masih ada → KONFLIK saat apply!**

---

## 6. Cara Build

```bash
# 1. Download kernel
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.74.tar.xz
tar -xf linux-6.12.74.tar.xz

# 2. Apply patches
cd linux-6.12.74
bash /path/to/scripts/patches/uml-arm64/apply.sh .

# 3. Configure
make ARCH=um SUBARCH=aarch64 arm64_defconfig

# 4. Build
make ARCH=um SUBARCH=aarch64 -j$(nproc)
```

---

## 7. Known Issues & Iterasi yang Sudah Gagal

### 7.1 Format Patch
- **JANGAN** tulis patch dengan `@@ -1,X +1,Y @@` untuk file baru
  → pakai `@@ -0,0 +1,N @@` dari `--- /dev/null`
- **JANGAN** biarkan `@@ ... @@` dan content line 1 jadi satu baris
  → selalu ada `\n` setelah `@@`
- **Cara generate patch yang benar:**
  1. Tulis file baru → `make_new_file()` pattern
  2. Untuk modifikasi file existing → `diff -u orig new` lalu fix header path

### 7.2 Makefile.um
- `SUBARCH_CFLAGS` → SALAH, harus `KBUILD_CFLAGS`
- `START_ADDR` → SALAH, harus `START`
- Multi-line dengan `\` di dalam heredoc/python string → sering corrupt
- Selalu cek dengan `make --dry-run` sebelum push

### 7.3 Android Symlink
- Kernel source tidak bisa di-extract langsung di `/sdcard` (FAT)
- Harus extract di internal storage atau Linux container

### 7.4 GitHub Actions
- Build script: `scripts/build-debian-image.sh`
- Workflow: `.github/workflows/debian_image.yml`
- Target: `ubuntu-24.04-arm` (native arm64 runner)

---

## 8. Status Saat Ini

| Komponen | Status |
|---|---|
| Build system (Makefile, Kconfig) | ✅ Done |
| arch headers (ptrace.h, archparam.h, dll) | ✅ Done |
| stub_segv.c | ✅ Done |
| syscall table | ✅ Done |
| sysdep headers | ✅ Done |
| GP + FP register access | ✅ Done |
| PTRACE_SYSCALL fallback | ✅ Done |
| check_sysemu non-fatal | ✅ Done |
| signal frame (rt_sigframe) | ✅ Done |
| UPT_* macros, EXECUTE_SYSCALL | ✅ Done |
| processor.h, defconfig | ✅ Done |
| arch_do_signal, prctl, uaccess | ✅ Done |
| **Patch format (malformed hunk)** | ✅ Fixed v5 |
| **Makefile.um missing separator** | ✅ Fixed v6
| **arm64_defconfig (bukan aarch64)** | ✅ Fixed v7 — kernel sed: aarch64→arm64 | |
| **Compile errors** | ⏳ Belum dicoba |
| **Runtime test** | ⏳ Belum |

**Current zip: `uml-arm64-patch-v6.zip`**

---

## 9. Referensi Penting

```
arch/x86/Makefile.um          → template Makefile.um yang benar
arch/x86/um/signal.c          → template signal frame (x86_64 bagian)
arch/um/os-Linux/skas/process.c  → file utama yang dimodifikasi
arch/um/os-Linux/start_up.c      → check_sysemu yang dimodifikasi
arch/arm64/include/uapi/asm/sigcontext.h  → layout sigcontext arm64
arch/arm64/include/uapi/asm/ucontext.h    → struct ucontext arm64
```

---

## 10. Kalau Mau Lanjut dari Sini

1. Upload `uml-arm64-patch-v6.zip` ke chat baru
2. Upload `AGENT.md` ini
3. Bilang: *"Ini project UML arm64 port untuk DevBox Android. Baca AGENT.md dulu, lanjutkan dari status di section 8."*

AI akan langsung paham tanpa perlu penjelasan ulang dari awal.
