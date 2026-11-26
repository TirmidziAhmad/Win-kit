#!/usr/bin/env bash
# boot_tester.sh - Diagnostik dan pengujian bootloader disk tanpa ISO

check_boot_readiness() {
    local target="$1"
    echo -e "\033[1;36m=== MEMERIKSA STATUS BOOTLOADER ($target) ===\033[0m"

    local pttype
    pttype=$(lsblk -dno PTTYPE "$target" 2>/dev/null | xargs || true)
    echo "Tipe Tabel Partisi: $pttype"

    if [[ "$pttype" == "dos" ]]; then
        echo -e "\n[Mode Legacy MBR]:"
        local active_part
        active_part=$(lsblk -no NAME,PARTFLAGS "$target" | grep "0x80" | awk '{print $1}' || true)
        if [[ -n "$active_part" ]]; then
            echo -e "  \033[1;32m[OK]\033[0m Partisi aktif (Bootable): /dev/$active_part"
        else
            echo -e "  \033[1;31m[PERINGATAN]\033[0m Tidak ada partisi yang ditandai aktif (0x80)!"
        fi

        if sudo dd if="$target" bs=512 count=1 2>/dev/null | strings | grep -qiE "Invalid partition table|Missing operating system"; then
            echo -e "  \033[1;32m[OK]\033[0m Boot code MBR terdeteksi."
        else
            echo -e "  \033[1;33m[PERHATIAN]\033[0m Boot code MBR standar Windows tidak terdeteksi."
        fi
    elif [[ "$pttype" == "gpt" ]]; then
        echo -e "\n[Mode UEFI GPT]:"
        local efi_part
        efi_part=$(lsblk -no NAME,PARTTYPENAME "$target" | grep -i "EFI" | awk '{print $1}' || true)
        if [[ -n "$efi_part" ]]; then
            echo -e "  \033[1;32m[OK]\033[0m Partisi EFI terdeteksi: /dev/$efi_part"
        else
            echo -e "  \033[1;31m[PERINGATAN]\033[0m Partisi EFI tidak ditemukan di disk GPT ini!"
        fi
    fi
}

run_test_boot() {
    local target="$1"
    local mode="$2" # "legacy" atau "uefi"

    xhost +SI:localuser:root >/dev/null 2>&1 || true

    echo ""
    echo -e "\033[1;36m=========================================================\033[0m"
    echo -e "\033[1;32mMEMULAI TEST BOOT QEMU (${mode^^})\033[0m"
    echo -e "Target Disk : \033[1;33m$target\033[0m"
    echo -e "\033[1;36m=========================================================\033[0m"
    echo "Petunjuk: Jika Windows berhasil loading / muncul logo, artinya disk siap dipindahkan ke PC tujuan!"
    echo "Tutup jendela VM jika sudah selesai menguji."
    echo ""

    if [[ "$mode" == "legacy" ]]; then
        local pttype
        pttype=$(lsblk -dno PTTYPE "$target" 2>/dev/null | xargs || true)
        if [[ "$pttype" == "dos" ]]; then
            local active_part
            active_part=$(lsblk -no NAME,PARTFLAGS "$target" 2>/dev/null | grep "0x80" | awk '{print $1}' || true)
            if [[ -z "$active_part" ]]; then
                echo -e "\033[1;33m[AUTO-FIX] Terdeteksi partisi belum aktif! Mengaktifkan partisi 1 secara otomatis...\033[0m"
                sudo sfdisk --activate "$target" 1 || true
                sudo partprobe "$target" || true
                sleep 1
            fi
        fi

        sudo --preserve-env=DISPLAY,WAYLAND_DISPLAY,XDG_RUNTIME_DIR,XAUTHORITY qemu-system-x86_64 \
            -enable-kvm \
            -machine pc,accel=kvm \
            -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
            -smp "$VM_CPUS" \
            -m "$VM_RAM" \
            -device ahci,id=ahci \
            -drive file="$target",format=raw,if=none,id=target_ssd,cache=writeback,aio=threads \
            -device ide-hd,bus=ahci.0,drive=target_ssd \
            -boot c \
            -usb -device usb-tablet \
            -vga std \
            -display gtk
    else
        # Gunakan Secure Boot firmware jika tersedia
        local ovmf_code="$OVMF_CODE"
        if [[ -f "$OVMF_CODE_SECBOOT" ]]; then
            ovmf_code="$OVMF_CODE_SECBOOT"
        fi

        # Mulai swtpm jika tersedia (untuk test boot Windows 11)
        local tpm_args=()
        if command -v swtpm >/dev/null 2>&1; then
            source "$TOOL_DIR/lib/qemu_runner.sh"
            if start_swtpm; then
                tpm_args+=(
                    -chardev "socket,id=chrtpm,path=$SWTPM_STATE_DIR/swtpm-sock"
                    -tpmdev "emulator,id=tpm0,chardev=chrtpm"
                    -device "tpm-tis,tpmdev=tpm0"
                )
                trap 'stop_swtpm' EXIT
            fi
        fi

        cp -f "$OVMF_VARS_TEMPLATE" "$OVMF_VARS_TMP"
        sudo --preserve-env=DISPLAY,WAYLAND_DISPLAY,XDG_RUNTIME_DIR,XAUTHORITY qemu-system-x86_64 \
            -enable-kvm \
            -machine q35,accel=kvm,smm=on \
            -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
            -global driver=cfi.pflash01,property=secure,value=on \
            -smp "$VM_CPUS" \
            -m "$VM_RAM" \
            -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
            -drive if=pflash,format=raw,file="$OVMF_VARS_TMP" \
            "${tpm_args[@]}" \
            -drive file="$target",format=raw,index=0,media=disk,cache=writeback,aio=threads \
            -usb -device usb-tablet \
            -vga std \
            -display gtk

        # Bersihkan swtpm
        if command -v swtpm >/dev/null 2>&1; then
            stop_swtpm 2>/dev/null || true
        fi
    fi
}
