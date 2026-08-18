# OpenAstro for ToupTek StellaVita

<img src="https://www.openastro.net/wp-content/uploads/2026/04/OpenAstro_logo.png" alt="OpenAstro logo" width="420">

OpenAstro OS for the **ToupTek StellaVita** (Raspberry Pi CM4 based): a
[Raspberry Pi OS Lite](https://www.raspberrypi.com/software/operating-systems/)
(arm64, no GUI, Debian 13 "Trixie") based image with the StellaVita's power
and USB hardware enabled, a WiFi access point, and everything ready for
[AlpacaBridge](https://github.com/open-astro/AlpacaBridge).

Everything from the
[StellaVita install guide](https://www.openastro.net/docs/sbc-install/touptek-stellavita)
is baked into the image:

- **12V power outputs** - GPIO 18, 10, 17, 4 driven high at boot via
  `config.txt`, so the DC outputs are live from power-on.
- **USB ports** - GPIO 9 and 11 power the Cypress USB hub, and the Renesas
  uPD720201 xHCI firmware (`renesas_usb_fw.mem`) is preinstalled and built
  into the initramfs, so the USB 3.0 ports work out of the box. The BCM2711's
  own USB 2.0 controller is enabled in host mode (`dtoverlay=dwc2` - vendor
  setup) for the internal USB 2.0 hub and microSD card reader.
- **Buzzer** - the OpenAstro jingle plays on the piezo (GPIO 12) once the
  board is up, so you know it's ready without a screen
  (`/usr/local/sbin/openastro-beep`).

The vendor unit's full hardware and software inventory - captured live from
a running StellaVita, with its original configs and scripts - lives in
[`hardware/stellavita-cm4-32g/`](hardware/stellavita-cm4-32g/).

## Supported hardware

| Device | Kernel | Status |
|--------|--------|--------|
| ToupTek StellaVita (Pi CM4) | Raspberry Pi OS stock | 🚧 Validation pending |

> **ZWO EAF/EFW:** the stock Raspberry Pi OS kernel ships with HIDRAW
> enabled, and the image bakes in a udev rule granting device access, so ZWO
> HID accessories should work out of the box.

## Install

### 1. Download + flash

Grab the latest `openastro-touptek-stellavita.img.xz` from the
[Releases](../../releases) page and flash it with
[Raspberry Pi Imager](https://www.raspberrypi.com/software/),
[balenaEtcher](https://etcher.balena.io/), or `dd`:

```bash
xzcat openastro-touptek-stellavita.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

(Use Imager's "No customisation" option - credentials and WiFi are already
baked in.)

### 2. Boot

Power on. The 12V outputs and USB ports come up with the board.

## First boot defaults

| Setting | Value |
|---------|-------|
| Hostname | `openastro` |
| Login | `astro` / `astro` - **change immediately:** `passwd` |
| WiFi AP | `OpenAstro-XXXX` (2.4 GHz, ch 6), password `12345678` |
| AP address | `172.24.1.1` (DHCP for clients) |
| Ethernet | DHCP |

`XXXX` is the last 4 hex digits of the board's WiFi MAC address (e.g.
`OpenAstro-915D`), applied automatically on first boot so multiple boards in
the same place each get a unique hotspot name.

Reach it over ethernet (`ssh astro@<ip>`) or by joining the `OpenAstro-XXXX`
WiFi. The access point starts automatically at every boot, so even if the
board can't be reached over your network you can always join its hotspot and
log in at `172.24.1.1`.

### Connect to your own network instead (optional)

All networking is managed by NetworkManager. The hotspot runs on a dedicated
virtual interface (`ap0`), concurrent with `wlan0` client mode, so joining
your own network - from AlpacaBridge's WiFi card in the web portal, or with
`nmcli` (`sudo nmcli dev wifi connect <SSID> password <pass>`) - does **not**
take down the hotspot. (One radio, one channel: while connected as a client
the hotspot follows the client network's channel.) You can also just use the
ethernet port.

## AlpacaBridge

[AlpacaBridge](https://github.com/open-astro/AlpacaBridge) is **preinstalled**
from the OpenAstro apt repository, so the device works at a dark site straight
from the flash - no internet required. When the device does have internet, it
stays current with `sudo apt update && sudo apt upgrade`.

## Build the image yourself

The release image is built from a stock Raspberry Pi OS Lite (arm64) image
plus the OpenAstro layer. On an **aarch64** host (an arm64 Debian box, or a
Pi itself - it's a native chroot, no emulation):

```bash
# 1. grab the latest Raspberry Pi OS Lite arm64 image
wget https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64-lite.img.xz

# 2. bake in the OpenAstro layer and repack
sudo apt install parted e2fsprogs dosfstools
sudo build/build-openastro-image.sh 2026-06-18-raspios-trixie-arm64-lite.img.xz images/openastro-touptek-stellavita.img.xz
```

- [`build/build-openastro-image.sh`](build/build-openastro-image.sh) - customizes
  the Raspberry Pi OS image in a chroot and produces a compressed, flashable
  `.img.xz`.
- [`openastro/openastro-setup.sh`](openastro/openastro-setup.sh) - the OpenAstro
  layer (StellaVita power/USB enablement, WiFi AP, baked-in credentials, ZWO
  udev rule). Idempotent; also runnable directly on a booted StellaVita.

## Sibling projects

- [openastro-raspberrypi](https://github.com/open-astro/openastro-raspberrypi)
  - same OpenAstro layer for the Raspberry Pi 3B+/4/5.
- [openastro-orangepi4pro](https://github.com/open-astro/openastro-orangepi4pro)
  - same OpenAstro layer for the Orange Pi 4 Pro (Allwinner A733).

## License

See [LICENSE.md](LICENSE.md).
