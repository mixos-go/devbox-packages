# devbox/

Source files bundled into the **Termux bootstrap zip** and shared into the
Debian VM at runtime via **virtio-fs** (not baked into the OS image).

## Structure

```
devbox/
├── opensandbox/     → $PREFIX/share/devbox/opensandbox/  (Termux)
│                    → /mnt/devbox/opensandbox/            (inside VM via virtio-fs)
└── mobile-agent/   → $PREFIX/share/devbox/mobile-agent/  (Termux)
                     → /mnt/devbox/mobile-agent/           (inside VM via virtio-fs)
```

## Full flow

```
[CI — build Debian OS image (pure OS, no source code)]
build-debian-image.sh
  └── debootstrap Debian bookworm (with Python, Go, SSH, virtiofs in fstab)
  └── NO opensandbox baked in — it comes from Termux side via virtio-fs
  └── gzip → debian-rootfs-aarch64.img.gz → upload to GitHub Releases

[CI — build bootstrap zip]
generate-bootstraps.sh
  └── copy devbox/opensandbox/ → $PREFIX/share/devbox/opensandbox/ (in zip)
  └── upload bootstrap-aarch64.zip → GitHub Releases

[User — first launch]
1. APK installs → bootstrap zip extracted to $PREFIX
   └── $PREFIX/share/devbox/opensandbox/  ← source is HERE (Termux side)
2. devbox-second-stage.sh runs
   └── downloads debian-rootfs-aarch64.img.gz → ~/.devbox/debian.img
3. devbox-start launches crosvm:
   └── --shared-dir "$PREFIX/share/devbox:devbox:type=fs"
   └── VM boots → systemd mounts virtiofs → /mnt/devbox/ appears in VM

[User — Setup Cloud Sandbox]
4. devbox-shell 'bash /mnt/devbox/opensandbox/install.sh'
   └── mounts virtiofs if not yet mounted
   └── apt install python3 golang-go curl
   └── pip install fastapi uvicorn pydantic ...
   └── cp /mnt/devbox/opensandbox/ → ~/opensandbox/
   └── build Go components
   └── install config → ~/.sandbox.toml

[User — Start Server]
5. devbox-shell 'bash ~/opensandbox/start.sh'
   └── uvicorn on 127.0.0.1:8080 inside VM

[Update opensandbox]
→ just update devbox/opensandbox/ source + release new bootstrap zip
→ NO need to rebuild debian.img
→ user re-runs install.sh to get updated version
```
