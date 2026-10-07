# Building the Pi mesh by hand, step by step

`mesh-config.sh` does everything below automatically. This tutorial walks through the
same thing manually, one layer at a time, so you can see what each piece does and why
it is there. Use it on two Raspberry Pis side by side; a mesh of one is hard to observe.

Every step says what it changes and how to check it. Nothing here survives a reboot;
that is what the script's systemd units add at the end.

> **Warning.** Step 4 takes the built-in Wi-Fi away from NetworkManager. If you are
> logged in over that Wi-Fi you will be cut off. Work on a keyboard and screen, over
> Ethernet, or accept the drop and reconnect after step 10.

## 0. The picture

```
 laptop ──(Wi-Fi "demo-mesh" or an Ethernet cable)──┐
                                                    │  br0  10.X.Y.1/8   dnsmasq · avahi · caddy
 other Pis ═══ ad-hoc cell "demo.mesh" ═══ wlan0 ───┤
                                             bat0 ──┘  batman-adv: routes between Pis, looks like one Ethernet
 internet ──(NetworkManager: eduroam, home Wi-Fi, PPPoE, ...)── wlan1 / eth0   → NAT gateway while it works
```

Seven layers, bottom up:

| Layer | What it does | Tools |
|---|---|---|
| 1 | Radios talk to each other without an access point (ad-hoc / IBSS) | `iw` |
| 2 | Multi-hop routing between Pis; the whole mesh behaves like one Ethernet switch | `batman-adv`, `batctl` |
| 3 | A bridge so the Pi, its laptops and its access point all sit on that Ethernet, plus a stable address per Pi | `ip link`, `ip addr` |
| 4 | Names: every Pi announces itself, every Pi resolves `<id>.mesh` | `avahi`, `dnsmasq` |
| 5 | Web: each Pi serves its folder and proxies every other Pi's folder | `caddy` |
| 6 | Uplink: a second radio either joins an external network (and the Pi becomes a gateway) or broadcasts the group access point | NetworkManager, `nftables`, `hostapd` |
| 7 | Back to normal | the reverse of all of the above |

Requirements: Raspberry Pi 4 or 5 with Raspberry Pi OS Bookworm or newer (NetworkManager),
a root shell, and optionally an ESP32-C5 running esp-hosted-linux as the second radio.
The built-in radio (brcmfmac) does ad-hoc but not 802.11s, which is why this design is ad-hoc.

Throughout the examples: Pi 1 has ID `pi1`, Pi 2 has ID `pi2`, the group is `demo`.
From the group name everything else is derived: address `demo.mesh`, ad-hoc cell name
`demo.mesh`, access point `demo-mesh`.

## 1. Packages and kernel settings

```bash
sudo apt install batctl hostapd dnsmasq avahi-daemon avahi-utils nftables curl iw bridge-utils caddy
sudo modprobe batman-adv
echo batman-adv | sudo tee /etc/modules-load.d/batman.conf
printf 'net.ipv4.ip_forward = 1\nnet.ipv4.conf.all.rp_filter = 0\n' | sudo tee /etc/sysctl.d/90-mesh.conf
sudo sysctl --system
```

- `batctl` controls the batman-adv kernel module (mesh routing).
- `dnsmasq` is DNS and DHCP for the mesh side; `avahi` is mDNS discovery (who is here?).
- `hostapd` turns the second radio into an access point; `nftables` does NAT on gateways.
- `ip_forward` lets a gateway pass packets between the mesh and the internet;
  `rp_filter=0` stops the kernel from dropping packets whose reply path differs from their arrival path, which is normal in a mesh.

Check: `lsmod | grep batman_adv` lists the module.

## 2. Know your radio

```bash
iw dev                                              # interfaces and their phys
readlink -f /sys/class/net/wlan0/device/driver      # ends in .../brcmfmac on a Pi
iw phy phy0 info | sed -n '/Supported interface modes/,/Band 1/p'
ip -d link show wlan0 | grep -o 'maxmtu [0-9]*'
```

