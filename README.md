# Windows Installer & Repair Toolkit for Linux

Toolkit otomatis untuk menginstal Windows pada SSD atau HDD sekunder langsung dari sistem Linux menggunakan QEMU/KVM, tanpa perlu membuat flashdisk bootable atau mengorbankan instalasi Linux utama.

## Untuk Siapa Toolkit Ini?

Toolkit ini dibuat untuk skenario spesifik:

> _"Saya punya PC/Laptop yang menjalankan Linux, dan ingin menginstall Windows di SSD/HDD kosong — lalu memindahkan SSD/HDD tersebut ke komputer lain."_

```
┌─────────────┐    QEMU/KVM     ┌─────────────┐              ┌─────────────┐
│  PC Linux   │ ──────────────► │  SSD Target  │ ──── cabut ──►│  PC Tujuan  │
│  (Host)     │  Install Win11  │  (Windows)   │   & pasang   │  (Windows)  │
└─────────────┘                 └─────────────┘              └─────────────┘
```

**Ini BUKAN:**
- Pengganti Rufus / Ventoy (pembuat bootable USB)
- Tool untuk dual-boot di satu disk
- Tool untuk Windows atau macOS

**Ini ADALAH:**
- Tool Linux-only yang menggunakan QEMU/KVM sebagai "mesin virtual sementara" untuk menginstall Windows langsung ke disk fisik
- SSD/HDD yang sudah diinstall bisa langsung dicabut dan dipakai di PC lain

---

## Fitur Utama

- **Proteksi Disk Linux Host Otomatis** — Disk utama Linux otomatis dikunci dari daftar pilihan. Wajib konfirmasi "YA" sebelum formatting dijalankan.
- **Dual Boot Mode** — Support Legacy BIOS (MBR) dan UEFI (GPT).
- **TPM 2.0 & Secure Boot** — Emulasi hardware via `swtpm` dan OVMF Secure Boot firmware. Windows 11 terinstall tanpa error.
- **Auto Bypass OOBE** — Melewati sign-in Microsoft Account, pengecekan hardware, dan langsung membuat akun lokal via `autounattend.xml`.
- **Test Boot** — Tes apakah SSD bisa booting sebelum dipindah ke PC tujuan.
- **Rescue Console** — Buka WinPE Command Prompt untuk `bcdboot`, `bootsect`, atau `diskpart` manual.

---

## Prasyarat

### Arch Linux / Arch-based

```bash
sudo pacman -S qemu-desktop edk2-ovmf swtpm dosfstools util-linux
```

### Paket yang dibutuhkan

| Paket | Fungsi |
|---|---|
| `qemu-desktop` | Virtual machine (QEMU/KVM) |
| `edk2-ovmf` | UEFI firmware (termasuk Secure Boot) |
| `swtpm` | Emulator TPM 2.0 |
| `dosfstools` | Formatting partisi FAT (bypass media) |
| `util-linux` | `sfdisk`, `wipefs`, dan tools partisi |

> [!NOTE]
> `swtpm` dan Secure Boot bersifat **opsional** — tanpa keduanya, win-kit tetap bisa menginstall Windows 11 menggunakan registry bypass. Tapi dengan keduanya, instalasi jauh lebih mulus.

---

## Cara Menggunakan

### 1. Clone repository

```bash
git clone https://github.com/<username>/windows-installer-kit.git
cd windows-installer-kit
chmod +x win-kit.sh
```

### 2. Siapkan file ISO Windows

Letakkan file `.iso` Windows 10/11 di dalam folder `windows-installer-kit/` atau di `~/Downloads/`. Win-kit akan otomatis mendeteksinya.

### 3. Hubungkan SSD/HDD target

Hubungkan SSD atau HDD tujuan ke PC Linux kamu (via USB adapter, docking station, atau SATA langsung).

### 4. Jalankan win-kit

```bash
sudo ./win-kit.sh
```

### 5. Pilih menu

```
=========================================================
       WINDOWS INSTALLER & REPAIR TOOLKIT (LINUX)
=========================================================
  [1] Install Windows Baru ke SSD/HDD Target
  [2] Test Booting Disk di QEMU (Cek sebelum pindah PC)
  [3] Diagnostik Bootloader Disk (MBR/GPT/VBR Check)
  [4] Rescue Console (Buka WinPE CMD untuk perbaikan)
  [0] Keluar
=========================================================
```

---

## Panduan Install Windows 11 (UEFI)

1. Pilih menu **[1]** → pilih disk target → pilih ISO Windows 11
2. Pilih mode boot **[2] UEFI (GPT)**
3. QEMU akan muncul dengan status:
   ```
   Secure Boot : Aktif (OVMF Secure Boot)
   TPM 2.0     : Aktif (swtpm TPM 2.0)
   ```
4. Tekan **Spasi** saat muncul _"Press any key to boot from CD or DVD..."_
5. Pilih bahasa → **Next** → **Install Now**
6. Pilih edisi Windows → Accept license
7. Pilih **Custom (advanced)** → pilih **Unallocated Space** → **Next**
8. Tunggu proses copy file selesai
9. Saat reboot otomatis, **jangan tekan apa-apa** (biarkan boot dari disk)
10. OOBE akan otomatis skip sign-in Microsoft Account → langsung masuk desktop ✅

---

## Tips & Troubleshooting

### Bypass Sign-in Microsoft Account (Manual)

Jika OOBE tetap meminta sign-in Microsoft Account, lakukan ini:

1. Di layar OOBE, tekan **Shift + F10** (buka Command Prompt)
2. Ketik:
   ```cmd
   ipconfig /release
   logoff
   ```
3. OOBE akan restart. Pilih **"I don't have internet"** → **"Continue with limited setup"**
4. Buat akun lokal seperti biasa

### Mengembalikan Internet Setelah Bypass

Setelah masuk Windows, buka Command Prompt dan ketik:

```cmd
ipconfig /renew
```

Atau cukup buka **Settings → Network & Internet** dan connect ke WiFi/Ethernet.

### Drive Virtual di QEMU

| Drive | Isi | Ada di SSD? |
|---|---|---|
| `C:` | Instalasi Windows | ✅ Ya |
| `D: CCCOMA_X64` | ISO Windows (virtual CD-ROM) | ❌ Tidak |
| `E: vvfat` | Bypass media (`autounattend.xml`) | ❌ Tidak |

> Drive `D:` dan `E:` hanya ada selama QEMU berjalan. SSD yang dipindah ke PC tujuan hanya berisi `C:`.

---

## Konfigurasi

Edit file `config.env` untuk mengubah alokasi resource VM:

```bash
# Alokasi RAM dan CPU untuk QEMU
VM_RAM="4G"
VM_CPUS="4"

# Folder pencarian ISO
DEFAULT_ISO_DIR="/home/<username>/Downloads"
```

---

## Struktur File

```
windows-installer-kit/
├── win-kit.sh              # Script utama (menu)
├── config.env              # Konfigurasi VM
├── README.md               # Dokumentasi
├── lib/
│   ├── safety.sh           # Proteksi disk Linux host
│   ├── disk_prep.sh        # Inisialisasi tabel partisi
│   ├── qemu_runner.sh      # QEMU launcher (TPM + Secure Boot)
│   ├── unattended.sh       # Generator autounattend.xml
│   └── boot_tester.sh      # Test boot & diagnostik
└── archive/                # Arsip/referensi
```

---

## Lisensi

MIT License
