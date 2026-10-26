# TODO

Findings from the first wlan1 access point test (2026-10-26): temporary AP on
wlan1 (ESP32-C5), wlan0 still on eduroam, caddy serving fine204.mesh/m782li/ to
an iPhone. Full page (5.2 MB) loaded in ~13 s.

## mesh-config.sh

- [ ] **AP role scan race** (`mesh-uplink.sh`, `ap)` branch): it unmanages the
      radio and starts hostapd at once. A scan still pending when the ESP switches
      to AP times out in the driver (15 s), the driver restarts the ESP firmware,
      wlan1 re-registers and NetworkManager manages it again -> AP gone.
      Fix that worked: unmanage, wait for wpa_supplicant to release the radio,
      wait ~17 s, repeat until the ifindex stays the same, then start hostapd.
  - A `[keyfile] unmanaged-devices` file in `/run/NetworkManager/conf.d` does not
    work: `/etc/NetworkManager/conf.d/99-mesh.conf` sets the same key and wins.
  - udev `ENV{NM_UNMANAGED}="1"` was not honoured by NetworkManager 1.52 for the
    re-registered device.
  - Consider adding `interface-name:<uplink_if>` to `unmanaged-devices` in
    99-mesh.conf while uplink=ap (keeps it unmanaged across firmware restarts).
- [ ] **Encryption (later)**: the access point is open and the ad-hoc mesh is
      open, on purpose, until the network and encryption design is decided. Do not
      ask about a password before then. Leftover: `ap_psk` in mesh.conf is unused.
- [ ] **Peer status page**: interactive page at `http://<group>.mesh/` showing which
      peers are online (today: static list rebuilt by `mesh-hosts.sh` every minute
      in `/var/www/mesh/index.html`).

## TUTORIAL.md

- [ ] ESP host driver must be built with AP support:
      `make target=sdio CONFIG_AP_SUPPORT=y` (default build has managed+monitor
      only, so hostapd cannot start). Note: `make` runs `clean` first and deletes
      every `*.ko` in the directory, backups included.
- [ ] iPhone clients: `.mesh` names only resolve when the AP hands out a router
      (mesh-config does; iOS otherwise sends DNS over cellular), and with
      "Limit IP Address Tracking" (Private Relay) off for the network. Type
      `http://` explicitly; Safari treats `fine204.mesh` as a search otherwise.
- [ ] Use `http://<group>.mesh/<id>/` (trailing slash; `/<id>` redirects).

## ESP32-C5 / SDIO speed

- [ ] Current link: 4 MHz, 1-bit (`dtoverlay=esp32-sdio-slow,max_freq=4000000,bus_width=1`)
      -> ~400 KB/s measured. Try 10 MHz and 25 MHz 4-bit with the patched
      (NSEND_PSAMPLE) firmware; fill in the untested rows of
      `~/esp-hosted-linux/ISSUE_DRAFT_c5_sdio_default_speed_timing.md`.

## Site (~/FINE315_Digital_Acetate)

- [ ] Shrink images: sheet-a.jpg 1.46 MB, acetate-b.png 1.28 MB, sheet-b.jpg
      1.0 MB, acetate-a.png 0.87 MB (4.6 of 5.2 MB per load). WebP/JPEG at screen
      size should bring the page to ~1 MB (~3 s over the current link).
- [ ] `assets/env.hdr` returns 404: referenced by the page but missing from
      `/home/m782li/public/assets`.

## Temporary state to undo

- [ ] `/etc/dnsmasq.d/mesh.conf` is still the temporary-AP version (its backup in
      /run was lost on reboot). `mesh-up` rewrites it on the next mesh start.