The mode list must contain `IBSS`. On Pi 4/5 it also contains `AP` and `managed` but
**not** `mesh point`, so 802.11s is not an option on this radio. `maxmtu 1500` means the
radio cannot carry batman-adv's preferred 1532-byte frames; batman-adv then fragments
by itself, which costs a little throughput and nothing else.

## 3. Pick names and compute the addresses

Decide the ID (hostname, user, folder, DNS name) and the group (shared by every Pi).

Every Pi needs a unique, stable mesh address without a central DHCP server. Derive it
from the radio's MAC address, which is unique and never changes:

```bash
m=$(cat /sys/class/net/wlan0/address)        # e.g. b8:27:eb:12:4e:9a
echo "10.$((0x${m:12:2})).$((0x${m:15:2})).1"   # -> 10.78.154.1
```

The last two bytes of the MAC become the second and third octet, so each Pi owns
`10.X.Y.1` and can hand out `10.X.Y.10` to `.250` to its own laptops. Because any Pi can
compute another Pi's address from its MAC, a gateway's address is known the moment
batman-adv reports the gateway's MAC (step 9).

Ad-hoc cells merge only when they share the cell ID (BSSID). Derive one from the mesh
name so every Pi with the same name computes the same cell ID; `02:` makes it a
locally administered MAC that cannot collide with real hardware:

```bash
printf '02:%s\n' "$(printf %s demo.mesh | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*/\1:\2:\3:\4:\5/')"
# -> 02:0e:87:37:df:c9
```

Set the hostname to the ID so mDNS announces the right name later:

```bash
sudo hostnamectl set-hostname pi1
sudo sed -i 's/^127\.0\.1\.1.*/127.0.1.1\tpi1/' /etc/hosts     # otherwise sudo complains it cannot resolve the host
```

## 4. Take the radio away from NetworkManager

```bash
sudo nmcli device set wlan0 managed no
while [ -e /run/wpa_supplicant/wlan0 ]; do sleep 0.5; done
```

NetworkManager reports "unmanaged" immediately, but its wpa_supplicant releases the
interface a moment later, and on the way out it puts the interface back into managed
mode. If you reconfigure the radio before that, the ad-hoc join in step 5 fails with
`Operation not supported (-95)`. Waiting for the control socket to disappear avoids the race.

## 5. Join the ad-hoc cell

```bash
sudo ip link set wlan0 down
sudo iw dev wlan0 set type ibss
sudo ip link set wlan0 mtu 1532 || true          # refused on Pi radios, see step 2
sudo ip link set wlan0 up
iw dev wlan0 info | grep type                     # must say "type IBSS"
sudo iw dev wlan0 ibss join demo.mesh 2437 fixed-freq 02:0e:87:37:df:c9
sleep 5; iw dev wlan0 link                        # "Joined IBSS 02:0e:87:37:df:c9 (on wlan0)"
```

2437 MHz is channel 6 (1 is 2412, 11 is 2462). Name, channel and cell ID must be
identical on every Pi. The join returns at once; the radio scans for an existing cell
with that name and joins it, or creates it if none is found.

## 6. batman-adv and the bridge

```bash
sudo ip link add bat0 type batadv
sudo batctl if add wlan0
sudo batctl gw_mode client
sudo ip link add br0 type bridge
sudo ip link set bat0 master br0
sudo ip link set bat0 up
sudo ip link set br0 up
sudo ip addr add 10.78.154.1/8 dev br0           # the address from step 3
```

`bat0` is a virtual Ethernet interface: anything sent into it is routed hop by hop over
the ad-hoc radio to the right Pi, and the Pis constantly measure link quality to pick
routes. `br0` is a plain Linux bridge with `bat0` as its first port; later an access
point and an Ethernet cable join the same bridge, so a laptop on any port is on the same
LAN as every Pi. The `/8` mask makes all `10.X.Y.z` addresses one subnet.

Now repeat steps 1 to 6 on Pi 2 (its own MAC gives it its own address, say `10.45.201.1`). Then:

