# DevBox Engine & Bootstrap Architecture

## Filosofi Dasar

Termux terpaksa build packages dari source karena berjalan **di atas Android langsung** —
setiap package harus di-port, di-patch, dikompilasi ulang untuk Bionic libc dan Android filesystem.

DevBox **tidak perlu itu sama sekali** karena berjalan di atas UML kernel — 
UML menyediakan environment Linux standar, jadi Debian official packages langsung bisa dipakai.

```
Termux:
  Setiap package → port ke Android → build dari source → termux-packages repo
  Ribuan package, masing-masing butuh maintenance

DevBox:
  UML kernel → Debian official → apt install apapun
  Zero porting, zero maintenance packages
```

---

## Komponen Engine

### 1. UML Binary (`linux-uml-aarch64`)
- Dihasilkan dari kernel build (PATCHING-PHASE.md)
- Di-bundle langsung di APK (`assets/linux-uml-aarch64`)
- Ukuran ~10-15MB (stripped)
- Diextract ke app private storage saat install

### 2. Rootfs Image (`debian-rootfs-aarch64.img.gz`)
- Dihasilkan oleh `build-debian-image.sh` via GitHub Actions
- Di-upload ke GitHub Releases
- Download saat first launch (seperti Termux download bootstrap-aarch64.zip)
- Ukuran compressed ~300MB, uncompressed ~1.5GB

### 3. Android App (DevBox.apk)
- Terminal emulator custom (tidak butuh Termux)
- PTY via `posix_openpt()` / JNI
- Langsung fork+exec UML binary
- Custom keyboard + UI

---

## Bootstrap Flow

### Termux (untuk perbandingan)
```
Install APK
  → APK berisi bootstrap.zip (~70MB bundled atau download)
  → Extract ke /data/data/com.termux/files/
  → Semua packages Termux-patched ada di sini
  → User bisa apt install (dari Termux repo, bukan Debian)
```

### DevBox
```
Install APK
  → APK berisi linux-uml-aarch64 binary (~12MB di assets/)
  → First launch: download debian-rootfs-aarch64.img.gz dari GitHub Releases
  → Decompress ke app private storage → debian-rootfs.img
  → Boot: exec linux-uml-aarch64 ubd0=debian-rootfs.img root=/dev/ubda mem=512M
  → User langsung dapat Debian bookworm
  → apt install dari deb.debian.org (official Debian!)
```

---

## Struktur APK

```
DevBox.apk
├── assets/
│   └── linux-uml-aarch64        ← UML kernel binary
├── lib/
│   └── arm64-v8a/
│       └── libdevbox.so          ← JNI: PTY, process management
└── classes.dex                   ← Android app (Kotlin)

~First launch download~
→ debian-rootfs-aarch64.img.gz    ← dari GitHub Releases
  disimpan di /data/data/com.devbox/files/
```

---

## Strategi Rootfs — Shell Only Base

**Satu image kecil. User install sisanya via apt setelah boot.**

Tidak perlu multiple flavors — kita bukan Termux yang harus pre-bundle packages.
Semua 50,000+ packages Debian tersedia langsung via `apt install` setelah boot.

```
devbox-base-aarch64.img.gz  (~80MB compressed, ~400MB uncompressed)

Yang di-bundle:
  ✓ zsh + starship          → UX layer
  ✓ openssh-server          → remote access
  ✓ curl, wget, socat       → networking essentials
  ✓ vim-tiny                → minimal editor
  ✓ apt + sources.list      → ke deb.debian.org official
  ✓ iproute2, net-tools     → network config

Yang TIDAK di-bundle (user apt install sendiri):
  python3, nodejs, golang, rust, gcc, git, docker, dll
```

### Kenapa Tidak Perlu Port Packages

```
Termux:
  berjalan di Android langsung → Bionic libc → paths aneh
  tiap package harus di-patch + build ulang → ~2000 packages, high maintenance

DevBox:
  UML = Linux standar → glibc standar → paths standar
  apt install langsung dari Debian official → zero porting, zero maintenance
```

Build via GitHub Actions → upload satu file ke Releases → user download saat first launch.

---

## Android App Architecture

### Terminal Stack
```
DevBox App
└── TerminalActivity (Kotlin)
    └── TerminalView (custom View)
        └── VT100/xterm parser
            └── PTY (via JNI libdevbox.so)
                └── UML process
```

**Library terminal yang bisa dipakai:**
- **JediTerm** — mature, dipakai IntelliJ IDEA, pure Java/Kotlin
- **termux-view** — extract dari Termux, Apache 2.0 license
- Custom dari scratch (lebih kontrol tapi lebih lama)

### JNI Layer (libdevbox.so)
```c
// Fungsi utama yang diexpose ke Kotlin:
int devbox_start(const char* rootfs_path, int mem_mb);
  → posix_openpt() → setup PTY
  → fork() → exec linux-uml-aarch64 dengan args yang benar
  → return PTY fd

void devbox_resize(int fd, int rows, int cols);
  → ioctl(fd, TIOCSWINSZ, ...)

void devbox_stop(int pid);
  → kill(pid, SIGTERM)
```

### UML Launch Command
```bash
./linux-uml-aarch64 \
    ubd0=$ROOTFS_PATH \
    root=/dev/ubda \
    mem=${MEM_MB}M \
    con=fd:0,fd:1 \      ← PTY fds
    ssl=none \
    TERM=xterm-256color
```

---

## Perbedaan vs Termux

| Aspek | Termux | DevBox |
|-------|--------|--------|
| Package source | Termux repo (ported) | Debian official |
| Package count | ~1000 (ported) | ~50,000+ |
| libc | Bionic (Android) | glibc (standard) |
| Kernel | Android kernel (terbatas) | UML kernel (full control) |
| Namespace | Tidak ada | Full (PID, NET, MNT, USER) |
| Docker support | Tidak bisa | Bisa (Fase 3) |
| Maintenance packages | Tinggi (tiap package diport) | Nol (Debian urus sendiri) |
| APK size | ~70MB (bootstrap bundled) | ~15MB (rootfs download) |
| First launch | Langsung siap | Download rootfs (~5 menit) |

---

## Phases

```
Fase 1 — UML Boot (PATCHING-PHASE.md)
  Status: in progress
  Goal: kernel compile + boot ke Debian

Fase 2 — Namespace & Isolasi
  Tambah CONFIG_NAMESPACES, USER_NS, NET_NS ke defconfig
  Goal: isolasi per-session

Fase 3 — Android App Mandiri
  Custom terminal emulator + JNI PTY
  Tidak butuh Termux sama sekali
  Goal: APK standalone

Fase 4 — Docker di dalam UML
  CONFIG_OVERLAY_FS, VETH, BRIDGE, NETFILTER
  Goal: docker run di dalam DevBox

Fase 5 — Distribusi
  GitHub Releases untuk rootfs flavors
  Play Store / F-Droid untuk APK
  Auto-update rootfs via apt
```

---

## Catatan Penting

- **Rootfs bukan di-bundle di APK** — terlalu besar untuk Play Store (limit 100MB)
  tapi **UML binary di-bundle** karena kecil (~12MB) dan critical untuk boot

- **Storage**: rootfs butuh ~2GB free di internal storage
  perlu cek dan tampilkan warning saat install

- **Android 9+**: `posix_openpt()` baru fully support dari Android 9
  target minSdk = 28

- **SELinux**: perlu test apakah `exec()` dari app context diblok SELinux
  kemungkinan butuh `execve()` via JNI, bukan `ProcessBuilder`
