# rpi_mesh_autodns

A self-organising classroom mesh for Raspberry Pis: an open ad-hoc cell with batman-adv on
the built-in radio, one address for clients (`<group>.mesh`), every Pi's web folder
reachable through it at `<group>.mesh/<id>/`, and a hot-pluggable second radio (ESP32-C5 via esp-hosted-linux)
that either joins an external network and shares it with the mesh, or broadcasts the group's
access point for laptops. Pis join and leave at any time; gateways appear and disappear on their own.

## Quick start

```bash
sudo ./mesh-config.sh            # interactive menu (raspi-config style)
sudo ./mesh-config.sh install    # write all system files non-interactively
sudo ./mesh-config.sh status     # print status and exit
sudo ./mesh-config.sh uninstall  # remove all system files, restore the originals
sudo mesh-config update          # after install: update from GitHub if version.txt is newer; mesh.conf is kept
```

In the menu: set the group and ID (1), install the system files (6), choose what the second
radio does (3), then turn the mesh on (2). Turning the mesh on takes the built-in Wi-Fi away
from NetworkManager, so do it from a keyboard, over Ethernet, or expect your Wi-Fi session to drop.
While the mesh is on, the Pi's hostname is its node ID and avahi announces only on `br0`; when
the mesh is off, the original hostname and avahi settings are back (also at boot, in case the
mesh was on at a power cut).

Group (at most 27 characters) and ID (at most 63, with at least one letter) take lowercase
letters and digits only and must differ; anything else is asked again. Install needs the
internet for the packages and stops when caddy cannot be installed.
`version.txt` is `YYYYMMDD+N`: a later date is newer, then a larger N.

Bridging eth0 into the mesh (5) is for a cable to one PC. Never bridge it into a shared network:
every Pi would hand out addresses there. Turn off "Addresses for devices on eth0" if the other
side uses fixed addresses.

Uninstall stops the mesh, removes every file install and the mesh scripts wrote (including
`version.txt` and the peer block in `/etc/hosts`) and restores the replaced files (a stock file
the first install recorded as new because its package came later is reinstalled from that
package), the hostname, the USB gadget settings in `config.txt` and `cmdline.txt`, and the
service states from before the first install. Packages, node users, their folders,
`/var/www/mesh` and `mesh.conf` stay.

Requirements: Raspberry Pi, Raspberry Pi OS Bookworm or newer (NetworkManager). The
built-in radio supports ad-hoc but not 802.11s, which is why the mesh is ad-hoc.

## Learn how it works

[TUTORIAL.md](TUTORIAL.md) builds the whole thing by hand, layer by layer, with the reason
for every command, and ends with a table mapping each manual step to the part of the script that automates it.