```bash
sudo batctl o          # originators: the other Pis, with link quality (TQ, 255 is perfect)
sudo batctl n          # direct radio neighbours
ping 10.45.201.1       # from pi1 to pi2
```

## 7. Names: discovery and DNS

Each Pi runs its own DNS server (dnsmasq) that knows the mesh names and forwards
everything else to the internet via whichever gateway exists. Write `/etc/dnsmasq.d/mesh.conf`
(values for pi1):

```
interface=br0
bind-dynamic
dhcp-range=10.78.154.10,10.78.154.250,255.0.0.0,10m
dhcp-option=option:dns-server,10.78.154.1
dhcp-option=option:router,10.78.154.1
domain=mesh
local=/mesh/
expand-hosts
addn-hosts=/etc/hosts.mesh
address=/demo.mesh/10.78.154.1
servers-file=/run/dnsmasq/upstream.conf
no-resolv
cache-size=1000
```

- `interface=br0` plus `bind-dynamic`: serve the mesh side only, even if `br0` appears later.
- `dhcp-range` ... `10m`: laptops attached to this Pi get an address from this Pi's block, with this Pi as router and DNS, on short leases so they re-learn quickly after roaming.
- `domain=mesh`, `local=/mesh/`, `expand-hosts`: `.mesh` is ours; never ask the internet about it.
- `addn-hosts=/etc/hosts.mesh`: the list of discovered Pis (built below).
- `address=/demo.mesh/...`: the group address always points at *this* Pi; whichever Pi you are attached to answers for the group.
- `servers-file` + `no-resolv`: upstream DNS comes from one small file we control, not from `/etc/resolv.conf`.

Then point the Pi itself at that resolver and tell NetworkManager to stop rewriting it:

```bash
sudo tee /etc/NetworkManager/conf.d/99-mesh.conf <<'EOF'
[main]
dns=none

[keyfile]
unmanaged-devices=interface-name:bat0;interface-name:br0;interface-name:usb0
EOF
sudo nmcli general reload
sudo mkdir -p /run/dnsmasq && sudo touch /run/dnsmasq/upstream.conf /etc/hosts.mesh
sudo rm -f /etc/resolv.conf
printf 'nameserver 127.0.0.1\nsearch mesh\n' | sudo tee /etc/resolv.conf
sudo systemctl restart dnsmasq
```

Discovery: avahi announces this host on the mesh, and a small service record marks it as a mesh node.

```bash
sudo tee /etc/avahi/avahi-daemon.conf <<'EOF'
[server]
use-ipv4=yes
use-ipv6=no
allow-interfaces=br0

[publish]
publish-hinfo=no
publish-workstation=no
EOF
sudo tee /etc/avahi/services/groupmesh.service <<'EOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h</name>
  <service>
    <type>_groupmesh._tcp</type>
    <port>80</port>
  </service>
</service-group>
EOF
sudo systemctl restart avahi-daemon
```

Build the name list from what avahi sees, and tell dnsmasq to reload it:

```bash
avahi-browse -trp _groupmesh._tcp | awk -F';' '$1=="=" && $3=="IPv4" {print $8, $4".mesh"}' | sort -u | sudo tee /etc/hosts.mesh
sudo pkill -HUP -x dnsmasq
ping pi2.mesh          # the Pi's resolver has "search mesh", so "ping pi2" works too
```

The script runs this every minute; by hand you run it whenever a Pi joins or leaves.

## 8. The web folder

Each student edits `/home/<id>/public`; every Pi serves its own folder and proxies the others by name.

```bash
sudo useradd -m -s /bin/bash pi1 && sudo passwd pi1
sudo install -d -o pi1 -g pi1 -m 755 /home/pi1/public && sudo chmod 755 /home/pi1
echo '<h1>hello from pi1</h1>' | sudo tee /home/pi1/public/index.html
sudo mkdir -p /var/www/mesh && echo '<h1>demo</h1><p>directory page</p>' | sudo tee /var/www/mesh/index.html
```

