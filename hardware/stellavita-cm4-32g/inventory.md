# ToupTek StellaVita — Hardware & Software Inventory

Captured live from a running unit over SSH (`pi@raspberrypi.lan`, default password `pi`) on 2026-08-18.
Unit serial (from AP SSID): **A59046**.

## Platform

| Item | Value |
|---|---|
| SoM | Raspberry Pi Compute Module 4 Rev 1.1 (BCM2711, revision `c03141`) |
| CPU | 4× Cortex-A72 (ARMv7l 32-bit userland/kernel), `arm_freq=1500`, `arm_boost=1` |
| RAM | 4 GB |
| Storage | 32 GB eMMC (`/dev/mmcblk0`, 29.12 GiB): 256 MB FAT32 `/boot` + 28.9 GB ext4 rootfs (MBR, disk id `0x85b3f946`) |
| OS | Raspbian GNU/Linux 11 (bullseye), 32-bit |
| Kernel | 5.15.32-v7l+ #1538 (2022-03-31) |
| EEPROM bootloader | 2023-01-11 (`8ba17717`), VC firmware 2022-03-24 (`e5a963ef`) |
| Ethernet MAC | D8:3A:DD:E6:CE:92 (set via `smsc95xx.macaddr` in cmdline) |
| Serial | 10000000f63a46c9 |

## Peripherals / board hardware

- **USB 3.0 host controller**: Renesas uPD720201 (4-port xHCI) on the CM4's PCIe x1. Firmware loaded at boot by `upd72020x-fwload.service`; the vendor `as.service` is ordered after it.
- **USB micro-SD card slot**: Genesys Logic GL0727 microSD reader/writer (`05e3:0727`) hard-wired to the internal USB 2.0 hub. Cards appear as `/dev/sda`; auto-formatted (FAT32) and auto-mounted at `/media/pi/sd/` by `scripts/as_sd` via udev rule + `as_sd.service`.
- **Speaker (piezo buzzer) on BCM GPIO 12**: not an ALSA device — the only sound cards are the two HDMI outputs. Beeps are bit-banged by `scripts/as_beep` (Python RPi.GPIO): `as_beep <gpio> <hz> <cycles>`, invoked by the vendor stack as `as_beep 12 1000 40` (AP-up double beep) and by `as_daemon` (`AstroDaemon::beepForFirstRunEv`). Firmware config has `force_pwm_open=1`, `audio_pwm_mode=514`.
- **DSLR port**: dedicated USB port serviced by **libgphoto2 2.5.32.1** (custom build in `/usr/local/lib/arm-linux-gnueabihf/`, plus libgphoto2_port 2.5.30 with its udev hooks). `as_core` links it directly and contains a `CameraDSLR` driver class (bulb via `bulb`/`eosremoterelease`, ISO/shutter mapping, capture-target to RAM, autofocus disable) — Canon/Nikon/Sony etc. per the standard gphoto2 camlib set.
- **WiFi**:
  - On-board CM4 WiFi (`brcmfmac`) = `wlan0`, default AP.
  - Supported external USB WiFi dongles (become `aswlan0` AP / `aswlan1` STA, enabling "WiFi bridge" station mode): Realtek RTL88x2BU (`0bda:b812`), RTL8821CU (`0bda:c811`, `0bda:c820`), and any TP-Link `2357:*` — see `configs/90-as.rules`; driver module `8821cu` ships in the kernel tree.
  - AP: hostapd, SSID `StellaVita_A59046`, WPA2 passphrase `12345678`, 5 GHz ch36 (`as_5g.conf`, active via `as.conf` symlink) or 2.4 GHz ch11 (`as_2.4g.conf`). AP IP 10.0.10.1/24, DHCP by dnsmasq. Band/channel/STA managed by `scripts/wifi_ap.sh`; NAT/bridging by `scripts/bridge_ap` + `scripts/bridge_init`.
- **Bluetooth**: CM4 on-board (hci_uart/btbcm), enabled.
- **HDMI**: 2 ports (vc4-kms-v3d), audio-capable (`vc4hdmi0/1`).
- **GPIO snapshot**: GPIO 4, 9, 10, 11, 17, 18, 42 configured as outputs at rest (likely status LED / power-control lines); GPIO 12 = buzzer.
- No I²C/SPI devices enabled (`i2c-20/21` are HDMI DDC only); no camera on CSI.

## Vendor software stack ("AstroStation")

- Install root: `/usr/local/astrostation/` (`bin/`, `data/`, `hostap/`).
- Boot chain: `as.service` (LSB wrapper for `/etc/init.d/as`, see `scripts/as.initd`) → sleeps 12 s → launches `as_daemon` (watchdog, ~30 KB) which runs `as_core` (~3 MB, the main app, runs as root).
- Working dirs: `/home/pi/AstroStation/{image,sequence,thin,tmp,autotest,update}`; settings in SQLite DBs under `/home/pi/.as/config/` (`global.db`, `cameramain.db`, `cameraguide.db`, `scope.db`, `focuser.db`, `filterwheel.db`, `sequence.db`); logs under `/home/pi/.as/log/`; plate-solve data in `/home/pi/.as/solve/` and `data/as_stars/`.
- Driver manifest: `configs/as_drv.json`.
- Camera/device SDKs linked into `as_core`: libtoupcam, libaltaircam, libbaccam, libnncam, libmallincam, libstarshootg, libomegonprocam, libogmacam (all ToupTek OEM builds), libASICamera2 + libEFWFilter + libEAFFocuser (ZWO), libqhyccd, libPlayerOneCamera/PW, libatikcameras, libgphoto2 (DSLR), plus cfitsio, OpenCV 4.5, libraw, libnova, wxWidgets GTK3, exiv2, libasrtsp (RTSP streaming).
- Full INDI 1.x distribution installed in `/usr/bin` (indiserver + ~all indi_* drivers); init script kills `indiserver` alongside the vendor daemons.
- Also running: lightdm/X desktop, RealVNC server, Samba (smbd/nmbd), CUPS, avahi (`raspberrypi.local`), sshd. `pi` has passwordless sudo.
- Astronomy tooling in `/usr/local/bin`: `gphoto2-config`, `ldactoasc`, `sex`/`source-extractor`; python3-astropy installed. 1412 dpkg packages total.

## Networking defaults

- `eth0`: DHCP client.
- `wlan0` (or `aswlan0` when a dongle is present): AP 10.0.10.1/24, dnsmasq DHCP (`configs/as_dns.conf`), hostapd (`configs/as_5g.conf` / `as_2.4g.conf`).
- IP forwarding + iptables MASQUERADE from the AP out via `eth0`/`aswlan1` (internet sharing to connected phones/tablets).
- Policy routing: `from 10.0.10.1 table 1` to keep AP traffic on the AP interface.

## Files in this directory

- `configs/config.txt`, `configs/cmdline.txt` — boot firmware config (notable: `dtoverlay=dwc2,dr_mode=host` under `[cm4]`, `dtoverlay=vc4-kms-v3d`, `snd_bcm2835.enable_hdmi=1`).
- `configs/90-as.rules` — udev rules for WiFi dongles and SD hot-plug.
- `configs/as_2.4g.conf`, `configs/as_5g.conf` — hostapd AP profiles.
- `configs/as_dns.conf` — dnsmasq AP DHCP config.
- `configs/as_drv.json` — vendor driver manifest.
- `scripts/` — vendor scripts verbatim: `as.initd`, `as_ap`, `as_beep` (buzzer), `as_sd` (SD automount/format), `bridge_ap`, `bridge_init`, `wifi_ap.sh` (WiFi CLI), `wifi_flag.py`, `sort.py`.
