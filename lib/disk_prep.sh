#!/usr/bin/env bash
# disk_prep.sh - Inisialisasi awal tabel partisi (MBR vs GPT) untuk mencegah error installer

clean_disk_partition_table() {
    local target="$1"
    local mode="$2" # "mbr" atau "gpt"

    echo "Membersihkan tabel partisi pada $target..."
    sudo dd if=/dev/zero of="$target" bs=1M count=10 status=none 2>/dev/null || true
    sudo wipefs -a "$target" >/dev/null 2>&1 || true

    if [[ "$mode" == "mbr" ]]; then
        echo "Menulis tabel partisi MBR (DOS) bersih pada $target..."
        echo 'label: dos' | sudo sfdisk "$target" >/dev/null 2>&1
    elif [[ "$mode" == "gpt" ]]; then
        echo "Menulis tabel partisi GPT bersih pada $target..."
        echo 'label: gpt' | sudo sfdisk "$target" >/dev/null 2>&1
    fi

    sudo partprobe "$target" >/dev/null 2>&1 || true
    sleep 1
    echo "Disk $target siap untuk instalasi mode $mode!"
}