`/etc/caddy/Caddyfile` (identical on every Pi; the three variables are filled in per node):

```
{
  auto_https off
}

http://{$GROUP}.mesh, http://{$ID}.mesh, http://{$ID}.local, http://{$MYIP} {
  bind {$MYIP}

  redir /{$ID} /{$ID}/ 301

  handle_path /{$ID}/* {
    root * /home/{$ID}/public
    file_server browse
  }

  @peer {
    path_regexp p ^/([a-z0-9]+)(/.*)?$
    not path /{$ID} /{$ID}/*
  }
  handle @peer {
    reverse_proxy {re.p.1}.mesh:80
  }

  handle {
    root * /var/www/mesh
    file_server
  }
}
```

```bash
sudo env ID=pi1 GROUP=demo MYIP=10.78.154.1 caddy run --config /etc/caddy/Caddyfile
```

Reading it top to bottom: listen only on the mesh address; `/pi1/` is this Pi's folder
(`handle_path` strips the prefix so links inside the folder stay relative); any other
`/<name>/` is proxied to `http://<name>.mesh:80` with the path unchanged, so that Pi
serves its own folder; everything else is the directory page. From pi2:

```bash
curl http://demo.mesh/pi1/      # proxied by pi2 to pi1
curl http://pi1.mesh/pi1/       # straight to pi1
```

## 9. The uplink radio

Everything so far used only the built-in radio. The second radio (ESP32-C5 via esp-hosted-linux,
usually `wlan1`) does one of two jobs per Pi.

### 9a. External network, and becoming a gateway

Leave the radio to NetworkManager and connect it to whatever external network you have.
This tutorial does not configure that network; it is yours:

```bash
nmcli device wifi connect "MyHomeWifi" password "secret" ifname wlan1    # or: nmcli connection up eduroam ifname wlan1
ip route show default                                                     # ... dev wlan1 ...
curl -sI --interface wlan1 http://detectportal.firefox.com/success.txt   # really online?
```

If so, this Pi becomes a gateway: NAT between the mesh and the uplink, announce itself
via batman-adv, and forward the mesh's DNS to the uplink's DNS servers.

```bash
sudo tee /etc/nftables.d/meshgw.nft <<'EOF'
table inet meshgw {
  chain forward {
    type filter hook forward priority 0; policy drop;
    iifname "br0"   oifname "wlan1" accept
    iifname "wlan1" oifname "br0" ct state established,related accept
    iifname "br0"   oifname "br0" accept
  }
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "wlan1" masquerade
  }
}
EOF
sudo nft -f /etc/nftables.d/meshgw.nft
sudo batctl gw_mode server 50mbit/20mbit
nmcli -g IP4.DNS device show wlan1 | tr '|' '\n' | sed 's/[[:space:]]//g; /^$/d; s/^/server=/; s/$/@wlan1/' | sudo tee /run/dnsmasq/upstream.conf
sudo pkill -HUP -x dnsmasq
```

On every other Pi, batman-adv now lists the gateway. Compute its address from its MAC
exactly as in step 3, route through it, and forward DNS to it:

```bash
sudo batctl gwl                      # "*" marks the selected gateway; second column is its MAC
sudo ip route replace default via 10.78.154.1 dev br0 metric 50
echo 'server=10.78.154.1' | sudo tee /run/dnsmasq/upstream.conf
sudo pkill -HUP -x dnsmasq
curl -sI http://detectportal.firefox.com/success.txt
```

The script repeats this check every two minutes and on every NetworkManager event, so a
Pi becomes a gateway when its uplink works and stops being one the moment it drops. By
hand you redo it whenever something changes. Any interface with an internet route works
the same way, including Ethernet or PPPoE on `eth0` (then just do not bridge `eth0` into the mesh).

### 9b. Access point for laptops

`/etc/hostapd/hostapd.conf` (pi1; the SSID and passphrase are the same on every AP Pi so laptops roam):

