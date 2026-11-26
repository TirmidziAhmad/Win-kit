#!/usr/bin/env bash
# qemu_runner.sh - Menjalankan instalasi Windows di dalam QEMU/KVM
# Mendukung TPM 2.0 (via swtpm) dan Secure Boot (via OVMF secboot) untuk Windows 11

start_swtpm() {
    # Membuat dan menjalankan swtpm (software TPM 2.0 emulator)
    mkdir -p "$SWTPM_STATE_DIR"

    # Hentikan instance swtpm lama jika ada
    if [[ -f "$SWTPM_STATE_DIR/swtpm.pid" ]]; then
        local old_pid
        old_pid=$(cat "$SWTPM_STATE_DIR/swtpm.pid" 2>/dev/null || true)
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            kill "$old_pid" 2>/dev/null || true
            sleep 0.5
        fi
        rm -f "$SWTPM_STATE_DIR/swtpm.pid"
    fi

    swtpm socket \
        --tpmstate dir="$SWTPM_STATE_DIR" \
        --ctrl type=unixio,path="$SWTPM_STATE_DIR/swtpm-sock" \
        --tpm2 \
        --log level=0 \
        --daemon \
        --pid file="$SWTPM_STATE_DIR/swtpm.pid"

    # Tunggu socket siap
    local retries=0
    while [[ ! -S "$SWTPM_STATE_DIR/swtpm-sock" ]] && (( retries < 20 )); do
        sleep 0.1
        ((retries++))
    done

    if [[ ! -S "$SWTPM_STATE_DIR/swtpm-sock" ]]; then
        echo -e "\033[1;31m[ERROR] swtpm gagal dimulai! Socket tidak ditemukan.\033[0m"
        return 1
    fi

    echo -e "\033[1;32m[OK]\033[0m swtpm TPM 2.0 emulator aktif."
    return 0
}

