# DevBox — UML arm64 Patching Phase Notes

## Status Saat Ini

**Target kernel:** Linux 6.12.74
**Build host:** ubuntu-24.04-arm (GitHub Actions, uname -m = aarch64)
**ARCH=um SUBARCH=arm64**

### Patches Yang Sudah Ada (v10)

| Patch | File | Keterangan |
|-------|------|------------|
| 0001 | arch/arm64/Makefile.um | ELF format, START addr, KBUILD_CFLAGS |
| 0001b | arch/arm64/Makefile | Tambah `archheaders` target → generate cpucap-defs.h |
| 0002 | arch/arm64/um/Makefile + headers + user-offsets.c | Makefile rules, archheaders→kapi, user_constants.h generation |
| 0003b | arch/arm64/um/stub_segv.c | SIGSEGV stub handler |
| 0003c | arch/arm64/um/task_size.c | TASK_SIZE untuk arm64 |
| 0004 | arch/arm64/um/sys_call_table.c | Syscall table arm64 |
| 0005 | arch/arm64/um/shared/sysdep/{faultinfo,stub,ptrace_user,archsetjmp}.h | Sysdep headers |
| 0005b | arch/arm64/um/shared/sysdep/kernel-offsets.h | Untuk asm-offsets generation |
| 0006 | arch/arm64/um/os-Linux/registers.c | PTRACE_GETREGSET/SETREGSET wrappers |
| 0007 | arch/um/os-Linux/skas/process.c | PTRACE_SYSCALL fallback (tidak pakai SYSEMU) |
| 0008 | arch/um/os-Linux/start_up.c | Non-fatal sysemu check |
| 0009 | arch/um/os-Linux/registers.c | arm64 register compat |
| 0010 | arch/arm64/um/signal.c | rt_sigframe handling |
| 0011 | arch/arm64/um/shared/sysdep/{ptrace,syscalls}.h | ptrace + syscall defs |
| 0012 | arch/arm64/um/{asm/processor.h,Kconfig} + arch/um/configs/arm64_defconfig | Processor, Kconfig, defconfig |
| 0013 | arch/arm64/um/os-Linux/{signal,prctl,uaccess}.c | arch_do_signal, PAC keys disable, uaccess stub |

### Bug-bug Yang Sudah Dipecahkan

1. **Makefile.um format** — variabel salah nama (SUBARCH_CFLAGS → KBUILD_CFLAGS, START_ADDR → START)
2. **defconfig naming** — `aarch64_defconfig` → `arm64_defconfig` (kernel sed: aarch64→arm64)
3. **user_constants.h** — butuh user-offsets.c + rules di Makefile
4. **cpucap-defs.h** — arch/arm64/Makefile tidak punya `archheaders`, harus tambah sendiri
5. **kernel-offsets.h** — arch/arm64/um/shared/sysdep/ kosong, tidak ada file ini

### Error Terakhir Yang Dipecahkan
```
fatal error: sysdep/kernel-offsets.h: No such file or directory
  in arch/um/kernel/asm-offsets.c:3
```
Fix: patch 0005b menambahkan file tersebut.

---

## Constraint Penting (JANGAN DILANGGAR)

- ❌ NO root di Android
- ❌ NO KVM (`/dev/kvm` tidak ada)
- ❌ NO `PTRACE_SYSEMU` (tidak support di arm64 host)
- ❌ NO `PTRACE_GETREGS/SETREGS` (arm64 hanya punya GETREGSET/SETREGSET)
- ❌ NO symlink di FAT filesystem (Android storage)
- ✅ PTRACE_SYSCALL saja (intercept syscall entry+exit)
- ✅ PTRACE_GETREGSET dengan NT_PRSTATUS

---

## Roadmap Setelah Compile Berhasil

### Fase 1 — UML Boot (sekarang)
- [ ] Compile berhasil tanpa error
- [ ] UML bisa boot ke Debian rootfs
- [ ] Login via console
- [ ] Ganti proot sepenuhnya

### Fase 2 — Namespace & Isolasi
Tambahkan ke `arm64_defconfig`:
```
CONFIG_NAMESPACES=y
CONFIG_UTS_NS=y
CONFIG_IPC_NS=y
CONFIG_PID_NS=y
CONFIG_NET_NS=y
CONFIG_USER_NS=y
CONFIG_CGROUPS=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_MEMCG=y
```
Hasilnya: tiap "session" DevBox bisa punya PID/network namespace sendiri.
**Lebih baik dari proot** — proot fake namespace, ini real kernel namespace.

### Fase 3 — Docker/Podman di dalam UML
Setelah namespace aktif, bisa run container di dalam UML:
```
CONFIG_OVERLAY_FS=y
CONFIG_VETH=y
CONFIG_BRIDGE=y
CONFIG_NETFILTER=y
CONFIG_IP_NF_IPTABLES=y
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
```
Analoginya seperti Docker di dalam VM — fully isolated.

### Fase 4 — Optimasi Performa
- Tune UML untuk startup cepat (target <2 detik di Android)
- Virtio-style I/O untuk UBD (block device)
- Memory balloon (dynamic RAM allocation)
- hostfs mount untuk akses file Android tanpa copy

### Fase 5 — Integrasi Android App
- Wrapper binary `devbox-start` yang launch UML + setup networking
- SSH forwarding dari localhost:2222 → UML
- Shared storage via hostfs (read-only /sdcard mount)
- Termux-style terminal integration

---

## Perbandingan Arsitektur

```
proot (lama):
  App → syscall → ptrace intercept (tiap syscall!) → path rewrite → host kernel
  Lambat, fake namespace, banyak yang tidak work

UML (baru):
  App → syscall → UML kernel (native C, cepat) → sesekali host syscall
  Real namespaces, real cgroups, real kernel
  
gVisor (tidak bisa):
  Butuh KVM atau PTRACE_SYSEMU → keduanya tidak ada di Android arm64 tanpa root
  UML adalah satu-satunya solusi yang feasible
```

---

## File Penting

| File | Lokasi | Fungsi |
|------|--------|--------|
| AGENT.md | /uml-arm64-patch/ | Dokumentasi lengkap untuk AI handoff |
| PATCHING-PHASE.md | /uml-arm64-patch/ | File ini |
| build-debian-image.sh | scripts/ | Build rootfs + kernel |
| apply.sh | scripts/patches/uml-arm64/ | Apply semua patches |
| debian_image.yml | .github/workflows/ | GitHub Actions CI |

---

## Cara Test Lokal (setelah CI hijau)

```bash
# 1. Download rootfs + kernel dari GitHub Actions artifacts
# 2. Jalankan UML
./linux-uml-aarch64 \
    ubd0=debian-rootfs-aarch64.img \
    root=/dev/ubda \
    mem=512M \
    con=fd:0,fd:1

# 3. Login: root / devbox
```

Tidak butuh initrd, tidak butuh bootloader, tidak butuh GRUB.
UML langsung mount rootfs via UBD driver → exec /sbin/init.