```
interface=wlan1
bridge=br0
driver=nl80211
ssid=demo-mesh
country_code=CA
ieee80211d=1
hw_mode=a
channel=36
ieee80211n=1
ieee80211ac=1
wmm_enabled=1
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_passphrase=demo.mesh
rsn_pairwise=CCMP
```

```bash
sudo nmcli device set wlan1 managed no
sudo hostapd /etc/hostapd/hostapd.conf
```

`bridge=br0` puts the access point on the mesh LAN, so a laptop that joins `demo-mesh`
gets `10.78.154.x` from pi1's dnsmasq, resolves `demo.mesh` to pi1, and reaches every
Pi's folder through it. Three ESP-Hosted facts: the driver must be built with
`ap_support`; it has no automatic channel selection, so give each AP Pi its own channel
from 36, 40, 44, 48 (the script hashes the ID: pi1 gets 36, pi2 gets 48); and the
firmware accepts at most 8 clients per radio.

## 10. Back to normal

The reverse order, each command harmless if that layer never came up:

```bash
sudo pkill hostapd; sudo nft delete table inet meshgw 2>/dev/null
sudo batctl if del wlan0; sudo ip link del bat0; sudo ip link del br0
sudo iw dev wlan0 ibss leave; sudo ip link set wlan0 down; sudo ip link set wlan0 mtu 1500
sudo iw dev wlan0 set type managed; sudo ip link set wlan0 up
sudo nmcli device set wlan0 managed yes            # NetworkManager reconnects to its known Wi-Fi
nmcli -g IP4.DNS device show wlan0 | tr '|' '\n' | sed 's/[[:space:]]//g; /^$/d; s/^/server=/' | sudo tee /run/dnsmasq/upstream.conf
sudo pkill -HUP -x dnsmasq                          # dnsmasq now forwards to the normal network again
```

## 11. What the script adds on top

| Tutorial step | In `mesh-config.sh` |
|---|---|
| 1 | `write_system_files`, menu 6 |
| 3 | `menu_identity`, menu 1; address and cell ID in `mesh-up.sh` steps 2 and 0 |
| 4 to 6 | `mesh-up.sh` steps 3 and 4, run by `mesh.service` |
| 7 | templates in `/etc/mesh`, `mesh-hosts.sh` on a one-minute timer, the NetworkManager dispatcher `50-mesh-dns` |
| 8 | the Caddyfile and `/etc/default/mesh`, started by `mesh-up.sh` step 5 |
| 9a | `mesh-role.sh` every two minutes and on every NetworkManager event |
| 9b | `mesh-uplink.sh` from `mesh-uplink@IFACE.service`, started by udev when the radio is plugged in |
| 10 | `mesh-down.sh`, run as `ExecStopPost` so it also runs when a start failed half way |

Plus the things a tutorial skips: every error shown with the journal instead of being
lost, warnings collected for the status page, DNS kept working when dnsmasq is down,
hot-plugging the uplink radio, and one `mesh.conf` on the boot partition holding all choices.

## Troubleshooting

- `ibss join` says `Operation not supported (-95)`: the interface was not in IBSS type at that instant. Check `iw dev wlan0 info`; wpa_supplicant probably reset it (step 4).
- `mtu greater than device maximum`: expected on Pi radios; ignore.
- dnsmasq refuses to start: never put template files in `/etc/dnsmasq.d`, it reads every file there. `journalctl -t dnsmasq` names the bad line.
- `batctl o` stays empty: compare `iw dev wlan0 link` on both Pis (same name, channel, cell). brcmfmac sometimes ignores the fixed cell ID; cells with the same name usually still merge after a few seconds.
- Names do not resolve: `avahi-browse -trp _groupmesh._tcp` must list the other Pi; avahi only listens on `br0`; the hostname must equal the ID.
- No DNS after tearing down: `/etc/resolv.conf` points at dnsmasq; either refill `/run/dnsmasq/upstream.conf` as in step 10 or put NetworkManager's `nameserver` lines back.
