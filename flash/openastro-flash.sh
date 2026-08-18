#!/bin/bash
# OpenAstro StellaVita flash tool (Linux + macOS).
#
# Just run it:   ./openastro-flash.sh
#
# You get a menu:
#   1) Backup   - save the current eMMC (stock ToupTek OS) to a compressed
#                 image + .sha256 in images/
#   2) Flash    - write the OpenAstro image to the eMMC (downloads the
#                 latest release image automatically if not present)
#   3) Restore  - write a saved backup back (return to stock ToupTek)
#
# Everything else is automatic: rpiboot is installed on first use, the eMMC
# is detected as the disk that newly appears (never guessed), size-checked
# (~32 GB), and you confirm the device before anything is written.
#
# ALWAYS make a backup before the first flash - the stock ToupTek OS is not
# downloadable anywhere; your backup is the only way back.
#
# Scripting: the menu choices also work as subcommands -
#   ./openastro-flash.sh backup  [out.img.xz]
#   ./openastro-flash.sh flash   [image.img.xz]
#   ./openastro-flash.sh restore [backup.img.xz]
set -euo pipefail

REPODIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGESDIR="$REPODIR/images"
OS="$(uname -s)"
RELEASE_API="https://api.github.com/repos/open-astro/openastro-touptek-stellavita/releases/latest"
IMAGE_NAME="openastro-touptek-stellavita.img.xz"

log()  { echo "[flash] $*"; }
die()  { echo "[flash] ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required - $2"; }

# ------------------------------------------------------------
# rpiboot (installed automatically on first use)
# ------------------------------------------------------------
ensure_rpiboot() {
    command -v rpiboot >/dev/null 2>&1 && return 0
    echo
    log "rpiboot (Raspberry Pi usbboot) is needed to talk to the StellaVita's eMMC."
    read -r -p "Install it now? [Y/n] " a
    case "$a" in [nN]*) die "rpiboot is required - aborting." ;; esac
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
# OpenAstro image (downloaded automatically if missing)
# ------------------------------------------------------------
fetch_openastro_image() {
    IMAGE="$IMAGESDIR/$IMAGE_NAME"
    [ -f "$IMAGE" ] && { log "Using local image: $IMAGE"; return 0; }
    need curl "install curl"
    echo
    log "OpenAstro image not found locally - fetching the latest release..."
    local url sha_url
    url="$(curl -fsSL "$RELEASE_API" | grep -o "https://[^\"]*/$IMAGE_NAME" | head -1)"
    [ -n "$url" ] || die "could not find $IMAGE_NAME in the latest GitHub release."
    sha_url="$(curl -fsSL "$RELEASE_API" | grep -o "https://[^\"]*/$IMAGE_NAME.sha256" | head -1)"
    mkdir -p "$IMAGESDIR"
    log "Downloading $url (~550 MB)..."
    curl -fL --progress-bar -o "$IMAGE.part" "$url"
    if [ -n "$sha_url" ]; then
        curl -fsSL -o "$IMAGE.sha256" "$sha_url"
        log "Verifying checksum..."
        local want got
        want="$(awk '{print $1}' "$IMAGE.sha256")"
        if [ "$OS" = Darwin ]; then got="$(shasum -a 256 "$IMAGE.part" | awk '{print $1}')"
        else got="$(sha256sum "$IMAGE.part" | awk '{print $1}')"; fi
        [ "$want" = "$got" ] || die "checksum mismatch on downloaded image - delete $IMAGE.part and retry."
        log "Checksum OK."
    fi
    mv "$IMAGE.part" "$IMAGE"
    log "Image saved to $IMAGE"
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
    ensure_rpiboot
    local before after new d
    before="$(list_disks)"

    echo
    echo "Put the StellaVita in USB device-boot mode now:"
    echo "  1. Make sure the StellaVita is unplugged (no DC power)."
    echo "  2. Open the case and short the two nRPIBOOT pads next to the"
    echo "     SD-card slot with a jumper wire (keep them shorted). Photo:"
    echo "     https://www.openastro.net/img/sbc/de035a79-7781-48b7-9d2b-e7f67dc5d166.webp"
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
have_backup() { compgen -G "$IMAGESDIR/stellavita-stock-backup-*.img.xz" >/dev/null 2>&1; }
latest_backup() { ls -t "$IMAGESDIR"/stellavita-stock-backup-*.img.xz 2>/dev/null | head -1; }

cmd_backup() {
    local out="${1:-$IMAGESDIR/stellavita-stock-backup-$(date +%Y%m%d).img.xz}"
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
    log "$label written. Disconnect USB, remove the jumper, and power-cycle."
}

cmd_flash() {
    local img="${1:-}"
    if [ -z "$img" ]; then
        fetch_openastro_image
        img="$IMAGE"
    fi
    echo
    echo "This OVERWRITES the eMMC with the OpenAstro image."
    if ! have_backup; then
        echo "No stock backup found in $IMAGESDIR - the stock ToupTek OS is NOT"
        echo "downloadable anywhere; a backup is the only way back to stock."
        read -r -p "Make a backup first? [Y/n] " a
        case "$a" in [nN]*) ;; *)
            cmd_backup
            echo
            echo "Backup done - now the flash. Unplug the USB cable, then plug it"
            echo "back in (keep the jumper shorted) so the board can re-enter boot mode."
            ;;
        esac
    fi
    read -r -p "Continue with the flash? [y/N] " a; case "$a" in [yY]) ;; *) exit 1 ;; esac
    write_image "$img" "OpenAstro image"
}

cmd_restore() {
    local img="${1:-}"
    if [ -z "$img" ]; then
        img="$(latest_backup || true)"
        [ -n "$img" ] || die "no backup found in $IMAGESDIR - pass one: $0 restore <backup.img.xz>"
    fi
    echo
    echo "This OVERWRITES the eMMC with the stock ToupTek backup:"
    echo "  $img"
    read -r -p "Continue? [y/N] " a; case "$a" in [yY]) ;; *) exit 1 ;; esac
    write_image "$img" "stock ToupTek backup"
}

menu() {
    echo
    echo "OpenAstro StellaVita flash tool"
    echo "==============================="
    echo
    echo "  1) Backup  - save the stock ToupTek OS from the eMMC (do this first!)"
    echo "  2) Flash   - write the OpenAstro image to the eMMC"
    echo "  3) Restore - write a stock backup back to the eMMC"
    echo "  q) Quit"
    echo
    read -r -p "Choose [1/2/3/q]: " choice
    case "$choice" in
    1) cmd_backup ;;
    2) cmd_flash ;;
    3) cmd_restore ;;
    q|Q) exit 0 ;;
    *) die "invalid choice '$choice'" ;;
    esac
}

case "${1:-}" in
"")              menu ;;
backup)          shift; cmd_backup "$@" ;;
flash)           shift; cmd_flash "$@" ;;
restore)         shift; cmd_restore "$@" ;;
install-rpiboot) ensure_rpiboot ;;
-h|--help|help)  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//' ;;
*)               die "unknown command '${1}' - run with no arguments for the menu." ;;
esac
