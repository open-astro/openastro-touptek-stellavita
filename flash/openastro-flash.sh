#!/bin/bash
# OpenAstro StellaVita flash tool (Linux + macOS).
#
# The StellaVita is a Raspberry Pi CM4 with a 32 GB eMMC - there is no SD
# card to pull. The eMMC is exposed as a USB mass-storage disk via rpiboot
# (Raspberry Pi usbboot) with the board in USB device-boot mode. This script
# wraps the whole workflow:
#
#   install-rpiboot            build/install rpiboot for this OS
#   backup  [out.img.xz]       save the current eMMC (stock ToupTek OS) to a
#                              compressed image + .sha256
#   flash   [openastro.img.xz] write the OpenAstro image to the eMMC
#   restore <backup.img.xz>    write a saved backup back (return to stock)
#
# backup/flash/restore all: run rpiboot, wait for the eMMC to appear as a
# USB disk (RPi-MSD), confirm the target device with you, then read/write.
#
# ALWAYS run `backup` once before the first `flash` - that backup is the
# only way back to the stock ToupTek OS.
set -euo pipefail

REPODIR="$(cd "$(dirname "$0")/.." && pwd)"
OS="$(uname -s)"

log()  { echo "[flash] $*"; }
die()  { echo "[flash] ERROR: $*" >&2; exit 1; }

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required - $2"; }

# ------------------------------------------------------------
# rpiboot
# ------------------------------------------------------------
install_rpiboot() {
    if command -v rpiboot >/dev/null 2>&1; then
        log "rpiboot already installed: $(command -v rpiboot)"
        return 0
    fi
    case "$OS" in
    Linux)
        log "Installing build deps (sudo apt-get)..."
        sudo apt-get update -qq
        sudo apt-get install -y -qq git libusb-1.0-0-dev pkg-config build-essential
        local src; src="$(mktemp -d)"
        log "Building rpiboot from raspberrypi/usbboot..."
        git clone --depth 1 https://github.com/raspberrypi/usbboot "$src/usbboot"
        make -C "$src/usbboot"
        sudo make -C "$src/usbboot" install
        rm -rf "$src"
        ;;
    Darwin)
        need brew "install Homebrew from https://brew.sh first"
        log "Installing rpiboot via Homebrew..."
        brew install rpiboot || {
            # No bottle for this platform: build from source.
            brew install libusb pkg-config
            local src; src="$(mktemp -d)"
            git clone --depth 1 https://github.com/raspberrypi/usbboot "$src/usbboot"
            make -C "$src/usbboot"
            sudo install -m 755 "$src/usbboot/rpiboot" /usr/local/bin/rpiboot
            sudo mkdir -p /usr/local/share/rpiboot
            sudo cp -R "$src/usbboot/mass-storage-gadget64" /usr/local/share/rpiboot/ 2>/dev/null || true
            rm -rf "$src"
        }
        ;;
    *) die "unsupported OS '$OS' (use openastro-flash.ps1 on Windows)" ;;
    esac
    log "rpiboot installed: $(command -v rpiboot)"
}

# ------------------------------------------------------------
# Device discovery
# ------------------------------------------------------------
# Snapshot of disks that exist BEFORE rpiboot, so the eMMC is identified as
# the disk that newly appears - never guessed.
list_disks() {
    case "$OS" in
    Linux)  lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' ;;
    Darwin) diskutil list | awk '/^\/dev\/disk/{print $1}' | sed 's|/dev/||' ;;
    esac
}

run_rpiboot_and_find_device() {
    command -v rpiboot >/dev/null 2>&1 || die "rpiboot not found - run: $0 install-rpiboot"
    local before after new d
    before="$(list_disks)"

    echo
    echo "Put the StellaVita in USB device-boot mode now:"
    echo "  1. Make sure the StellaVita is unplugged (no DC power)."
    echo "  2. Short the nRPIBOOT pins with a jumper (keep them shorted)."
    echo "  3. Connect a USB-A (computer) to USB-C (StellaVita) data cable."
    echo "     The board powers up over USB - do NOT connect DC power."
    echo
    read -r -p "Press Enter when the pins are shorted and the USB cable is connected... " _
    log "Running rpiboot (waits for the CM4)..."
    # The mass-storage gadget exports the eMMC as a USB disk; -d picks the
    # gadget directory when rpiboot was built from source.
    sudo rpiboot -d mass-storage-gadget64 || sudo rpiboot

    log "Waiting for the eMMC to appear as a USB disk..."
    for _ in $(seq 1 60); do
        after="$(list_disks)"
        new="$(comm -13 <(echo "$before" | sort) <(echo "$after" | sort) || true)"
        if [ -n "$new" ]; then
            d="$(echo "$new" | head -1)"
            DEVICE="/dev/$d"
            break
        fi
        sleep 1
    done
    [ -n "${DEVICE:-}" ] || die "eMMC never appeared as a disk. Check the USB cable (must be data-capable) and boot mode."

    # Sanity: the StellaVita eMMC is 32 GB (~29 GiB); refuse anything wildly
    # different so a wrong disk can't be nuked.
    local size_bytes size_gb
    case "$OS" in
    Linux)  size_bytes="$(lsblk -bdno SIZE "$DEVICE")" ;;
    Darwin) size_bytes="$(diskutil info "$DEVICE" | sed -n 's/.*(\([0-9][0-9]*\) Bytes).*/\1/p' | head -1)" ;;
    esac
    size_gb=$(( ${size_bytes:-0} / 1000000000 ))
    log "Found new USB disk: $DEVICE (${size_gb} GB)"
    if [ "$size_gb" -lt 28 ] || [ "$size_gb" -gt 36 ]; then
        die "$DEVICE is ${size_gb} GB - not a 32 GB StellaVita eMMC. Aborting."
    fi

    echo
    echo "  >>> Target device: $DEVICE (${size_gb} GB) <<<"
    echo
    read -r -p "Type the device path again to confirm: " confirm
    [ "$confirm" = "$DEVICE" ] || die "confirmation mismatch - aborting."
}

