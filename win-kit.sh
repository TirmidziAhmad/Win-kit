#!/usr/bin/env bash
# win-kit.sh - Windows Installer Toolkit untuk Linux
# Berdasarkan praktik terbaik & pengalaman instalasi Windows (Legacy MBR & UEFI GPT)

set -o pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TOOL_DIR/config.env"
source "$TOOL_DIR/lib/safety.sh"
source "$TOOL_DIR/lib/unattended.sh"
source "$TOOL_DIR/lib/disk_prep.sh"
source "$TOOL_DIR/lib/qemu_runner.sh"
source "$TOOL_DIR/lib/boot_tester.sh"

check_dependencies() {
    local missing=()
    local optional_missing=()
    for cmd in qemu-system-x86_64 sfdisk mkfs.vfat wipefs; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if [[ ! -f "$OVMF_CODE" ]]; then
        missing+=("edk2-ovmf (file: $OVMF_CODE)")
    fi

    # Cek dependensi opsional untuk Windows 11 (TPM 2.0 + Secure Boot)
    if ! command -v swtpm >/dev/null 2>&1; then
        optional_missing+=("swtpm (TPM 2.0 emulator)")
    fi
    if [[ ! -f "$OVMF_CODE_SECBOOT" ]]; then
        optional_missing+=("edk2-ovmf secure boot (file: $OVMF_CODE_SECBOOT)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "\033[1;31m[ERROR] Dependensi berikut belum terinstal:\033[0m"
        for m in "${missing[@]}"; do
            echo "  - $m"
        done
        echo "Silakan install melalui pacman: sudo pacman -S qemu-desktop edk2-ovmf dosfstools util-linux"
        exit 1
    fi

    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        echo -e "\033[1;33m[PERINGATAN] Komponen opsional untuk Windows 11 (TPM 2.0 + Secure Boot):\033[0m"
        for m in "${optional_missing[@]}"; do
            echo -e "  - \033[1;33m$m\033[0m (belum terinstal)"
        done
        echo -e "  Install: \033[1msudo pacman -S swtpm edk2-ovmf\033[0m"
        echo -e "  Tanpa komponen ini, win-kit tetap bisa install Windows 11 via registry bypass."
        echo ""
        sleep 2
    fi
}

find_iso_files() {
    local isos=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && isos+=("$f")
    done < <(find "$DEFAULT_ISO_DIR" "$TOOL_DIR" -maxdepth 2 -type f -name "*.iso" 2>/dev/null || true)
    
    if [[ ${#isos[@]} -eq 0 ]]; then
        echo ""
    else
        echo "${isos[@]}"
    fi
}

select_iso_file() {
    local raw_isos
    raw_isos=$(find_iso_files)
    local iso_list=()
    read -r -a iso_list <<< "$raw_isos"

    echo -e "\033[1;36m=== MEMILIH FILE ISO WINDOWS ===\033[0m"
    if [[ ${#iso_list[@]} -gt 0 ]]; then
        echo "File ISO terdeteksi di sistem:"
        local idx=1
        for iso in "${iso_list[@]}"; do
            local sz
            sz=$(du -h "$iso" 2>/dev/null | awk '{print $1}')
            echo -e "  \033[1;32m[$idx]\033[0m $(basename "$iso") \033[1;30m($sz)\033[0m"
            ((idx++))
        done
        echo -e "  \033[1;33m[m]\033[0m Masukkan path file ISO secara manual"
        echo ""
        read -rp "Pilih nomor ISO (1-${#iso_list[@]}) atau [m]: " iso_choice
        if [[ "$iso_choice" =~ ^[0-9]+$ ]] && (( iso_choice >= 1 && iso_choice <= ${#iso_list[@]} )); then
            SELECTED_ISO="${iso_list[$((iso_choice-1))]}"
            return 0
        fi
    fi

    while true; do
        read -rp "Masukkan path lengkap file .iso Windows: " manual_iso
        if [[ -f "$manual_iso" && "$manual_iso" == *.iso ]]; then
            SELECTED_ISO="$manual_iso"
            return 0
        fi
        echo "File ISO tidak ditemukan atau tidak valid. Silakan coba lagi."
    done
}

menu_install_new() {
    clear
    echo -e "\033[1;34m=========================================================\033[0m"
    echo -e "\033[1;37m        PANDUAN INSTALASI WINDOWS BARU KE DISK           \033[0m"
    echo -e "\033[1;34m=========================================================\033[0m"

    # 1. Pilih Disk
    if ! select_target_disk; then
        return
    fi

    # 2. Unmount partisi jika ada
    unmount_disk_partitions "$SELECTED_DISK"

    # 3. Pilih ISO
    echo ""
    select_iso_file

    # 4. Pilih Boot Mode
    echo ""
    echo -e "\033[1;36m=== PILIH MODE BOOT KOMPUTER TUJUAN ===\033[0m"
    echo -e "  \033[1;32m[1]\033[0m \033[1mLegacy BIOS (MBR)\033[0m"
    echo "      Cocok untuk: PC/Laptop generasi lama, motherboard dengan CSM diaktifkan,"
    echo "      atau PC yang sebelumnya stuck di '_' jika pakai UEFI."
    echo -e "  \033[1;32m[2]\033[0m \033[1mUEFI (GPT)\033[0m"
    echo "      Cocok untuk: PC/Laptop modern (~2016 ke atas) dengan UEFI murni."
    echo ""
    local boot_choice
    local boot_mode="legacy"
    read -rp "Pilihan mode boot (1 atau 2, default 1): " boot_choice
    if [[ "$boot_choice" == "2" ]]; then
        boot_mode="uefi"
    else
        boot_mode="legacy"
    fi

    # 5. Format awal tabel partisi
    echo ""
    read -rp "Apakah ingin mengosongkan/membersihkan tabel partisi disk terlebih dahulu? [Y/n]: " prep_choice
    if [[ "$prep_choice" =~ ^[yY]?$ ]]; then
        if [[ "$boot_mode" == "legacy" ]]; then
            clean_disk_partition_table "$SELECTED_DISK" "mbr"
        else
            clean_disk_partition_table "$SELECTED_DISK" "gpt"
        fi
    fi

    # 6. Generate bypass media (hanya jika Windows 11)
    local bypass_dir=""
    if [[ "$SELECTED_ISO" =~ [wW]in(dows)?[[:space:]_-]*11 ]]; then
        echo "Windows 11 terdeteksi: Menyiapkan media bypass TPM & Secure Boot..."
        bypass_dir=$(generate_bypass_media)
    else
        echo "Windows 10 / lainnya: Melewati pembuatan media bypass (tidak diperlukan)..."
    fi

    # 7. Jalankan QEMU Installer
    run_windows_install "$SELECTED_DISK" "$SELECTED_ISO" "$boot_mode" "$bypass_dir"
}

menu_test_boot() {
    clear
    echo -e "\033[1;34m=========================================================\033[0m"
    echo -e "\033[1;37m        PENGUJIAN BOOTING DISK WINDOWS DI QEMU           \033[0m"
    echo -e "\033[1;34m=========================================================\033[0m"

    if ! select_target_disk; then
        return
    fi

    unmount_disk_partitions "$SELECTED_DISK"

    echo ""
    echo -e "\033[1;36m=== PILIH MODE PENGUJIAN ===\033[0m"
    echo -e "  \033[1;32m[1]\033[0m Test Boot Mode Legacy BIOS (SeaBIOS)"
    echo -e "  \033[1;32m[2]\033[0m Test Boot Mode UEFI (OVMF)"
    echo ""
    local mode_choice
    read -rp "Pilih mode uji (1 atau 2, default 1): " mode_choice
    local mode="legacy"
    [[ "$mode_choice" == "2" ]] && mode="uefi"

    run_test_boot "$SELECTED_DISK" "$mode"
}

menu_diagnostics() {
    clear
    echo -e "\033[1;34m=========================================================\033[0m"
    echo -e "\033[1;37m        DIAGNOSTIK BOOTLOADER DISK TARGET                \033[0m"
    echo -e "\033[1;34m=========================================================\033[0m"

    if ! select_target_disk; then
        return
    fi

    check_boot_readiness "$SELECTED_DISK"
    echo ""
    read -rp "Tekan Enter untuk kembali ke menu utama..."
}

menu_winpe_rescue() {
    clear
    echo -e "\033[1;34m=========================================================\033[0m"
    echo -e "\033[1;37m        RESCUE CONSOLE (WinPE COMMAND PROMPT)            \033[0m"
    echo -e "\033[1;34m=========================================================\033[0m"
    echo "Membuka ISO Windows di QEMU untuk menjalankan bcdboot/bootsect manual jika diperlukan."
    echo ""

    if ! select_target_disk; then
        return
    fi

    unmount_disk_partitions "$SELECTED_DISK"
    select_iso_file

    echo ""
    echo -e "Pilih mode rescue: \033[1;32m[1]\033[0m Legacy BIOS | \033[1;32m[2]\033[0m UEFI"
    read -rp "Pilihan (1/2, default 1): " rmode
    local mode="legacy"
    [[ "$rmode" == "2" ]] && mode="uefi"

    local bypass_dir
    bypass_dir=$(generate_bypass_media)

    echo ""
    echo "TIPS: Begitu installer Windows muncul, langsung tekan Shift+F10 untuk buka Command Prompt."
    echo ""
    run_windows_install "$SELECTED_DISK" "$SELECTED_ISO" "$mode" "$bypass_dir"
}

main() {
    check_dependencies

    while true; do
        clear
        echo -e "\033[1;34m=========================================================\033[0m"
        echo -e "\033[1;37m       WINDOWS INSTALLER & REPAIR TOOLKIT (LINUX)        \033[0m"
        echo -e "\033[1;34m=========================================================\033[0m"
        echo -e "  \033[1;32m[1]\033[0m Install Windows Baru ke SSD/HDD Target"
        echo -e "  \033[1;32m[2]\033[0m Test Booting Disk di QEMU (Cek sebelum pindah PC)"
        echo -e "  \033[1;32m[3]\033[0m Diagnostik Bootloader Disk (MBR/GPT/VBR Check)"
        echo -e "  \033[1;32m[4]\033[0m Rescue Console (Buka WinPE CMD untuk perbaikan)"
        echo -e "  \033[1;31m[0]\033[0m Keluar"
        echo -e "\033[1;34m=========================================================\033[0m"
        echo ""
        local opt
        read -rp "Pilih menu (0-4): " opt
        case "$opt" in
            1) menu_install_new ;;
            2) menu_test_boot ;;
            3) menu_diagnostics ;;
            4) menu_winpe_rescue ;;
            0) echo "Sampai jumpa!"; exit 0 ;;
            *) echo "Pilihan tidak valid."; sleep 1 ;;
        esac
    done
}

main "$@"