stop_swtpm() {
    if [[ -f "$SWTPM_STATE_DIR/swtpm.pid" ]]; then
        local pid
        pid=$(cat "$SWTPM_STATE_DIR/swtpm.pid" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "$SWTPM_STATE_DIR/swtpm.pid"
    fi
}

run_windows_install() {
    local target_disk="$1"
    local iso_path="$2"
    local boot_mode="$3"   # "legacy" atau "uefi"
    local bypass_dir="$4"

    xhost +SI:localuser:root >/dev/null 2>&1 || true

    echo ""
    echo -e "\033[1;36m=========================================================\033[0m"
    echo -e "\033[1;32mMEMULAI QEMU INSTALLER WINDOWS\033[0m"
    echo -e "Target Disk : \033[1;33m$target_disk\033[0m"
    echo -e "Boot Mode   : \033[1;35m${boot_mode^^}\033[0m"

    local bypass_args=()
    if [[ -n "$bypass_dir" && -d "$bypass_dir" ]]; then
        bypass_args+=(
            -drive "file=fat:rw:$bypass_dir,id=bypass_usb,if=none,format=raw"
            -device "usb-storage,drive=bypass_usb"
        )
    fi

    if [[ "$boot_mode" == "legacy" ]]; then
        echo -e "TPM/SecBoot : \033[1;33mTidak tersedia (Legacy BIOS)\033[0m"
        echo -e "Bypass Media: \033[1;32mAktif (Auto TPM/SecureBoot/Akun Lokal)\033[0m"
        echo -e "\033[1;36m=========================================================\033[0m"
        echo "Petunjuk:"
        echo "1. Saat muncul 'Press any key to boot from CD or DVD...', segera klik di jendela dan tekan Spasi."
        echo "2. Pada pemilihan partisi, pilih Unallocated Space lalu klik Next."
        echo "3. Setelah proses salin file selesai dan Windows melakukan reboot otomatis pertama kali,"
        echo "   JANGAN tekan tombol apa pun (biarkan Windows boot dari disk)."
        echo ""
        echo -e "\033[1;33m[TIP] Jika OOBE tetap minta sign-in Microsoft Account:\033[0m"
        echo "  Tekan Shift+F10 → ketik: ipconfig /release → lalu: logoff"
        echo "  Pilih 'I don't have internet' → 'Continue with limited setup'"
        echo -e "\033[1;33m[TIP] Mengembalikan internet setelah bypass:\033[0m"
        echo "  Buka CMD → ketik: ipconfig /renew"
        echo ""

        sudo --preserve-env=DISPLAY,WAYLAND_DISPLAY,XDG_RUNTIME_DIR,XAUTHORITY qemu-system-x86_64 \
            -enable-kvm \
            -machine pc,accel=kvm \
            -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time \
            -smp "$VM_CPUS" \
            -m "$VM_RAM" \
            -device ahci,id=ahci \
            -drive file="$target_disk",format=raw,if=none,id=target_ssd,cache=writeback,aio=threads \
            -device ide-hd,bus=ahci.0,drive=target_ssd,bootindex=2 \
            -drive file="$iso_path",media=cdrom,if=none,id=cdrom0,readonly=on \
            -device ide-cd,bus=ahci.1,drive=cdrom0,bootindex=1 \
            -boot order=d,menu=on \
            -usb -device usb-tablet \
            "${bypass_args[@]}" \
            -vga std \
            -display gtk \
            -net nic,model=e1000 -net user
    else
        # === Mode UEFI dengan TPM 2.0 + Secure Boot ===

        # Tentukan firmware: gunakan Secure Boot jika tersedia
        local ovmf_code="$OVMF_CODE"
        local secboot_label="Tidak aktif"
        if [[ -f "$OVMF_CODE_SECBOOT" ]]; then
            ovmf_code="$OVMF_CODE_SECBOOT"
            secboot_label="\033[1;32mAktif (OVMF Secure Boot)\033[0m"
        else
            secboot_label="\033[1;33mTidak tersedia (file secboot tidak ditemukan)\033[0m"
        fi

        # Mulai swtpm untuk TPM 2.0
        local tpm_args=()
        local tpm_label="\033[1;33mTidak tersedia (swtpm belum terinstal)\033[0m"
        if command -v swtpm >/dev/null 2>&1; then
            if start_swtpm; then
                tpm_args+=(
                    -chardev "socket,id=chrtpm,path=$SWTPM_STATE_DIR/swtpm-sock"
                    -tpmdev "emulator,id=tpm0,chardev=chrtpm"
                    -device "tpm-tis,tpmdev=tpm0"
                )
                tpm_label="\033[1;32mAktif (swtpm TPM 2.0)\033[0m"
                # Daftarkan trap untuk membersihkan swtpm saat selesai
                trap 'stop_swtpm' EXIT
            fi
        fi

        echo -e "Secure Boot : $secboot_label"
        echo -e "TPM 2.0     : $tpm_label"
        echo -e "Bypass Media: \033[1;32mAktif (Fallback auto bypass)\033[0m"
        echo -e "\033[1;36m=========================================================\033[0m"
        echo "Petunjuk:"
        echo "1. Saat muncul 'Press any key to boot from CD or DVD...', segera klik di jendela dan tekan Spasi."
        echo "2. Pada pemilihan partisi, pilih Unallocated Space lalu klik Next."
        echo "3. Setelah proses salin file selesai dan Windows melakukan reboot otomatis pertama kali,"
        echo "   JANGAN tekan tombol apa pun (biarkan Windows boot dari disk)."
        echo ""
        echo -e "\033[1;33m[TIP] Jika OOBE tetap minta sign-in Microsoft Account:\033[0m"
        echo "  Tekan Shift+F10 → ketik: ipconfig /release → lalu: logoff"
        echo "  Pilih 'I don't have internet' → 'Continue with limited setup'"
        echo -e "\033[1;33m[TIP] Mengembalikan internet setelah bypass:\033[0m"
        echo "  Buka CMD → ketik: ipconfig /renew"
        echo ""

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
            -device ahci,id=ahci \
            -drive file="$target_disk",format=raw,if=none,id=target_ssd,cache=unsafe \
            -device ide-hd,bus=ahci.0,drive=target_ssd,bootindex=2 \
            -drive file="$iso_path",media=cdrom,if=none,id=cdrom0,readonly=on \
            -device ide-cd,bus=ahci.1,drive=cdrom0,bootindex=1 \
            -usb -device usb-tablet \
            "${bypass_args[@]}" \
            -vga std \
            -display gtk \
            -net nic,model=e1000 -net user

        # Bersihkan swtpm setelah QEMU selesai
        stop_swtpm
    fi
}
