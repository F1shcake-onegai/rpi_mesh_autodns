# Changelog

## 20261122+02

The index page. Built and tested on a laptop with generated data and one real two-Pi
`batadv-vis` output; not yet run on a Pi.

### Added
- Index page at `http://<group>.mesh/`, headed `<group>.mesh - Live Node Index`: the Pis
  that are online, as a list on the left (two per line, `@<display name>` over the MAC) and a
  map on the right (a dot per Pi with the same two lines). A click opens that Pi's page
  (`/<id>/`). A Pi without a display name shows as `@<id>`.
- Map layout: the Pi serving the page on the left ("you are here"), Pis with internet or a
  Wi-Fi access point on the right with an `internet` or `wifi` tag, the others in between,
  further right the more hops away. A line joins two Pis that hear each other directly; only
  each Pi's three best links are drawn.
- The page updates by itself: a Pi that joins drops in, a Pi that leaves fades out with its
  lines, the others keep their places. `Map not updating` shows after 30 seconds without new
  data, `No other Pis found yet` when this Pi is alone.
- `mesh-map.sh` (`mesh-map.service`, while the mesh is on): every 10 seconds it announces this
  Pi's ID, MAC, display name and roles through alfred, and writes
  `/var/www/mesh/_mesh/map.json` from every Pi's announcement, `batadv-vis` and `batctl o`.
  A Pi not heard of for 15 seconds is left out. Everything read from the mesh is checked
  before it goes into the file.
- Fonts Space Grotesk and Space Mono (`fonts/`, SIL Open Font License), installed to
  `/var/www/mesh/_mesh/fonts`; from GitHub when install runs without the folder next to it.
  Without them the page uses the device's own fonts.

### Changed
- 1 Identity: the display name takes letters, digits, spaces and `. _ -` only, at most 24
  characters; anything else is asked again. A stored name with other characters is not shown
  on the index page (the ID is shown instead) until it is changed.
- `mesh-hosts.sh` no longer writes `/var/www/mesh/index.html`; install writes the page.
- Status (8) shows whether `mesh-map` is running.

## 20261122+01

First step towards the map on the index page: the data source only. Nothing shows it in
the browser yet.

### Added
- Map data source: while the mesh is on, every Pi runs `alfred` and `batadv-vis`
  (`mesh-alfred.service`, `mesh-vis.service`; started by `mesh-up`, stopped with the mesh).
  Every 10 seconds each Pi reports the Pis it hears directly, and alfred carries that to all
  other Pis, so any Pi can print the whole picture with `sudo batadv-vis`.
- Install adds the `alfred` package (without its recommended graphviz). The mesh runs without
  it; `mesh-up` then warns `alfred not installed: no map data (run install)`.
- Status (8) shows the map data: every Pi that reports and the Pis it hears, with the link
  cost (1.000 is a perfect link, larger is worse).
- Warning `br0 has no IPv6 link-local address: no map data` (alfred talks over IPv6
  link-local multicast).

### Changed
- `mesh-config.sh`: one coding style and comments throughout, no functional change.
- todo: the mesh radio stays unencrypted, with the reason; the map layout decided for the
  index page.

## 20261104+02

### Fixed
- Zero peers when a Pi's NetworkManager had left power save on (seen on a Pi Zero 2 W):
  the mesh radio joined its ad-hoc cell ("Joined IBSS") but sent no beacons, so other Pis
  never found or merged with it. `mesh-up` turns power save off on the mesh radio before
  the ad-hoc join (the kernel takes it only in managed mode) and warns
  `power save is still on for <if>: other nodes may not find this one` if it stays on.
  NetworkManager applies its own setting again when the mesh stops.

### Added
- Status (8) shows the mesh radio's power save.
- Tutorial: the power save step in step 5 and why; troubleshooting for a cell nobody sees,
  and the new warning in the message table.

## 20261104+01

Update every Pi of a group together (`sudo mesh-config update`, then restart the mesh): the
ad-hoc cell name changes, and a Pi on the old name forms a separate mesh until it is updated.

### Added
- The second radio's capabilities are read from `iw phy`: access point mode, and the channels
  it may transmit on (2.4 GHz 1/6/11 and non-DFS 5 GHz 36/40/44/48; a channel marked disabled,
  no IR or radar detection is not used). The access point role works on 2.4 GHz-only radios
  such as USB dongles (for example the RTL8192EU), not only on the 5 GHz ESP32-C5.
- `ap_channel=auto` picks 36/40/44/48 by node ID when the radio can use them (the same
  channel as before), else the 2.4 GHz channel farthest from `mesh_channel`: 1 or 11 by node
  ID with the mesh on 6, 11 with the mesh on 1, 1 with the mesh on 11.
- Status (8) shows, for each second radio, whether it can be an access point and its usable channels.
- Warnings `<if> cannot run an access point (no AP mode); uplink role not applied` and
  `<if> cannot run an access point on channel <n> (usable: ...); uplink role not applied`.
  The radio is checked before it is taken from NetworkManager, so a refused role leaves it
  with NetworkManager instead of idle; the warning is given once, not every two minutes.
- Tutorial: how to read a radio's modes and usable channels; 2.4 GHz access point settings;
  the two new warnings in the troubleshooting table.

### Changed
- Default ad-hoc cell name `<group>-pis` (was `<group>.mesh`, the same text as the web
  address) and default access point SSID `<group>-ap` (was `<group>-mesh`, one character away
  from the cell name). The web address stays `<group>.mesh`. A `mesh.conf` that stored the
  old defaults explicitly follows the new ones; custom names stay.
- The hostapd template takes `hw_mode` (a or g) and `ieee80211ac` (1 or 0) from the chosen
  channel; it was fixed to 5 GHz, so hostapd failed on 2.4 GHz-only radios with
  `Could not determine operating frequency`.
- 3 Uplink: a radio without access point mode is not offered the access point role; the
  channel list shows only the channels the radio can use, marks the mesh channel and shows
  which channel `auto` picks. Without the radio attached, all channels are listed and
  `mesh-uplink.sh` checks when the radio appears.

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