unmount_device() {
    case "$OS" in
    Linux)  for p in "${DEVICE}"?*; do sudo umount "$p" 2>/dev/null || true; done ;;
    Darwin) diskutil unmountDisk "$DEVICE" >/dev/null ;;
    esac
}

raw_device() {
    # macOS: the raw (character) node is dramatically faster for dd.
    case "$OS" in
    Darwin) echo "${DEVICE/\/dev\/disk//dev/rdisk}" ;;
    *)      echo "$DEVICE" ;;
    esac
}

# ------------------------------------------------------------
# Commands
# ------------------------------------------------------------
cmd_backup() {
    local out="${1:-$REPODIR/images/stellavita-stock-backup-$(date +%Y%m%d).img.xz}"
    need xz "install xz-utils"
    [ -e "$out" ] && die "$out already exists - refusing to overwrite a backup."
    run_rpiboot_and_find_device
    unmount_device
    mkdir -p "$(dirname "$out")"
    log "Reading eMMC -> $out (32 GB read, takes a while)..."
    set -o pipefail
    if [ "$OS" = Darwin ]; then
        sudo dd if="$(raw_device)" bs=4m | xz -T0 -2 > "$out"
        ( cd "$(dirname "$out")" && shasum -a 256 "$(basename "$out")" > "$(basename "$out").sha256" )
    else
        sudo dd if="$(raw_device)" bs=4M status=progress | xz -T0 -2 > "$out"
        ( cd "$(dirname "$out")" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )
    fi
    log "Backup complete: $out ($(du -h "$out" | cut -f1))"
    log "Keep this file safe - it is the way back to the stock ToupTek OS."
}

write_image() {
    local img="$1" label="$2"
    [ -f "$img" ] || die "image not found: $img"
    run_rpiboot_and_find_device
    unmount_device
    log "Writing $label -> $DEVICE ..."
    set -o pipefail
    decompress() {
        case "$img" in
        *.xz) xz -dc "$img" ;;
        *.gz) gzip -dc "$img" ;;
        *)    cat "$img" ;;
        esac
    }
    if [ "$OS" = Darwin ]; then
        decompress | sudo dd of="$(raw_device)" bs=4m
    else
        decompress | sudo dd of="$(raw_device)" bs=4M status=progress conv=fsync
    fi
    sync
    case "$OS" in Darwin) diskutil eject "$DEVICE" || true ;; esac
    log "$label written. Disconnect USB, restore normal boot, and power-cycle."
}

cmd_flash() {
    local img="${1:-$REPODIR/images/openastro-touptek-stellavita.img.xz}"
    echo "This OVERWRITES the eMMC with the OpenAstro image."
    echo "Run '$0 backup' first if you have not - it is the only way back to stock."
    read -r -p "Continue? [y/N] " a; case "$a" in [yY]) ;; *) exit 1 ;; esac
    write_image "$img" "OpenAstro image"
}

cmd_restore() {
    local img="${1:?usage: $0 restore <backup.img.xz>}"
    echo "This OVERWRITES the eMMC with the stock ToupTek backup: $img"
    read -r -p "Continue? [y/N] " a; case "$a" in [yY]) ;; *) exit 1 ;; esac
    write_image "$img" "stock ToupTek backup"
}

case "${1:-}" in
install-rpiboot) install_rpiboot ;;
backup)          shift; cmd_backup "$@" ;;
flash)           shift; cmd_flash "$@" ;;
restore)         shift; cmd_restore "$@" ;;
*)               usage ;;
esac
