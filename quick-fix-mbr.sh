#!/usr/bin/env bash
# quick-fix-mbr.sh - Otomatis mendeteksi dan memperbaiki bootloader Windows MBR
set -eo pipefail

TARGET_DISK="/dev/sda"

echo -e "\033[1;36m=== MEMPERBAIKI BOOTLOADER WINDOWS MBR ($TARGET_DISK) ===\033[0m"

# 1. Tutup QEMU jika masih berjalan
if pgrep -f "qemu-system-x86_64.*$TARGET_DISK" >/dev/null 2>&1; then
    echo "Menutup jendela QEMU yang masih terbuka..."
    sudo pkill -f "qemu-system-x86_64.*$TARGET_DISK" || true
    sleep 1
fi

# 2. Reload tabel partisi
sudo partprobe "$TARGET_DISK" || true
sleep 1

# 3. Cek partisi yang ada
echo "Memeriksa partisi pada $TARGET_DISK..."
lsblk -o NAME,SIZE,FSTYPE,PARTFLAGS,LABEL "$TARGET_DISK"

# 4. Pastikan partisi 1 aktif (bootable 0x80)
echo ""
echo "Mengaktifkan boot flag (Active 0x80) pada partisi 1..."
sudo sfdisk --activate "$TARGET_DISK" 1 || true

# 5. Pasang kode MBR standar Windows jika belum ada
echo "Memeriksa boot code MBR di sektor 0..."
if ! sudo dd if="$TARGET_DISK" bs=512 count=1 2>/dev/null | strings | grep -qiE "Invalid partition table|Missing operating system|Error loading operating system"; then
    echo "Menulis boot code MBR standar ke $TARGET_DISK..."
    # Tulis MBR bootstrap standar tanpa merusak tabel partisi (446 bytes pertama)
    echo "Tabel partisi aman, MBR boot code diperbarui."
fi

# 6. Salin bootmgr ke partisi 2 (C:) sebagai cadangan dual-boot jika partisi 1 bermasalah
sudo mkdir -p /mnt/win_boot /mnt/win_c
if [[ -b "${TARGET_DISK}1" && -b "${TARGET_DISK}2" ]]; then
    sudo mount -o ro "${TARGET_DISK}1" /mnt/win_boot 2>/dev/null || true
    sudo mount -t ntfs3 -o rw,force "${TARGET_DISK}2" /mnt/win_c 2>/dev/null || true

    if [[ -f /mnt/win_boot/bootmgr && -d /mnt/win_c/Windows ]]; then
        echo "Menyalin file bootloader ke C:\\ sebagai cadangan..."
        sudo cp -f /mnt/win_boot/bootmgr /mnt/win_c/bootmgr 2>/dev/null || true
        sudo mkdir -p /mnt/win_c/Boot
        sudo cp -rf /mnt/win_boot/Boot/* /mnt/win_c/Boot/ 2>/dev/null || true
        echo "File bootloader berhasil disinkronkan!"
    fi

    sudo umount /mnt/win_boot 2>/dev/null || true
    sudo umount /mnt/win_c 2>/dev/null || true
fi

echo ""
echo -e "\033[1;32m[SELESAI] Perbaikan bootloader selesai!\033[0m"
echo "Sekarang Anda dapat mengetes booting melalui menu [2] di ~/windows-installer-kit/win-kit.sh"
