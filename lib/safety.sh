#!/usr/bin/env bash
# safety.sh - Deteksi disk dan proteksi disk sistem Linux host

get_protected_disks() {
    local protected=()
    # Deteksi disk yang memuat /, /boot, /home, dan swap
    for mount_pt in "/" "/boot" "/home"; do
        local dev
        dev=$(findmnt -no SOURCE "$mount_pt" 2>/dev/null || true)
        dev="${dev%%\[*}" # Hapus tag subvolume btrfs seperti [/@]
        if [[ -n "$dev" ]]; then
            local base_disk
            base_disk=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -n1 || true)
            if [[ -z "$base_disk" ]]; then
                base_disk=$(basename "$dev")
            fi
            # Jika itu mapper/luks, cari disk fisiknya
            if [[ "$base_disk" == mapper* || "$base_disk" == "root" ]]; then
                local slave
                slave=$(ls -1 /sys/class/block/"$base_disk"/slaves/ 2>/dev/null | head -n1 || true)
                if [[ -n "$slave" ]]; then
                    base_disk=$(lsblk -no PKNAME "/dev/$slave" 2>/dev/null | head -n1 || true)
                    [[ -z "$base_disk" ]] && base_disk="$slave"
                fi
            fi
            [[ -n "$base_disk" ]] && protected+=("/dev/$base_disk")
        fi
    done

    # Deteksi swap
    while read -r sdev; do
        if [[ -n "$sdev" && "$sdev" == /dev/* ]]; then
            local bdisk
            bdisk=$(lsblk -no PKNAME "$sdev" 2>/dev/null | head -n1 || true)
            [[ -n "$bdisk" ]] && protected+=("/dev/$bdisk")
        fi
    done < <(swapon --show=NAME --noheadings 2>/dev/null || true)

    # Hilangkan duplikat
    echo "${protected[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

select_target_disk() {
    local protected_disks
    protected_disks=$(get_protected_disks)

    echo -e "\033[1;36m=== MEMINDAI DISK PENYIMPANAN ===\033[0m"
    echo -e "\033[1;33mDisk Linux Host (TERPROTEKSI & DILINDUNGI):\033[0m $protected_disks"
    echo ""

    local available_disks=()
    local i=1

    while read -r disk size model tran; do
        local disk_path="/dev/$disk"
        local is_prot=0
        for p in $protected_disks; do
            if [[ "$disk_path" == "$p" ]]; then
                is_prot=1
                break
            fi
        done

        if [[ $is_prot -eq 0 ]]; then
            available_disks+=("$disk_path")
            echo -e "  \033[1;32m[$i]\033[0m \033[1m$disk_path\033[0m - $model ($size, $tran)"
            # Tampilkan partisi yang ada di dalam disk
            lsblk -o NAME,SIZE,FSTYPE,LABEL "$disk_path" | sed 's/^/      /'
            ((i++))
        fi
    done < <(lsblk -dno NAME,SIZE,MODEL,TRAN -e 7,11)

    if [[ ${#available_disks[@]} -eq 0 ]]; then
        echo -e "\033[1;31m[!] Tidak ada disk sekunder yang terdeteksi!\033[0m"
        echo "Pastikan SSD/HDD target sudah terhubung ke PC."
        return 1
    fi

    echo ""
    local choice
    while true; do
        read -rp "Pilih nomor disk target (1-${#available_disks[@]}) atau [b]atal: " choice
        if [[ "$choice" =~ ^[bB]$ ]]; then
            echo "Dibatalkan."
            return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#available_disks[@]} )); then
            SELECTED_DISK="${available_disks[$((choice-1))]}"
            break
        fi
        echo "Pilihan tidak valid."
    done

    local model
    model=$(lsblk -dno MODEL "$SELECTED_DISK" | xargs)
    echo ""
    echo -e "\033[1;31mPERINGATAN:\033[0m Anda memilih disk: \033[1;33m$SELECTED_DISK ($model)\033[0m"
    echo -e "Semua data di disk ini dapat dihapus/diubah selama proses instalasi."
    read -rp "Ketik 'YA' dengan huruf besar untuk mengonfirmasi: " confirm
    if [[ "$confirm" != "YA" ]]; then
        echo "Konfirmasi gagal. Dibatalkan demi keamanan."
        return 1
    fi

    return 0
}

unmount_disk_partitions() {
    local target="$1"
    echo "Memastikan semua partisi di $target tidak sedang di-mount..."
    for part in "${target}"*; do
        if findmnt -rn -S "$part" >/dev/null 2>&1; then
            echo "  Unmounting $part..."
            sudo umount "$part" 2>/dev/null || udisksctl unmount -b "$part" 2>/dev/null || true
        fi
    done
}
