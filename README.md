# rpi_mesh_autodns

A self-organising classroom mesh for Raspberry Pis: an open ad-hoc cell with batman-adv on
the built-in radio, automatic names (`<id>.mesh`, `<group>.mesh`), every Pi's web folder
reachable through every Pi, and a hot-pluggable second radio (ESP32-C5 via esp-hosted-linux)
that either joins an external network and shares it with the mesh, or broadcasts the group's
access point for laptops. Pis join and leave at any time; gateways appear and disappear on their own.

## Quick start

```bash
sudo ./mesh-config.sh            # interactive menu (raspi-config style)
sudo ./mesh-config.sh install    # write all system files non-interactively
sudo ./mesh-config.sh status     # print status and exit
sudo ./mesh-config.sh uninstall  # remove all system files, restore the originals
```

In the menu: set the ID and group (1), install the system files (6), choose what the second
radio does (3), then turn the mesh on (2). Turning the mesh on takes the built-in Wi-Fi away
from NetworkManager, so do it from a keyboard, over Ethernet, or expect your Wi-Fi session to drop.

Bridging eth0 into the mesh (5) is for a cable to one PC. Never bridge it into a shared network:
every Pi would hand out addresses there. Turn off "Addresses for devices on eth0" if the other
side uses fixed addresses.

Requirements: Raspberry Pi 4 or 5, Raspberry Pi OS Bookworm or newer (NetworkManager). The
built-in radio supports ad-hoc but not 802.11s, which is why the mesh is ad-hoc.

## Learn how it works

[TUTORIAL.md](TUTORIAL.md) builds the whole thing by hand, layer by layer, with the reason
for every command, and ends with a table mapping each manual step to the part of the script that automates it.
