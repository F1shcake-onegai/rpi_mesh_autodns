# Changelog

## 20261028+1

### Added
- `mesh-config uninstall` (menu: 6 Install > 2 Uninstall): stops the mesh, removes every file install and the mesh scripts wrote (including `version.txt`, `/etc/hosts.mesh.new`, `/etc/hosts.new`, the mesh-peers block in `/etc/hosts` and an empty `/etc/nftables.d`), unloads batman-adv, and restores the files the first install replaced (kept as `<file>.mesh-bak`, taken after the packages so the stock Caddyfile and avahi settings come back), the hostname, the USB gadget settings in `config.txt` and `cmdline.txt`, the sysctls and the boot state of each service. Packages, node users, their folders, `/var/www/mesh` and `mesh.conf` stay.
- Uninstall: a config file the first install recorded as new because its package came later (`/etc/caddy/Caddyfile`, `/etc/avahi/avahi-daemon.conf`) is reinstalled from the package instead of deleted (`No stock copy of <file>: reinstall <package> to restore it` when that fails); on a Pi installed over 2026102601 (no backups) the replaced files are left as they are; the USB gadget settings are only touched when the install recorded them.
- `mesh-restore.service`: at every boot, before avahi and the mesh, the original hostname, `127.0.1.1` line and avahi settings are put back from the first-install backups, in case the mesh was on at a power cut (`mesh-down.sh restore`).
- `eth0_dhcp` (5 Ports, "Addresses for devices on eth0"): off, DHCP through a bridged eth0 is dropped at the bridge port; Status shows it.
- Warnings are shown when the menu opens and at SSH login (`/run/motd.d/mesh`), not only in Status.
- Warning `ID <id> is already used by another node on the mesh` when avahi publishes this Pi's record under another name.
- "Uplink role is off" message when the uplink role is applied with `uplink=off`.
- Troubleshooting table of the install and mesh messages in the tutorial.
- todo: `mesh-config fix` to repair a half-finished install; gateway spoofing noted under encryption.

### Changed
- Version format `YYYYMMDD+N` (a later date is newer, then a larger N); `mesh-config update` still understands the digits-only versions of older installs.
- 1 Identity asks the group first, then the ID: lowercase letters and digits only, group at most 27 characters, ID at most 63 with at least one letter, and they must differ; anything else is asked again, and the mesh refuses to start with an invalid pair.
- Install runs `apt-get update` first; caddy is required (install stops when it cannot be installed, when `caddy.service` does not read `/etc/caddy/Caddyfile` or when `/etc/caddy` is missing); caddy is stopped at install while the mesh is off; the uplink role is applied again at the end of install while the mesh runs.
- avahi announces only on `br0` while the mesh is on (`/etc/mesh/avahi-daemon.conf` copied over `/etc/avahi/avahi-daemon.conf` by mesh-up); when the mesh stops the original settings are back and avahi is restarted or stopped per its boot state.
- When the mesh stops, the original hostname and `127.0.1.1` line are back (from the first-install backups) and the warning list is emptied.
- Gateway DNS: NetworkManager's servers first, then 1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4, 9.9.9.9; dnsmasq tries them in that order (`strict-order`).
- Until the first mesh start dnsmasq answers only the Pi itself (`interface=lo`).
- Uplink `external` with a named profile: the connection is left alone when it is already active (no reconnect when install restarts the uplink unit).
- Only valid IDs with an IPv4 address and a six-pair MAC are taken from mDNS into `/etc/hosts` and the directory page.
- Home folders `/home/<id>` are mode 711: caddy reaches `public/`, other users cannot list them.
- Windows line endings in `mesh.conf` are accepted.
- 5 Ports offers a mesh restart while the mesh runs.
- Docs: "Raspberry Pi" (not "4 or 5"); the tutorial's mDNS filter, step references and 9b DHCP explanation (any Pi's dnsmasq may answer a laptop) corrected; the dnsmasq config and gateway DNS commands match the script (`strict-order`, public servers); identity rules, uninstall and the boot restore described.

### Fixed
- The first gateway comes up: the forwarders are filled from the uplink before the internet check, which resolves through dnsmasq.
- The gateway role check runs only once the mesh is up.
- The uplink radio goes back to NetworkManager when the mesh stops.
