#!/bin/bash
# mesh-config: configuration tool for a Raspberry Pi ad-hoc mesh (after the
# meshunderground.com Raspberry Pi mesh guide).
#
#   sudo ./mesh-config.sh            interactive menu
#   sudo ./mesh-config.sh install    write all system files
#   sudo ./mesh-config.sh status     print status
#   sudo ./mesh-config.sh uninstall  remove all system files, restore the originals
#
# Design:
#   mesh radio     built-in Wi-Fi, open ad-hoc (IBSS) cell, batman-adv on top
#   uplink radio   second Wi-Fi (ESP32-C5, esp-hosted-linux), role per node:
#                    external  NetworkManager connection; node is a gateway while online
#                    ap        group access point, same SSID on every AP node
#   names          dnsmasq + avahi: <id>.mesh, <group>.mesh
#   web            caddy on every node: /home/<id>/public, other nodes proxied at /<id>/
#   hot plug       udev starts and stops the uplink role with the radio
#   failure        checks before any radio is touched; mesh-down.sh runs as
#                  ExecStopPost, so the mesh radio returns to NetworkManager
#
# Settings live in /boot/firmware/mesh.conf. Every write is idempotent.
#
# mesh.conf keys (empty value: derived from the group):
#   id             node name: hostname, DNS name, Linux user and folder /home/<id>/public
#   group          shared name of this mesh, address <group>.mesh (default: group)
#   display        optional display name
#   mesh_if        built-in radio: auto (the brcmfmac one) or an interface name
#   mesh_id        ad-hoc network name (default <group>.mesh); the cell id is derived from it
#   mesh_channel   2.4 GHz channel 1, 6 or 11        mesh_prefix   first octet of 10.X.Y.1/8
#   uplink_if      uplink radio: auto (first non-brcmfmac Wi-Fi interface) or a name
#   uplink         external | ap | off               uplink_profile  NetworkManager profile name or auto
#   ap_ssid        access point name (default <group>-mesh)   ap_psk   passphrase (default <group>.mesh)
#   ap_channel     auto (36/40/44/48 picked from the id) or a fixed channel
#   bridge_eth0    yes/no: bridge eth0 into the mesh     usb_gadget   yes/no: USB-C gadget port
#   eth0_dhcp      yes/no: hand out addresses through a bridged eth0 (no: devices there need fixed addresses)
#
# Files written by install (6 Install):
#   /usr/local/sbin/mesh-{up,down,uplink,role,hosts}.sh and /usr/local/lib/mesh/common.sh
#   /etc/systemd/system/mesh.service, mesh-uplink@.service, mesh-role-check.{service,timer},
#     mesh-hosts.{service,timer}, caddy.service.d/mesh.conf
#   /etc/mesh/*.tpl (dnsmasq, hostapd and nftables templates), /etc/mesh/meshdhcp.nft, /etc/caddy/Caddyfile
#   /etc/NetworkManager/conf.d/99-mesh.conf, /etc/NetworkManager/dispatcher.d/50-mesh-dns
#   /etc/udev/rules.d/90-mesh-uplink.rules, /etc/avahi/avahi-daemon.conf, /etc/avahi/services/groupmesh.service
#   /etc/tmpfiles.d/mesh.conf, /etc/sysctl.d/90-mesh.conf, /etc/modules-load.d/batman.conf
#   /etc/resolv.conf (local dnsmasq; NetworkManager dns=none)
# The first install keeps every file it replaces as <file>.mesh-bak and the
# service states it changes in /etc/mesh/preinstall.state; uninstall restores both.
# Runtime state: /etc/default/mesh (ID, MYIP, GROUP, MESH_IF, MESH_BSSID), /run/mesh/{up,uplink,gateway,warnings},
#   /run/dnsmasq/upstream.conf (dnsmasq forwarders), /etc/hosts.mesh (names found via mDNS).

set -u
CONF=/boot/firmware/mesh.conf
[ -d /boot/firmware ] || CONF=/boot/mesh.conf
SELF=$(readlink -f "$0")
TITLE="Raspberry Pi Mesh Configuration Tool (mesh-config)"
WARN_FILE=/run/mesh/warnings      # warnings from the mesh scripts
INTERACTIVE=0                     # 1 inside the menu
# Existing files that install or the mesh scripts replace; kept as <file>.mesh-bak.
MESH_REPLACED="/etc/avahi/avahi-daemon.conf /etc/caddy/Caddyfile /etc/resolv.conf /etc/hosts /etc/hostname /etc/hostapd/hostapd.conf"
# Services whose boot state install changes.
MESH_UNITS="dnsmasq hostapd caddy dhcpcd avahi-daemon"

[ "$EUID" -eq 0 ] || exec sudo -E "$SELF" "$@"

# ---------------------------------------------------------------- helpers ----

# Fatal error: stderr, plus a dialog inside the menu.
die() {
  echo "mesh-config: ERROR: $*" >&2
  [ "$INTERACTIVE" = 1 ] && command -v whiptail >/dev/null 2>&1 && whiptail --title "$TITLE: error" --msgbox "$*" 12 70
  exit 1
}

# mesh.conf: one key='value' per line, sourced by the mesh scripts. Values are
# stored single-quoted with embedded quotes escaped.
cfg_get() {
  local v q="'"
  [ -f "$CONF" ] || return 0
  v=$(sed -n "s/^$1=//p" "$CONF" | tail -n1)
  case $v in
    "$q"*"$q") v=${v#"$q"}; v=${v%"$q"}; v=${v//"$q\\$q$q"/"$q"} ;;
    \"*\")     v=${v#\"}; v=${v%\"} ;;
  esac
  printf '%s\n' "$v"
}
# Write or replace one key in mesh.conf (quoting rules above).
cfg_set() {
  local key=$1 val=$2 q="'"
  val=${val//"$q"/"$q\\$q$q"}
  { [ -f "$CONF" ] || : > "$CONF"; } 2>/dev/null || die "Cannot create $CONF"
  [ -w "$CONF" ] || die "Cannot write $CONF."
  if grep -q "^$key=" "$CONF"; then
    sed -i "/^$key=/d" "$CONF" || die "Cannot update $CONF."
  fi
  printf "%s='%s'\n" "$key" "$val" >> "$CONF" || die "Cannot update $CONF."
}
# Set a key only when it has no value yet.
cfg_default() { [ -n "$(cfg_get "$1")" ] || cfg_set "$1" "$2"; }
# Store a value; store an empty string when it equals the derived default.
cfg_set_or_follow() { if [ "$2" = "$3" ]; then cfg_set "$1" ""; else cfg_set "$1" "$2"; fi; }

# Names derived from the group when not set explicitly:
#   group_name   the group ("group" if unset)      mesh_name     ad-hoc network name, <group>.mesh
#   ap_ssid_name access point SSID, <group>-mesh   ap_psk_value  access point passphrase, <group>.mesh
group_name()   { local g; g=$(cfg_get group); echo "${g:-group}"; }
mesh_name()    { local v; v=$(cfg_get mesh_id); echo "${v:-$(group_name).mesh}"; }
ap_ssid_name() { local v; v=$(cfg_get ap_ssid); echo "${v:-$(group_name)-mesh}"; }
ap_psk_value() { local v; v=$(cfg_get ap_psk);  echo "${v:-$(group_name).mesh}"; }

# Install whiptail when missing.
ensure_whiptail() {
  command -v whiptail >/dev/null 2>&1 && return 0
  DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail >/dev/null 2>&1
  command -v whiptail >/dev/null 2>&1 || die "whiptail is not installed"
}
# Dialog wrappers: message box, text input (with default), password input, yes/no question.
msg()  { whiptail --title "$TITLE" --msgbox "$1" 12 70; }
ask()  { whiptail --title "$TITLE" --inputbox "$1" 11 72 "${2:-}" 3>&1 1>&2 2>&3; }
pass() { whiptail --title "$TITLE" --passwordbox "$1" 10 70 3>&1 1>&2 2>&3; }
yesno(){ whiptail --title "$TITLE" --yesno "$1" 10 70; }

# Show a text file: a scrollable dialog in the menu, plain output otherwise.
show_text() { if [ "$INTERACTIVE" = 1 ]; then whiptail --title "$TITLE: $1" --scrolltext --textbox "$2" 30 100; else cat "$2"; fi; }

# Run a command. On failure show its output and the recent mesh journal.
run_checked() {
  local out rc
  out=$(mktemp)
  "$@" >"$out" 2>&1; rc=$?
  if [ $rc -ne 0 ]; then
    {
      echo "Failed (exit $rc): $*"; echo
      cat "$out"
      echo; echo "---- systemctl status mesh.service ----"
      systemctl status mesh.service --no-pager -l 2>&1 | head -25
      echo; echo "---- journalctl -u mesh.service -u 'mesh-uplink@*' (last 40 lines) ----"
      journalctl -u mesh.service -u 'mesh-uplink@*' -n 40 --no-pager 2>&1
    } > "$out.err"
    show_text "error" "$out.err"
    rm -f "$out.err"
  fi
  rm -f "$out"
  return $rc
}

# Wi-Fi interfaces with their drivers.
wifi_ifaces() {
  local d
  for d in /sys/class/net/*; do
    [ -e "$d/phy80211" ] || continue
    printf '%s(%s) ' "$(basename "$d")" "$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)")"
  done
}
# Wi-Fi interfaces other than the built-in radio.
uplink_candidates() {
  local d
  for d in /sys/class/net/*; do
    [ -e "$d/phy80211" ] || continue
    [ "$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)")" = brcmfmac ] || basename "$d"
  done
}

# System files installed? Mesh active? Mesh enabled at boot?
installed() { [ -x /usr/local/sbin/mesh-up.sh ] && [ -f /etc/systemd/system/mesh.service ] && [ -f /usr/local/lib/mesh/common.sh ] && [ -x /usr/local/sbin/mesh-uplink.sh ]; }
mesh_active() { systemctl is-active --quiet mesh.service; }
mesh_enabled() { systemctl is-enabled --quiet mesh.service 2>/dev/null; }

# Defaults for unset keys; migration from earlier layouts.
set_defaults() {
  if [ -z "$(cfg_get group)" ] && [ -n "$(cfg_get course)" ]; then cfg_set group "$(cfg_get course)"; fi
  [ "$(cfg_get mesh_id)" = watiam-mesh ] && cfg_set mesh_id ""
  [ "$(cfg_get ap_psk)" = watiam-mesh ]  && cfg_set ap_psk ""
  [ "$(cfg_get uplink)" = eduroam ]      && cfg_set uplink external
  cfg_default group      group
  cfg_default mesh_if    auto
  cfg_default uplink_if  auto
  cfg_default uplink     ap
  cfg_default uplink_profile auto
  cfg_default ap_channel auto
  cfg_default mesh_channel 6
  cfg_default mesh_prefix 10
  cfg_default bridge_eth0 no
  cfg_default eth0_dhcp  yes
  cfg_default usb_gadget no
}

# ------------------------------------------------------------ system files ----

write_system_files() (
  # Subshell with set -e: the first failed write aborts the install. Call it
  # plainly and test $? ("write_system_files || ..." disables set -e inside).
  set -eE
  trap 'echo "mesh-config: install failed at line $LINENO: $BASH_COMMAND" >&2' ERR
  trap 'systemctl unmask hostapd >/dev/null 2>&1 || true' EXIT
  fail() { echo "mesh-config: ERROR: $*" >&2; exit 1; }

  systemctl is-active --quiet NetworkManager \
    || fail "NetworkManager is not running"
  [ -f "$CONF" ] || : > "$CONF" || fail "cannot create $CONF"

  # --- first install only: keep what is about to be replaced, and the boot
  #     state of each service before its package is installed, for uninstall.
  #     An install by an older mesh-config has already replaced it.
  install -d /etc/mesh
  if [ ! -f /etc/mesh/preinstall.state ]; then
    if [ -f /etc/systemd/system/mesh.service ]; then
      echo "# installed over an older mesh-config: no backups, service states unknown" > /etc/mesh/preinstall.state
    else
      {
        # new=: did not exist, uninstall removes it
        for f in $MESH_REPLACED; do
          if [ -e "$f" ] || [ -L "$f" ]; then
            [ -e "$f.mesh-bak" ] || cp -a "$f" "$f.mesh-bak"
          else
            echo "new=$f"
          fi
        done
        for u in $MESH_UNITS; do echo "$u=$(systemctl is-enabled "$u" 2>/dev/null || true)"; done
        echo "ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
        echo "rp_filter=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo 0)"
      } > /etc/mesh/preinstall.state
    fi
  fi

  echo "Installing packages..."
  # hostapd must not start with its stock config on installation.
  systemctl mask hostapd >/dev/null 2>&1 || true
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y batctl hostapd dnsmasq avahi-daemon avahi-utils \
         nftables curl iw bridge-utils whiptail >/dev/null; then
    echo "WARNING: apt-get install failed" >&2
    missing=""
    for b in batctl hostapd dnsmasq avahi-daemon nft iw; do
      command -v "$b" >/dev/null 2>&1 || missing="$missing $b"
    done
    [ -z "$missing" ] || fail "not installed:$missing"
  fi
  if ! command -v caddy >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y caddy >/dev/null 2>&1 || echo "WARNING: caddy is not installed" >&2
  fi
  systemctl unmask hostapd >/dev/null 2>&1 || true

  install -d /etc/mesh /usr/local/lib/mesh /etc/nftables.d /etc/dnsmasq.d /etc/avahi/services /etc/hostapd \
             /etc/caddy /etc/systemd/system/caddy.service.d /etc/NetworkManager/conf.d /etc/NetworkManager/dispatcher.d \
             /etc/udev/rules.d /etc/tmpfiles.d /var/www/mesh /usr/local/sbin /run/mesh /run/dnsmasq
  # Files from earlier layouts.
  rm -f /etc/dnsmasq.d/mesh.conf.tpl /etc/hostapd/hostapd.conf.tpl /etc/wpa_supplicant/wpa_supplicant-wlan1.conf.tpl \
        /etc/wpa_supplicant/wpa_supplicant-wlan0.conf /etc/mesh/wpa_supplicant-uplink.conf.tpl /etc/mesh/dhcpcd.conf.tpl \
        /etc/systemd/system/mesh-role.service /etc/systemd/system/mesh-role@.service /etc/avahi/services/watiam.service

  # --- runtime directories
  cat > /etc/tmpfiles.d/mesh.conf <<'EOF'
d /run/mesh 0755 root root -
d /run/dnsmasq 0755 root root -
f /run/dnsmasq/upstream.conf 0644 root root -
EOF
  touch /run/dnsmasq/upstream.conf /etc/hosts.mesh

  # --- shared helpers for the mesh scripts
  cat > /usr/local/lib/mesh/common.sh <<'EOF'
#!/bin/bash
# Shared helpers for the mesh scripts. Sourced, not executed.
CONF=/boot/firmware/mesh.conf; [ -f "$CONF" ] || CONF=/boot/mesh.conf
RUN=/run/mesh
WARN=$RUN/warnings
TPL=/etc/mesh

# Source mesh.conf when present and derive GROUP (defaults to "group").
load_conf() { [ -f "$CONF" ] && . "$CONF"; GROUP=${group:-group}; return 0; }

# render TEMPLATE DEST KEY=VALUE...  Literal replacement of @KEY@ tags.
render() {
  local tpl dest kv
  tpl=$(cat "$1") || return 1
  dest=$2; shift 2
  for kv in "$@"; do tpl=${tpl//"@${kv%%=*}@"/"${kv#*=}"}; done
  printf '%s\n' "$tpl" > "$dest"
}

# The built-in radio (brcmfmac). Interface names change with a second radio present.
detect_mesh_if() {
  local d
  for d in /sys/class/net/*; do
    [ -e "$d/phy80211" ] || continue
    [ "$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)")" = brcmfmac ] && { basename "$d"; return 0; }
  done
  [ -e /sys/class/net/wlan0 ] && { echo wlan0; return 0; }
  return 1
}
# First Wi-Fi interface other than the mesh radio ($1).
detect_uplink_if() {
  local d n
  for d in /sys/class/net/*; do
    [ -e "$d/phy80211" ] || continue
    n=$(basename "$d")
    [ "$n" != "$1" ] && { echo "$n"; return 0; }
  done
  return 1
}
# mesh_if / uplink_if from mesh.conf: "auto" or an explicit interface name.
resolve_mesh_if()   { case ${mesh_if:-auto}   in auto) detect_mesh_if ;;        *) echo "$mesh_if" ;;   esac; }
resolve_uplink_if() { case ${uplink_if:-auto} in auto) detect_uplink_if "$1" ;; *) echo "$uplink_if" ;; esac; }

# Interface of the default route, unless it belongs to the mesh.
external_dev() {
  local mif; mif=$(sed -n 's/^MESH_IF=//p' /etc/default/mesh 2>/dev/null)
  ip -4 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}' \
    | grep -vx -e br0 -e bat0 -e lo -e "${mif:-none}" | head -1
}
EOF

  # --- NetworkManager dispatcher: mesh off, dnsmasq forwards to NetworkManager's
  #     DNS servers; mesh on, every network change re-runs the gateway check.
  cat > /etc/NetworkManager/dispatcher.d/50-mesh-dns <<'EOF'
#!/bin/bash
# NetworkManager runs this as "50-mesh-dns IFACE ACTION"; the mesh scripts as
# "50-mesh-dns any refresh".
case "${2:-}" in
  up|down|dhcp4-change|dhcp6-change|connectivity-change|dns-change|reapply|refresh) ;;
  *) exit 0 ;;
esac
if [ "${2:-}" != refresh ]; then
  case "$(systemctl is-active mesh.service 2>/dev/null)" in
    active|activating|reloading) systemctl start --no-block mesh-role-check.service 2>/dev/null; exit 0 ;;
  esac
fi
umask 022
install -d /run/dnsmasq
# nmcli -g joins several servers as "a | b".
nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: '$2=="connected"{print $1}' \
  | while read -r dev; do nmcli -g IP4.DNS device show "$dev" 2>/dev/null; done \
  | tr '|' '\n' | sed 's/[[:space:]]//g; /^$/d; s/^/server=/' | awk '!seen[$0]++' > /run/dnsmasq/upstream.conf.new
mv -f /run/dnsmasq/upstream.conf.new /run/dnsmasq/upstream.conf
if pkill -HUP -x dnsmasq 2>/dev/null; then
  # dnsmasq running: resolver points at it
  grep -qx 'nameserver 127.0.0.1' /etc/resolv.conf 2>/dev/null \
    || { rm -f /etc/resolv.conf; printf 'nameserver 127.0.0.1\nsearch mesh\n' > /etc/resolv.conf; }
else
  # dnsmasq not running: resolver points at NetworkManager's servers
  sed 's/^server=/nameserver /' /run/dnsmasq/upstream.conf > /etc/resolv.conf.new
  if [ -s /etc/resolv.conf.new ]; then
    rm -f /etc/resolv.conf; mv -f /etc/resolv.conf.new /etc/resolv.conf
    logger -t mesh-dns -p user.err "dnsmasq not running; resolv.conf set to NetworkManager servers"
  else
    rm -f /etc/resolv.conf.new
  fi
fi
exit 0
EOF
  chmod 755 /etc/NetworkManager/dispatcher.d/50-mesh-dns

  # --- udev: start the uplink role when a Wi-Fi interface other than the
  #     built-in radio appears (no-op while the mesh is off)
  cat > /etc/udev/rules.d/90-mesh-uplink.rules <<'EOF'
# Written by mesh-config.
SUBSYSTEM=="net", ACTION=="add", ENV{DEVTYPE}=="wlan", DRIVERS!="brcmfmac", TAG+="systemd", ENV{SYSTEMD_WANTS}+="mesh-uplink@$name.service"
EOF
  udevadm control --reload >/dev/null 2>&1 || true

  # --- sysctl, modules
  printf 'net.ipv4.ip_forward = 1\nnet.ipv4.conf.all.rp_filter = 0\n' > /etc/sysctl.d/90-mesh.conf
  echo batman-adv > /etc/modules-load.d/batman.conf

  # --- templates, rendered by the mesh scripts (@TAG@ replaced); kept out of
  #     /etc/dnsmasq.d, which dnsmasq reads whole
  cat > /etc/mesh/dnsmasq.conf.tpl <<'EOF'
interface=br0
bind-dynamic
dhcp-range=@IP_PREFIX@.10,@IP_PREFIX@.250,255.0.0.0,10m
dhcp-option=option:dns-server,@IP@
dhcp-option=option:router,@IP@
domain=mesh
local=/mesh/
expand-hosts
addn-hosts=/etc/hosts.mesh
address=/@GROUP@.mesh/@IP@
servers-file=/run/dnsmasq/upstream.conf
no-resolv
cache-size=1000
EOF
  # placeholder until the first mesh start
  [ -f /etc/dnsmasq.d/mesh.conf ] || printf 'no-resolv\nservers-file=/run/dnsmasq/upstream.conf\n' > /etc/dnsmasq.d/mesh.conf

  cat > /etc/mesh/hostapd.conf.tpl <<'EOF'
interface=@UPLINK_IF@
bridge=br0
driver=nl80211
# same SSID on every AP node
ssid=@AP_SSID@
country_code=CA
ieee80211d=1
hw_mode=a
# fixed per node (esp-hosted has no automatic channel selection); non-DFS 5 GHz only
channel=@AP_CHANNEL@
ieee80211n=1
ieee80211ac=1
wmm_enabled=1
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_passphrase=@AP_PSK@
rsn_pairwise=CCMP
EOF

  # --- firewall table for gateway nodes (rendered with the uplink interface)
  cat > /etc/mesh/meshgw.nft.tpl <<'EOF'
table inet meshgw {
  chain forward {
    type filter hook forward priority 0; policy drop;
    iifname "br0"   oifname "@UPLINK_IF@" accept
    iifname "@UPLINK_IF@" oifname "br0" ct state established,related accept
    iifname "br0"   oifname "br0" accept
  }
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "@UPLINK_IF@" masquerade
  }
}
EOF

  # --- DHCP filter for a bridged eth0 (eth0_dhcp=no): dnsmasq only sees br0,
  #     so requests in and offers out are dropped at the bridge port
  cat > /etc/mesh/meshdhcp.nft <<'EOF'
table bridge meshdhcp {
  chain pre {
    type filter hook prerouting priority 0; policy accept;
    iifname "eth0" udp dport 67 drop
  }
  chain post {
    type filter hook postrouting priority 0; policy accept;
    oifname "eth0" udp sport 67 drop
  }
}
EOF

  # --- avahi
  cat > /etc/avahi/avahi-daemon.conf <<'EOF'
[server]
use-ipv4=yes
use-ipv6=no
allow-interfaces=br0

[publish]
publish-hinfo=no
publish-workstation=no
EOF
  cat > /etc/avahi/services/groupmesh.service <<'EOF'
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

  # --- caddy
  cat > /etc/caddy/Caddyfile <<'EOF'
{
  auto_https off
}

http://{$GROUP}.mesh, http://{$ID}.mesh, http://{$ID}.local, http://{$MYIP} {
  bind {$MYIP}

  redir /{$ID} /{$ID}/ 301
  # <group>.mesh is this node; proxying /<group>/ would loop
  redir /{$GROUP} / 302
  redir /{$GROUP}/* / 302

  handle_path /{$ID}/* {
    root * /home/{$ID}/public
    file_server browse
  }

  # a request another node already forwarded is never forwarded again
  @peer {
    path_regexp p ^/([a-z0-9]+)(/.*)?$
    not path /{$ID} /{$ID}/*
    not header X-Mesh-Hop *
  }
  handle @peer {
    reverse_proxy {re.p.1}.mesh:80 {
      header_up X-Mesh-Hop 1
    }
  }

  handle {
    root * /var/www/mesh
    file_server
  }
}
EOF
  cat > /etc/systemd/system/caddy.service.d/mesh.conf <<'EOF'
[Unit]
# started by mesh-up.sh, stopped with the mesh; PartOf, not Requires
After=mesh.service
PartOf=mesh.service

[Service]
EnvironmentFile=/etc/default/mesh
EOF

  # --- scripts
  cat > /usr/local/sbin/mesh-up.sh <<'EOF'
#!/bin/bash
# Bring the mesh up (ExecStart of mesh.service). On any failure systemd runs
# mesh-down.sh (ExecStopPost).
set -eu
. /usr/local/lib/mesh/common.sh
install -d "$RUN"; : > "$WARN"; rm -f "$RUN/up" "$RUN/uplink" "$RUN/gateway"
# fail: log and abort.  warn: log, record for the status page, continue.
fail() { echo "mesh-up: ERROR: $*" >&2; logger -t mesh-up -p user.err "ERROR: $*"; exit 1; }
warn() { echo "mesh-up: WARNING: $*" >&2; logger -t mesh-up -p user.warning "WARNING: $*"; echo "$*" >> "$WARN"; }
trap 'rc=$?; echo "mesh-up: FAILED (exit $rc) at line $LINENO: $BASH_COMMAND" >&2; logger -t mesh-up -p user.err "FAILED at line $LINENO: $BASH_COMMAND"' ERR

[ -f "$CONF" ] || fail "$CONF not found"
load_conf
ID=${id:-}; [ -n "$ID" ] || fail "id not set in $CONF"
[[ $ID =~ ^[a-z0-9]+$ ]]    || fail "invalid id '$ID'"
[[ $GROUP =~ ^[a-z0-9]+$ ]] || fail "invalid group '$GROUP'"
[ "$ID" != "$GROUP" ]       || fail "id and group must differ ('$ID')"
PFX=${mesh_prefix:-10}
UPLINK=${uplink:-ap}
MESH_ID=${mesh_id:-$GROUP.mesh}
case "${mesh_channel:-6}" in 1) FREQ=2412;; 11) FREQ=2462;; *) FREQ=2437;; esac
# cell id derived from the mesh name (locally administered MAC)
BSSID=02:$(printf %s "$MESH_ID" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*/\1:\2:\3:\4:\5/')

# 0. Checks, before any interface is touched
MESH_IF=""
for _ in $(seq 30); do   # the radio may still be probing at boot
  MESH_IF=$(resolve_mesh_if || true)
  [ -n "$MESH_IF" ] && [ -e "/sys/class/net/$MESH_IF" ] && break
  sleep 0.5
done
[ -n "$MESH_IF" ] && [ -e "/sys/class/net/$MESH_IF" ] || fail "no mesh radio (mesh_if=${mesh_if:-auto})"
command -v iw >/dev/null 2>&1 || fail "iw not installed"
modes=$(iw phy "$(cat "/sys/class/net/$MESH_IF/phy80211/name" 2>/dev/null)" info 2>/dev/null \
        | sed -n '/Supported interface modes:/,/^\t[^\t]/p' || true)
if [ -n "$modes" ] && ! echo "$modes" | grep -q '\* IBSS'; then
  fail "$MESH_IF has no IBSS mode (modes:$(echo "$modes" | sed -n 's/^.*\* / /p' | tr -d '\n'))"
fi
modprobe batman-adv || fail "batman-adv module not available"
command -v batctl >/dev/null 2>&1 || fail "batctl not installed"
[ -f "$TPL/dnsmasq.conf.tpl" ] || fail "$TPL/dnsmasq.conf.tpl not found (run install)"
systemctl is-active --quiet NetworkManager || warn "NetworkManager not running"
[ -z "${mesh_psk:-}" ] || warn "mesh_psk ignored: the ad-hoc network is open"
rfkill unblock wifi 2>/dev/null || true

# 1. Identity
hostnamectl set-hostname "$ID"
if grep -q '^127\.0\.1\.1' /etc/hosts; then sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$ID/" /etc/hosts; else printf '127.0.1.1\t%s\n' "$ID" >> /etc/hosts; fi
id -u "$ID" >/dev/null 2>&1 || useradd -m -s /bin/bash "$ID"
install -d -o "$ID" -g "$ID" -m 755 "/home/$ID/public"
chmod 711 "/home/$ID"   # caddy reaches public/; other users cannot list the home folder

# 2. Address from the mesh radio's MAC (peers derive a gateway's address the same way)
m=$(cat "/sys/class/net/$MESH_IF/address")
X=$((0x${m:12:2})); Y=$((0x${m:15:2}))
MYIP="$PFX.$X.$Y.1"; IP_PREFIX="$PFX.$X.$Y"

# 3. Take the mesh radio and the bridged ports from NetworkManager
ports=""
[ "${bridge_eth0:-no}" = yes ] && [ -e /sys/class/net/eth0 ] && ports="eth0" || true
[ "${usb_gadget:-no}" = yes ] && [ -e /sys/class/net/usb0 ] && ports="$ports usb0" || true
for d in "$MESH_IF" $ports; do
  nmcli device set "$d" managed no >/dev/null 2>&1 || true
done
# wpa_supplicant releases the radio after NetworkManager reports "unmanaged" and
# resets it to managed mode on release; wait for its control socket to go away.
for _ in $(seq 30); do
  case "$(nmcli -g GENERAL.STATE device show "$MESH_IF" 2>/dev/null || true)" in
    *unmanaged*|"") [ -e "/run/wpa_supplicant/$MESH_IF" ] || break ;;
  esac
  sleep 0.5
done
[ -e "/run/wpa_supplicant/$MESH_IF" ] && warn "wpa_supplicant still holds $MESH_IF"
sleep 1

# 4. Ad-hoc cell, batman-adv, bridge
for attempt in 1 2 3; do
  ip link set "$MESH_IF" down
  iw dev "$MESH_IF" set type ibss || fail "cannot set $MESH_IF to IBSS mode"
  ip link set "$MESH_IF" mtu 1532 2>/dev/null || true   # brcmfmac allows 1500 at most; batman-adv fragments
  ip link set "$MESH_IF" up
  sleep 0.5
  iw dev "$MESH_IF" info 2>/dev/null | grep -q 'type IBSS' && break
  [ "$attempt" = 3 ] && fail "$MESH_IF does not stay in IBSS mode"
  logger -t mesh-up "$MESH_IF left IBSS mode, retrying ($attempt)"
done
iw dev "$MESH_IF" ibss leave 2>/dev/null || true
iw dev "$MESH_IF" ibss join "$MESH_ID" "$FREQ" fixed-freq "$BSSID" \
  || fail "ibss join failed on $MESH_IF ('$MESH_ID', $FREQ MHz, $BSSID)"
ip link add bat0 type batadv 2>/dev/null || true
batctl if add "$MESH_IF" 2>/dev/null || batctl if 2>/dev/null | grep -q "^$MESH_IF:" || fail "batctl if add $MESH_IF failed"
batctl gw_mode client
ip link add br0 type bridge 2>/dev/null || true
ip link set bat0 master br0
ip link set bat0 up
ip link set br0 up
ip addr replace "$MYIP/8" dev br0
# loaded before eth0 joins br0, so no offer slips through
nft delete table bridge meshdhcp 2>/dev/null || true
if [[ " $ports " == *" eth0 "* ]] && [ "${eth0_dhcp:-yes}" = no ]; then
  nft -f "$TPL/meshdhcp.nft" || warn "cannot block DHCP on eth0"
fi
for p in $ports; do
  { ip link set "$p" master br0 && ip link set "$p" up; } || warn "cannot add $p to br0"
done
for _ in $(seq 20); do   # join or cell creation takes a few seconds
  iw dev "$MESH_IF" link 2>/dev/null | grep -q 'Joined IBSS' && break
  sleep 0.5
done
iw dev "$MESH_IF" link 2>/dev/null | grep -q 'Joined IBSS' \
  || warn "$MESH_IF not joined yet (iw dev $MESH_IF link)"

# 5. Per-node files, services on the bridge
render "$TPL/dnsmasq.conf.tpl" /etc/dnsmasq.d/mesh.conf IP="$MYIP" IP_PREFIX="$IP_PREFIX" ID="$ID" GROUP="$GROUP"
printf 'ID=%s\nMYIP=%s\nGROUP=%s\nMESH_IF=%s\nMESH_BSSID=%s\n' "$ID" "$MYIP" "$GROUP" "$MESH_IF" "$BSSID" > /etc/default/mesh
install -d /run/dnsmasq; : > /run/dnsmasq/upstream.conf
touch /etc/hosts.mesh
install -d /var/www/mesh
[ -e /var/www/mesh/index.html ] || echo "<h1>$GROUP</h1>" > /var/www/mesh/index.html
systemctl restart dnsmasq || { journalctl -t dnsmasq -n 5 --no-pager >&2 || true; fail "dnsmasq failed to start"; }
grep -qx 'nameserver 127.0.0.1' /etc/resolv.conf 2>/dev/null \
  || { rm -f /etc/resolv.conf; printf 'nameserver 127.0.0.1\nsearch mesh\n' > /etc/resolv.conf; }
systemctl start avahi-daemon || warn "avahi-daemon failed to start"
# caddy is After=mesh.service: queue it, do not wait for it
if command -v caddy >/dev/null 2>&1; then
  systemctl restart --no-block caddy || warn "caddy failed to start"
fi

# 6. Uplink role (separate unit, started by udev when the radio appears)
touch "$RUN/up"
UPLINK_IF=$(resolve_uplink_if "$MESH_IF" || true)
if [ "$UPLINK" = off ]; then
  :
elif [ -n "$UPLINK_IF" ] && [ -e "/sys/class/net/$UPLINK_IF" ]; then
  systemctl start --no-block "mesh-uplink@$UPLINK_IF.service" || warn "cannot start mesh-uplink@$UPLINK_IF"
else
  warn "no uplink radio attached (uplink_if=${uplink_if:-auto})"
fi
systemctl start --no-block mesh-role-check.service 2>/dev/null || true
n=$(wc -l < "$WARN")
logger -t mesh-up "up: $ID $MYIP $MESH_IF cell '$MESH_ID' $BSSID $FREQ MHz uplink=$UPLINK/${UPLINK_IF:-none} warnings=$n"
exit 0
EOF

  cat > /usr/local/sbin/mesh-down.sh <<'EOF'
#!/bin/bash
# Undo mesh-up.sh (ExecStopPost of mesh.service, also after a failed start).
# Idempotent.
set -u
. /usr/local/lib/mesh/common.sh
load_conf
MESH_IF=$(sed -n 's/^MESH_IF=//p' /etc/default/mesh 2>/dev/null)
[ -n "$MESH_IF" ] || MESH_IF=$(resolve_mesh_if || true)
UPLINK_IF=$(cat "$RUN/uplink" 2>/dev/null || true)

rm -f "$RUN/up"
systemctl stop 'mesh-uplink@*.service' 2>/dev/null
systemctl stop mesh-role-check.timer mesh-hosts.timer hostapd caddy avahi-daemon 2>/dev/null
nft delete table inet meshgw 2>/dev/null
nft delete table bridge meshdhcp 2>/dev/null
rm -f "$RUN/uplink" "$RUN/gateway"

[ -n "$MESH_IF" ] && batctl if del "$MESH_IF" 2>/dev/null
ip link del bat0 2>/dev/null
ip link del br0 2>/dev/null

# Reset the mesh radio only while NetworkManager does not have it.
if [ -n "$MESH_IF" ]; then
  case "$(nmcli -g GENERAL.STATE device show "$MESH_IF" 2>/dev/null)" in
    *unmanaged*|"")
      iw dev "$MESH_IF" ibss leave 2>/dev/null
      ip link set "$MESH_IF" down 2>/dev/null
      ip link set "$MESH_IF" mtu 1500 2>/dev/null
      iw dev "$MESH_IF" set type managed 2>/dev/null
      ip link set "$MESH_IF" up 2>/dev/null ;;
  esac
fi
for d in "$MESH_IF" "$UPLINK_IF" eth0; do
  [ -n "$d" ] && [ -e "/sys/class/net/$d" ] && nmcli device set "$d" managed yes >/dev/null 2>&1
done

# DNS: forward to NetworkManager's servers again
systemctl is-active --quiet dnsmasq || systemctl start dnsmasq 2>/dev/null
if [ -x /etc/NetworkManager/dispatcher.d/50-mesh-dns ]; then
  /etc/NetworkManager/dispatcher.d/50-mesh-dns any refresh
else
  : > /run/dnsmasq/upstream.conf 2>/dev/null; pkill -HUP -x dnsmasq 2>/dev/null
fi
logger -t mesh-down "mesh stopped"
exit 0
EOF

  cat > /usr/local/sbin/mesh-uplink.sh <<'EOF'
#!/bin/bash
# Uplink radio role: "mesh-uplink.sh IFACE up|down|check". Run by
# mesh-uplink@IFACE.service (udev starts it with the radio); "check" is the
# periodic fallback.
#   external  NetworkManager keeps the radio and activates the chosen connection
#   ap        hostapd broadcasts the group access point
set -u
. /usr/local/lib/mesh/common.sh
IF=${1:-}; ACTION=${2:-up}
[ "$IF" = - ] && IF=""
load_conf
UPLINK=${uplink:-ap}
PROFILE=${uplink_profile:-auto}
# Log a warning and record it for the status page.
warn() { echo "mesh-uplink: WARNING: $*" >&2; logger -t mesh-uplink -p user.warning "WARNING: $*"; echo "$*" >> "$WARN"; }
MESH_IF=$(sed -n 's/^MESH_IF=//p' /etc/default/mesh 2>/dev/null)
is_uplink() {   # does $1 carry the uplink role?
  [ -n "$1" ] && [ "$1" != "$MESH_IF" ] || return 1
  case ${uplink_if:-auto} in
    auto) [ -e "/sys/class/net/$1/phy80211" ] ;;
    *)    [ "$1" = "$uplink_if" ] ;;
  esac
}

case $ACTION in
  check)
    [ -e "$RUN/up" ] || exit 0
    cur=$(cat "$RUN/uplink" 2>/dev/null || true)
    if [ -n "$cur" ] && [ ! -e "/sys/class/net/$cur" ]; then
      systemctl stop "mesh-uplink@$cur.service" 2>/dev/null
      cur=""
    fi
    if [ -z "$cur" ] && [ "$UPLINK" != off ]; then
      want=$(resolve_uplink_if "$MESH_IF" || true)
      [ -n "$want" ] && [ -e "/sys/class/net/$want" ] && systemctl start --no-block "mesh-uplink@$want.service"
    fi
    exit 0 ;;
  down)
    [ -n "$IF" ] && [ "$IF" != "$MESH_IF" ] || exit 0
    if [ "$(cat "$RUN/uplink" 2>/dev/null)" = "$IF" ]; then
      # external connections stay with NetworkManager
      systemctl stop hostapd 2>/dev/null
      rm -f "$RUN/uplink"
      [ -x /usr/local/sbin/mesh-role.sh ] && /usr/local/sbin/mesh-role.sh UNPLUGGED
      logger -t mesh-uplink "$IF released"
    fi
    exit 0 ;;
esac

# up
[ -e "$RUN/up" ] || { echo "mesh-uplink: mesh not running" >&2; exit 0; }
[ -n "$IF" ] && [ -e "/sys/class/net/$IF" ] || { echo "mesh-uplink: no interface '$IF'" >&2; exit 1; }
is_uplink "$IF" || { echo "mesh-uplink: $IF is not the uplink interface" >&2; exit 0; }
cur=$(cat "$RUN/uplink" 2>/dev/null || true)
if [ -n "$cur" ] && [ "$cur" != "$IF" ] && [ -e "/sys/class/net/$cur" ]; then
  echo "mesh-uplink: uplink already on $cur" >&2; exit 0
fi
[ "$UPLINK" = off ] && { logger -t mesh-uplink "$IF present but uplink=off"; exit 0; }
echo "$IF" > "$RUN/uplink"
case "$UPLINK" in
  external)
    # "auto": NetworkManager autoconnect
    nmcli device set "$IF" managed yes >/dev/null 2>&1 || true
    if [ "$PROFILE" != auto ]; then
      if ! nmcli -g connection.id connection show "$PROFILE" >/dev/null 2>&1; then
        warn "NetworkManager connection '$PROFILE' not found"
      else
        # a connection pinned to the mesh radio must float to the uplink radio
        if [ "$(nmcli -g connection.interface-name connection show "$PROFILE" 2>/dev/null)" = "$MESH_IF" ]; then
          nmcli connection modify "$PROFILE" connection.interface-name "" >/dev/null 2>&1 \
            && logger -t mesh-uplink "connection '$PROFILE': interface-name $MESH_IF cleared"
        fi
        if [ "$(nmcli -g connection.type connection show "$PROFILE" 2>/dev/null)" = 802-11-wireless ]; then
          nmcli -w 30 connection up id "$PROFILE" ifname "$IF" >/dev/null 2>&1 \
            || nmcli -w 30 connection up id "$PROFILE" >/dev/null 2>&1 \
            || warn "nmcli connection up '$PROFILE' failed"
        else
          nmcli -w 30 connection up id "$PROFILE" >/dev/null 2>&1 \
            || warn "nmcli connection up '$PROFILE' failed"
        fi
      fi
    fi
    systemctl start --no-block mesh-role-check.service 2>/dev/null
    logger -t mesh-uplink "$IF: external, connection $PROFILE"
    ;;
  ap)
    AP_SSID=${ap_ssid:-$GROUP-mesh}
    AP_CHANNEL=${ap_channel:-auto}
    if [ "$AP_CHANNEL" = auto ]; then
      # one of the non-DFS 5 GHz channels, by node id
      AP_CHANNEL=$((36 + 4 * (0x$(printf %s "${id:-}" | md5sum | cut -c1-2) % 4)))
    fi
    nmcli device set "$IF" managed no >/dev/null 2>&1 || true
    render "$TPL/hostapd.conf.tpl" /etc/hostapd/hostapd.conf UPLINK_IF="$IF" AP_SSID="$AP_SSID" AP_CHANNEL="$AP_CHANNEL" AP_PSK="${ap_psk:-$GROUP.mesh}"
    systemctl start hostapd \
      || { warn "hostapd failed to start on $IF ('$AP_SSID', channel $AP_CHANNEL)"; exit 1; }
    logger -t mesh-uplink "$IF: ap '$AP_SSID' channel $AP_CHANNEL"
    ;;
esac
exit 0
EOF

  cat > /usr/local/sbin/mesh-role.sh <<'EOF'
#!/bin/bash
# Gateway role: on while a connection outside the mesh reaches the internet,
# off otherwise. Run on every NetworkManager event, by the periodic timer and
# when the uplink radio is unplugged. Arg: event name for the log.
set -u
. /usr/local/lib/mesh/common.sh
EV=${1:-CHECK}; [ "$EV" = - ] && EV=CHECK
case "$(systemctl is-active mesh.service 2>/dev/null)" in active|activating) ;; *) exit 0 ;; esac
load_conf
PFX=${mesh_prefix:-10}
WAS=$(cat "$RUN/gateway" 2>/dev/null || true)     # current gateway interface, if any

# online: $1 reaches the internet.  peer_ip: batman originator MAC to mesh address.
# nm_name: NetworkManager connection on $1.
online()  { curl -fsm5 -o /dev/null --interface "$1" http://detectportal.firefox.com/success.txt; }
peer_ip() { echo "$PFX.$((0x${1:12:2})).$((0x${1:15:2})).1"; }
nm_name() { nmcli -g GENERAL.CONNECTION device show "$1" 2>/dev/null; }
upstream_from() {   # dnsmasq forwarders = NetworkManager's DNS servers on $1
  local dns; dns=$(nmcli -g IP4.DNS device show "$1" 2>/dev/null | tr '|' '\n' | sed 's/[[:space:]]//g; /^$/d')
  { for d in ${dns:-1.1.1.1}; do echo "server=$d@$1"; done; } > /run/dnsmasq/upstream.conf
}

# Gateway on: NAT via $1, batman-adv gateway announcement, DNS forwarders from $1.
gateway_on() {
  nft delete table inet meshgw 2>/dev/null
  render "$TPL/meshgw.nft.tpl" /etc/nftables.d/meshgw.nft UPLINK_IF="$1" && nft -f /etc/nftables.d/meshgw.nft
  ip route del default dev br0 2>/dev/null
  batctl gw_mode server 50mbit/20mbit
  upstream_from "$1"
  echo "$1" > "$RUN/gateway"
  logger -t mesh-role "gateway on: $1 ($(nm_name "$1")) [$EV]"
}
# Gateway off: route through the gateway batman-adv selected, if any.
gateway_off() {
  nft delete table inet meshgw 2>/dev/null
  batctl gw_mode client
  mac=$(batctl gwl -H 2>/dev/null | awk '/^\*/{print $2}')
  if [ -n "$mac" ]; then
    ip route replace default via "$(peer_ip "$mac")" dev br0 metric 50
    echo "server=$(peer_ip "$mac")" > /run/dnsmasq/upstream.conf
  else
    ip route del default dev br0 2>/dev/null
    : > /run/dnsmasq/upstream.conf
  fi
  rm -f "$RUN/gateway"
  [ -n "$WAS" ] && logger -t mesh-role "gateway off (was $WAS) [$EV]"
}

dev=$(external_dev)
if [ -n "$dev" ] && online "$dev"; then
  if [ "$dev" = "$WAS" ]; then upstream_from "$dev"; else gateway_on "$dev"; fi
else
  gateway_off
fi
pkill -HUP -x dnsmasq 2>/dev/null
exit 0
EOF

  cat > /usr/local/sbin/mesh-hosts.sh <<'EOF'
#!/bin/bash
# Rebuild /etc/hosts.mesh from mDNS and the directory page. Names come from any
# host on the open mesh: only valid ids and IPv4 addresses are taken, which
# also keeps markup out of the page.
systemctl is-active --quiet mesh.service || exit 0
. /usr/local/lib/mesh/common.sh
load_conf
avahi-browse -trp _groupmesh._tcp 2>/dev/null \
  | awk -F';' '$1=="=" && $3=="IPv4" && $4 ~ /^[a-z0-9]+$/ && $8 ~ /^[0-9]+(\.[0-9]+)(\.[0-9]+)(\.[0-9]+)$/ {print $8, $4".mesh"}' \
  | sort -u > /etc/hosts.mesh.new
if ! cmp -s /etc/hosts.mesh.new /etc/hosts.mesh; then
  mv /etc/hosts.mesh.new /etc/hosts.mesh
  pkill -HUP -x dnsmasq 2>/dev/null
  {
    echo "<!doctype html><meta charset=utf-8><title>${GROUP}</title>"
    echo "<h1>${GROUP} on the mesh</h1><ul>"
    awk '{sub(/\.mesh$/,"",$2); print "<li><a href=\"/"$2"/\">"$2"</a></li>"}' /etc/hosts.mesh
    echo "</ul>"
  } > /var/www/mesh/index.html
else
  rm -f /etc/hosts.mesh.new
fi
exit 0
EOF
  chmod +x /usr/local/sbin/mesh-up.sh /usr/local/sbin/mesh-down.sh /usr/local/sbin/mesh-uplink.sh \
           /usr/local/sbin/mesh-role.sh /usr/local/sbin/mesh-hosts.sh

  # --- systemd units
  cat > /etc/systemd/system/mesh.service <<'EOF'
[Unit]
Description=Pi mesh node bring-up (ad-hoc + batman-adv on the built-in radio)
After=NetworkManager.service
Wants=NetworkManager.service mesh-hosts.timer mesh-role-check.timer

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=120
ExecStart=/usr/local/sbin/mesh-up.sh
# ExecStopPost also runs after a failed start
ExecStopPost=/usr/local/sbin/mesh-down.sh

[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/mesh-uplink@.service <<'EOF'
[Unit]
Description=Uplink radio role on %i (external network or access point)
# started by udev when %i appears, stopped when %i disappears or the mesh stops
ConditionPathExists=/run/mesh/up
BindsTo=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device mesh.service
PartOf=mesh.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/mesh-uplink.sh %i up
ExecStopPost=/usr/local/sbin/mesh-uplink.sh %i down
EOF
  cat > /etc/systemd/system/mesh-role-check.service <<'EOF'
[Unit]
Description=Gateway role check and uplink hot-plug fallback
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mesh-uplink.sh - check
ExecStart=/usr/local/sbin/mesh-role.sh CHECK
EOF
  # timers run only while mesh.service is active (Wants= there, BindsTo= here)
  cat > /etc/systemd/system/mesh-role-check.timer <<'EOF'
[Unit]
Description=Run the gateway role check every two minutes while the mesh runs
BindsTo=mesh.service
After=mesh.service
[Timer]
OnActiveSec=30
OnUnitActiveSec=2min
EOF
  cat > /etc/systemd/system/mesh-hosts.service <<'EOF'
[Unit]
Description=Rebuild /etc/hosts.mesh from mDNS
After=mesh.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mesh-hosts.sh
EOF
  cat > /etc/systemd/system/mesh-hosts.timer <<'EOF'
[Unit]
Description=Sweep the mesh for names every minute while the mesh runs
BindsTo=mesh.service
After=mesh.service
[Timer]
OnActiveSec=15
OnUnitActiveSec=1min
EOF

  # --- activate (NetworkManager's wpa_supplicant.service is left alone)
  systemctl disable --now hostapd dhcpcd >/dev/null 2>&1 || true
  systemctl disable caddy >/dev/null 2>&1 || true
  systemctl daemon-reload
  systemctl disable mesh-hosts.timer mesh-role-check.timer >/dev/null 2>&1 || true
  systemctl enable dnsmasq >/dev/null 2>&1 || echo "WARNING: could not enable dnsmasq at boot" >&2
  systemctl reset-failed dnsmasq >/dev/null 2>&1 || true
  if ! systemctl restart dnsmasq; then
    journalctl -t dnsmasq -n 10 --no-pager >&2 || true
    fail "dnsmasq failed to start"
  fi

  # --- resolver: dnsmasq forwards to the current DNS servers; NetworkManager
  #     stops writing resolv.conf; resolv.conf points at dnsmasq
  old_ns=$(sed -n 's/^nameserver[[:space:]]*//p' /etc/resolv.conf 2>/dev/null | grep -v '^127\.' || true)
  cat > /etc/NetworkManager/conf.d/99-mesh.conf <<'EOF'
[main]
dns=none

[keyfile]
unmanaged-devices=interface-name:bat0;interface-name:br0;interface-name:usb0
EOF
  nmcli general reload >/dev/null 2>&1 || systemctl reload NetworkManager >/dev/null 2>&1 || true
  /etc/NetworkManager/dispatcher.d/50-mesh-dns any refresh || true
  if [ ! -s /run/dnsmasq/upstream.conf ] && [ -n "$old_ns" ]; then
    printf 'server=%s\n' $old_ns > /run/dnsmasq/upstream.conf
    pkill -HUP -x dnsmasq 2>/dev/null || true
  fi
  rm -f /etc/resolv.conf     # usually a symlink into /run/NetworkManager
  printf 'nameserver 127.0.0.1\nsearch mesh\n' > /etc/resolv.conf

  sysctl -q --system >/dev/null 2>&1 || true
  modprobe batman-adv 2>/dev/null || echo "WARNING: batman-adv module not loaded" >&2
  install -m 755 "$SELF" /usr/local/sbin/mesh-config 2>/dev/null || true
  echo "System files written"
)

# Undo install: stop the mesh, remove every file install wrote, restore the
# replaced files and the service states from before the first install.
# Packages, users, /home/<id>, /var/www/mesh and mesh.conf stay.
uninstall_mesh() (
  [ -f /etc/systemd/system/mesh.service ] || [ -d /etc/mesh ] || { echo "mesh-config is not installed"; exit 0; }
  echo "Stopping the mesh..."
  if systemctl is-active --quiet mesh.service; then
    systemctl stop mesh.service
  elif [ -x /usr/local/sbin/mesh-down.sh ]; then
    /usr/local/sbin/mesh-down.sh
  fi
  systemctl stop mesh-hosts.timer mesh-role-check.timer 'mesh-uplink@*.service' 2>/dev/null
  systemctl disable mesh.service mesh-hosts.timer mesh-role-check.timer >/dev/null 2>&1
  state=$(grep -v '^#' /etc/mesh/preinstall.state 2>/dev/null)

  echo "Removing system files..."
  rm -f /usr/local/sbin/mesh-up.sh /usr/local/sbin/mesh-down.sh /usr/local/sbin/mesh-uplink.sh \
        /usr/local/sbin/mesh-role.sh /usr/local/sbin/mesh-hosts.sh /usr/local/sbin/mesh-config \
        /etc/systemd/system/mesh.service /etc/systemd/system/mesh-uplink@.service \
        /etc/systemd/system/mesh-role-check.service /etc/systemd/system/mesh-role-check.timer \
        /etc/systemd/system/mesh-hosts.service /etc/systemd/system/mesh-hosts.timer \
        /etc/systemd/system/caddy.service.d/mesh.conf \
        /etc/NetworkManager/conf.d/99-mesh.conf /etc/NetworkManager/dispatcher.d/50-mesh-dns \
        /etc/udev/rules.d/90-mesh-uplink.rules /etc/avahi/services/groupmesh.service \
        /etc/tmpfiles.d/mesh.conf /etc/sysctl.d/90-mesh.conf /etc/modules-load.d/batman.conf \
        /etc/dnsmasq.d/mesh.conf /etc/nftables.d/meshgw.nft /etc/hosts.mesh /etc/default/mesh \
        /run/dnsmasq/upstream.conf
  rmdir /etc/systemd/system/caddy.service.d 2>/dev/null
  rm -rf /usr/local/lib/mesh /etc/mesh /run/mesh

  for f in $MESH_REPLACED; do
    if [ -e "$f.mesh-bak" ] || [ -L "$f.mesh-bak" ]; then
      rm -f "$f"; mv "$f.mesh-bak" "$f"; echo "Restored $f"
    elif grep -qx "new=$f" <<< "$state"; then
      rm -f "$f"
    elif [ "$f" = /etc/resolv.conf ]; then
      rm -f "$f"   # NetworkManager writes it again on reload
    elif [ -e "$f" ]; then
      echo "No backup of $f; left as it is"
    fi
  done
  [ -s /etc/hostname ] && hostnamectl set-hostname "$(cat /etc/hostname)"

  systemctl daemon-reload
  udevadm control --reload >/dev/null 2>&1
  nmcli general reload >/dev/null 2>&1 || systemctl reload NetworkManager >/dev/null 2>&1
  sysctl -q --system >/dev/null 2>&1
  if [ -n "$state" ]; then
    for u in $MESH_UNITS; do
      case $(sed -n "s/^$u=//p" <<< "$state") in
        enabled)  systemctl enable "$u" >/dev/null 2>&1; systemctl restart "$u" 2>/dev/null ;;
        disabled|"") systemctl disable --now "$u" >/dev/null 2>&1 ;;   # "": not installed before
        masked)   systemctl stop "$u" 2>/dev/null; systemctl mask "$u" >/dev/null 2>&1 ;;
      esac
    done
    sysctl -qw "net.ipv4.ip_forward=$(sed -n 's/^ip_forward=//p' <<< "$state")" >/dev/null 2>&1
    sysctl -qw "net.ipv4.conf.all.rp_filter=$(sed -n 's/^rp_filter=//p' <<< "$state")" >/dev/null 2>&1
  else
    echo "Service states from before the install are unknown; dnsmasq, avahi-daemon and caddy left as they are"
  fi

  echo
  echo "mesh-config is uninstalled. Kept:"
  echo "  packages: batctl hostapd dnsmasq avahi-daemon avahi-utils nftables iw bridge-utils caddy whiptail"
  echo "  users created for node ids, their /home/<id>/public folders, /var/www/mesh and $CONF"
)

# USB gadget (dwc2 + g_ether) in the boot files, per usb_gadget.
apply_usb_gadget() {
  local cfg=/boot/firmware/config.txt cmd=/boot/firmware/cmdline.txt
  [ -f "$cfg" ] || { cfg=/boot/config.txt; cmd=/boot/cmdline.txt; }
  [ -f "$cfg" ] && [ -f "$cmd" ] || { msg "config.txt or cmdline.txt not found"; return 1; }
  if [ "$(cfg_get usb_gadget)" = yes ]; then
    grep -q '^dtoverlay=dwc2' "$cfg" || echo 'dtoverlay=dwc2' >> "$cfg"
    grep -q 'modules-load=dwc2,g_ether' "$cmd" || sed -i 's/$/ modules-load=dwc2,g_ether/' "$cmd"
  else
    sed -i '/^dtoverlay=dwc2$/d' "$cfg"
    sed -i 's/ modules-load=dwc2,g_ether//' "$cmd"
  fi
}

# ------------------------------------------------------------------ menus ----

# 1 Identity: node ID, group, display name, Linux user.
menu_identity() {
  local id group display rc
  id=$(ask "Enter the node ID (letters and digits)" "$(cfg_get id)") || return
  id=$(echo "$id" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')
  [ -n "$id" ] || { msg "ID must not be empty"; return; }
  group=$(ask "Enter the group name (same on all nodes)" "$(cfg_get group)") || return
  group=$(echo "$group" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')
  [ -n "$group" ] || group=group
  [ "$id" != "$group" ] || { msg "ID and group name must differ"; return; }
  display=$(ask "Enter a display name (optional)" "$(cfg_get display)") || return
  cfg_set id "$id"; cfg_set group "$group"; cfg_set display "$display"
  if id -u "$id" >/dev/null 2>&1; then
    msg "User $id exists. Web folder: /home/$id/public"
  elif yesno "Create user $id?"; then
    clear
    if useradd -m -s /bin/bash "$id"; then
      install -d -o "$id" -g "$id" -m 755 "/home/$id/public"; chmod 711 "/home/$id"
      passwd "$id" || echo "passwd failed"
    else
      echo "useradd failed"
    fi
    read -rp "Press Enter to continue"
  fi
  if ! installed; then
    yesno "System files are not installed. Install now?" || return
    clear; write_system_files; rc=$?
    [ $rc -eq 0 ] || echo "Install failed (exit $rc)"
    read -rp "Press Enter to continue"
  fi
}

# Stop the mesh. After a failed start the unit is inactive and "systemctl stop"
# does nothing, so mesh-down.sh runs directly in that case.
mesh_off() {
  local was_active=0
  mesh_active && was_active=1
  run_checked systemctl stop mesh.service || true
  systemctl reset-failed mesh.service 2>/dev/null
  [ "$was_active" = 1 ] || run_checked /usr/local/sbin/mesh-down.sh || true
}

# Report the mesh state after a start or stop, with any warnings.
report_mesh_state() {
  local f
  if mesh_active; then
    if [ -s "$WARN_FILE" ]; then
      f=$(mktemp)
      {
        echo "Mesh is on. Node address $(sed -n 's/^MYIP=//p' /etc/default/mesh 2>/dev/null) ($(sed -n 's/^MESH_IF=//p' /etc/default/mesh 2>/dev/null))"; echo
        echo "Warnings:"; sed 's/^/  /' "$WARN_FILE"
      } > "$f"
      show_text "warnings" "$f"; rm -f "$f"
    else
      msg "Mesh is on. Node address $(sed -n 's/^MYIP=//p' /etc/default/mesh 2>/dev/null) ($(sed -n 's/^MESH_IF=//p' /etc/default/mesh 2>/dev/null))"
    fi
  else
    msg "Mesh is off"
  fi
}

# Re-apply the uplink role while the mesh keeps running.
apply_uplink_now() {
  local cur
  cur=$(cat /run/mesh/uplink 2>/dev/null)
  if [ -n "$cur" ]; then
    run_checked systemctl restart "mesh-uplink@$cur.service" || true
  fi
  /usr/local/sbin/mesh-uplink.sh - check 2>/dev/null
  sleep 1
  cur=$(cat /run/mesh/uplink 2>/dev/null)
  if [ -n "$cur" ]; then
    msg "Uplink role applied on $cur"
  else
    msg "No uplink radio attached"
  fi
}

# 2 Mesh: start, stop, restart, enable or disable at boot.
menu_mesh_status() {
  local now boot choice
  mesh_active && now="on" || now="off"
  mesh_enabled && boot="enabled" || boot="disabled"
  choice=$(whiptail --title "$TITLE" --menu "Mesh: $now   At boot: $boot" 16 60 5 \
      "1 Start"   "Start the mesh" \
      "2 Stop"    "Stop the mesh" \
      "3 Restart" "Restart the mesh" \
      "4 Enable"  "Start the mesh at boot" \
      "5 Disable" "Do not start the mesh at boot" \
      3>&1 1>&2 2>&3) || return
  choice=${choice%% *}
  installed || { msg "System files are not installed (6 Install)"; return; }
  case $choice in 1|3) [ -n "$(cfg_get id)" ] || { msg "Node ID is not set (1 Identity)"; return; } ;; esac
  clear
  case $choice in
    1) run_checked systemctl start mesh.service ;;
    2) mesh_off ;;
    3) run_checked systemctl restart mesh.service ;;
    4) run_checked systemctl enable mesh.service && msg "Mesh enabled at boot"; return ;;
    5) run_checked systemctl disable mesh.service && msg "Mesh disabled at boot"; return ;;
  esac
  sleep 1
  report_mesh_state
}

# Select a NetworkManager connection for the external network.
choose_nm_profile() {
  local cur items=() name type dev
  cur=$(cfg_get uplink_profile)
  items+=("auto" "NetworkManager autoconnect" "$([ "$cur" = auto ] && echo ON || echo OFF)")
  while IFS=: read -r name type dev; do
    [ -n "$name" ] && [ "$type" != loopback ] || continue
    case $type in 802-11-wireless) type=wifi ;; 802-3-ethernet) type=ethernet ;; esac
    items+=("$name" "${type}${dev:+ (on $dev)}" "$([ "$cur" = "$name" ] && echo ON || echo OFF)")
  done < <(nmcli -t -f NAME,TYPE,DEVICE connection show 2>/dev/null)
  whiptail --title "$TITLE" --radiolist "Select the NetworkManager connection for the external network" 20 72 10 \
      "${items[@]}" 3>&1 1>&2 2>&3
}

# 3 Uplink: uplink interface and role (external network, access point, off).
menu_uplink() {
  local ifname role profile psk ssid chan cur_ssid
  ifname=$(ask "Enter the uplink interface (auto or a name). Present: $(wifi_ifaces)" "$(cfg_get uplink_if)") || return
  [[ $ifname =~ ^(auto|[A-Za-z0-9_.-]{1,15})$ ]] || { msg "Invalid interface name"; return; }
  role=$(whiptail --title "$TITLE" --radiolist "Select the uplink role" 14 60 3 \
      "external" "External network via NetworkManager (gateway)" "$([ "$(cfg_get uplink)" = external ] && echo ON || echo OFF)" \
      "ap"       "Access point"                                  "$([ "$(cfg_get uplink)" = ap ] && echo ON || echo OFF)" \
      "off"      "Unused"                                        "$([ "$(cfg_get uplink)" = off ] && echo ON || echo OFF)" \
      3>&1 1>&2 2>&3) || return
  # mesh.conf is written only once all answers are in
  case $role in
    external)
      profile=$(choose_nm_profile) || return
      cfg_set uplink_if "$ifname"; cfg_set uplink external; cfg_set uplink_profile "$profile"
      msg "Uplink: external network, connection '$profile'"
      ;;
    ap)
      cur_ssid=$(ap_ssid_name)
      ssid=$(ask "Enter the access point SSID (same on all nodes)" "$cur_ssid") || return
      [ -n "$ssid" ] && [ ${#ssid} -le 32 ] && [[ $ssid != *\"* ]] || { msg "SSID must be 1 to 32 characters without double quotes"; return; }
      psk=$(ask "Enter the access point passphrase (8 to 63 characters)" "$(ap_psk_value)") || return
      [ ${#psk} -ge 8 ] && [ ${#psk} -le 63 ] || { msg "Passphrase must be 8 to 63 characters"; return; }
      chan=$(whiptail --title "$TITLE" --radiolist "Select the access point channel" 14 60 5 \
          "auto" "36/40/44/48 by node ID" "$([ "$(cfg_get ap_channel)" = auto ] && echo ON || echo OFF)" \
          "36"   "5180 MHz" "$([ "$(cfg_get ap_channel)" = 36 ] && echo ON || echo OFF)" \
          "40"   "5200 MHz" "$([ "$(cfg_get ap_channel)" = 40 ] && echo ON || echo OFF)" \
          "44"   "5220 MHz" "$([ "$(cfg_get ap_channel)" = 44 ] && echo ON || echo OFF)" \
          "48"   "5240 MHz" "$([ "$(cfg_get ap_channel)" = 48 ] && echo ON || echo OFF)" \
          3>&1 1>&2 2>&3) || return
      cfg_set uplink_if "$ifname"; cfg_set uplink ap; cfg_set ap_channel "$chan"
      cfg_set_or_follow ap_ssid "$ssid" "$(group_name)-mesh"
      cfg_set_or_follow ap_psk "$psk" "$(group_name).mesh"
      msg "Uplink: access point '$ssid', channel $chan"
      ;;
    off) cfg_set uplink_if "$ifname"; cfg_set uplink off ;;
  esac
  if mesh_active; then
    yesno "Apply the uplink role now?" && { clear; apply_uplink_now; }
  elif [ "$role" != off ] && [ -z "$(uplink_candidates)" ]; then
    msg "No uplink radio attached. Setting saved"
  fi
  return 0
}

# 4 Radio: mesh interface, ad-hoc network name, channel, address block.
menu_radio() {
  local mif mid ch pfx
  mif=$(ask "Enter the mesh interface (auto or a name). Present: $(wifi_ifaces)" "$(cfg_get mesh_if)") || return
  [[ $mif =~ ^(auto|[A-Za-z0-9_.-]{1,15})$ ]] || { msg "Invalid interface name"; return; }
  mid=$(ask "Enter the ad-hoc network name (same on all nodes)" "$(mesh_name)") || return
  [ -n "$mid" ] && [ ${#mid} -le 32 ] && [[ $mid != *\"* ]] || { msg "Name must be 1 to 32 characters without double quotes"; return; }
  ch=$(whiptail --title "$TITLE" --radiolist "Select the mesh channel (same on all nodes)" 12 60 3 \
      "1" "2412 MHz" "$([ "$(cfg_get mesh_channel)" = 1 ] && echo ON || echo OFF)" \
      "6" "2437 MHz" "$([ "$(cfg_get mesh_channel)" = 6 ] && echo ON || echo OFF)" \
      "11" "2462 MHz" "$([ "$(cfg_get mesh_channel)" = 11 ] && echo ON || echo OFF)" \
      3>&1 1>&2 2>&3) || return
  pfx=$(ask "Enter the first octet of the mesh address block (10 = 10.X.Y.1/8)" "$(cfg_get mesh_prefix)") || return
  [[ $pfx =~ ^[0-9]+$ ]] && [ "$pfx" -ge 1 ] && [ "$pfx" -le 223 ] || { msg "Octet must be 1 to 223"; return; }
  cfg_set mesh_if "$mif"; cfg_set mesh_channel "$ch"; cfg_set mesh_prefix "$pfx"
  cfg_set_or_follow mesh_id "$mid" "$(group_name).mesh"
  msg "Mesh radio settings saved. The ad-hoc network is open (no encryption)"
  mesh_active && yesno "Restart the mesh now?" && { clear; run_checked systemctl restart mesh.service && report_mesh_state; }
  return 0
}

# 5 Ports: wired mesh ports (Ethernet bridge, USB gadget).
menu_ports() {
  local sel
  sel=$(whiptail --title "$TITLE" --checklist "Select wired mesh ports. Keep DHCP on for a cable to one PC; never bridge eth0 into a shared network" 14 72 3 \
      "eth0" "Ethernet port"               "$([ "$(cfg_get bridge_eth0)" = yes ] && echo ON || echo OFF)" \
      "dhcp" "Addresses for devices on eth0" "$([ "$(cfg_get eth0_dhcp)" != no ] && echo ON || echo OFF)" \
      "usb"  "USB gadget (needs reboot)"   "$([ "$(cfg_get usb_gadget)" = yes ] && echo ON || echo OFF)" \
      3>&1 1>&2 2>&3) || return
  # whiptail returns the quoted tags: "eth0" "dhcp"
  [[ $sel == *'"eth0"'* ]] && cfg_set bridge_eth0 yes || cfg_set bridge_eth0 no
  [[ $sel == *'"dhcp"'* ]] && cfg_set eth0_dhcp yes   || cfg_set eth0_dhcp no
  [[ $sel == *'"usb"'* ]]  && cfg_set usb_gadget yes  || cfg_set usb_gadget no
  apply_usb_gadget || return
  msg "Port settings saved"
  mesh_active && yesno "Restart the mesh now?" && { clear; run_checked systemctl restart mesh.service && report_mesh_state; }
  return 0
}

# 6 Install: write or refresh the system files, or remove them.
menu_install() {
  local rc choice
  choice=$(whiptail --title "$TITLE" --menu "System files" 12 64 2 \
      "1 Install"   "Install or refresh system files and packages" \
      "2 Uninstall" "Remove system files, restore the originals" \
      3>&1 1>&2 2>&3) || return
  case ${choice%% *} in
    1) yesno "Install system files and packages?" || return
       clear; write_system_files; rc=$?
       [ $rc -eq 0 ] || echo "Install failed (exit $rc)" ;;
    2) yesno "Stop the mesh and remove all its system files? Packages, users and their folders stay." || return
       clear; uninstall_mesh ;;
  esac
  read -rp "Press Enter to continue"
}

# 7 Wi-Fi: join a Wi-Fi network through NetworkManager (stops the mesh).
menu_wifi() {
  local list ssid pw
  if mesh_active; then
    yesno "The mesh is on. Stop it?" || return
    clear; mesh_off; sleep 2
  fi
  clear; echo "Scanning..."; nmcli device wifi rescan 2>/dev/null; sleep 3
  list=$(nmcli -t -f SSID,SIGNAL device wifi list 2>/dev/null | awk -F: '$1!="" && !seen[$1]++ {print $1"\t"$2"%"}' | sort -t$'\t' -k2 -rn | head -20)
  [ -n "$list" ] || { msg "No networks found"; return; }
  local -a items=()
  while IFS=$'\t' read -r s sig; do items+=("$s" "$sig"); done <<< "$list"
  ssid=$(whiptail --title "$TITLE" --menu "Select a network" 22 70 12 "${items[@]}" 3>&1 1>&2 2>&3) || return
  pw=$(pass "Enter the password for $ssid") || return
  clear
  if [ -n "$pw" ]; then nmcli device wifi connect "$ssid" password "$pw"; else nmcli device wifi connect "$ssid"; fi \
    || echo "Connection to $ssid failed"
  read -rp "Press Enter to continue"
}

# 8 Status.
show_status() {
  local f mif uif gw; f=$(mktemp)
  mif=$(sed -n 's/^MESH_IF=//p' /etc/default/mesh 2>/dev/null); uif=$(cat /run/mesh/uplink 2>/dev/null); gw=$(cat /run/mesh/gateway 2>/dev/null)
  {
    echo "mesh.conf: $CONF"; echo "----"; sed 's/^\(ap_psk\|mesh_psk\)=.*/\1=(hidden)/' "$CONF" 2>/dev/null
    echo "Derived: group=$(group_name) mesh=$(mesh_name) ap=$(ap_ssid_name)"
    echo; echo "mesh.service: $(systemctl is-active mesh.service) (boot: $(systemctl is-enabled mesh.service 2>/dev/null))"
    echo "dnsmasq: $(systemctl is-active dnsmasq)  avahi: $(systemctl is-active avahi-daemon)  caddy: $(systemctl is-active caddy 2>/dev/null)  hostapd: $(systemctl is-active hostapd)"
    echo; echo "Wi-Fi interfaces: $(wifi_ifaces)"
    echo "Mesh radio: ${mif:-none}  $(iw dev "${mif:-none}" link 2>/dev/null | head -1)"
    echo "Uplink radio: ${uif:-none} (uplink_if=$(cfg_get uplink_if) role=$(cfg_get uplink) profile=$(cfg_get uplink_profile)) mesh-uplink@${uif:-?}: $(systemctl is-active "mesh-uplink@${uif:-none}" 2>/dev/null)"
    [ "$(systemctl is-active hostapd 2>/dev/null)" = active ] && echo "Access point: '$(sed -n 's/^ssid=//p' /etc/hostapd/hostapd.conf 2>/dev/null)' channel $(sed -n 's/^channel=//p' /etc/hostapd/hostapd.conf 2>/dev/null), clients: $(iw dev "${uif:-none}" station dump 2>/dev/null | grep -c '^Station') of 8"
    echo "eth0: bridged=$(cfg_get bridge_eth0) dhcp=$(cfg_get eth0_dhcp)$(nft list table bridge meshdhcp >/dev/null 2>&1 && echo ' (DHCP blocked at eth0)')"
    if [ -n "$gw" ]; then echo "Gateway: on via $gw ($(nmcli -g GENERAL.CONNECTION device show "$gw" 2>/dev/null))"; else echo "Gateway: off"; fi
    echo; echo "Interfaces (NetworkManager view):"; nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null | grep -v '^lo:'
    echo; echo "Addresses:"; ip -4 -br addr 2>/dev/null
    echo; echo "Default routes:"; ip route show default 2>/dev/null
    echo; echo "Gateway mode: $(batctl gw_mode 2>/dev/null)"
    echo; echo "Mesh neighbours (batctl o):"; batctl o 2>/dev/null | tail -n +2 | head -20
    echo; echo "Gateways (batctl gwl):"; batctl gwl 2>/dev/null
    echo; echo "Names (/etc/hosts.mesh):"; cat /etc/hosts.mesh 2>/dev/null
    echo; echo "Upstream DNS:"; cat /run/dnsmasq/upstream.conf 2>/dev/null
    if [ -s "$WARN_FILE" ]; then echo; echo "Warnings:"; sed 's/^/  /' "$WARN_FILE"; fi
    echo; echo "Log:"; journalctl -u mesh.service -u 'mesh-uplink@*' -u mesh-role-check.service -n 15 --no-pager 2>/dev/null
  } > "$f"
  show_text "status" "$f"
  rm -f "$f"
}

# Main menu.
main_menu() {
  INTERACTIVE=1
  ensure_whiptail
  set_defaults
  while true; do
    local id state choice
    id=$(cfg_get id)
    mesh_active && state="on" || state="off"
    choice=$(whiptail --title "$TITLE" --menu "Node: ${id:-unset}   Group: $(group_name)   Mesh: $state   Uplink: $(cfg_get uplink)" 20 70 9 \
      "1 Identity" "Node ID, group, user" \
      "2 Mesh"     "Start, stop, enable at boot" \
      "3 Uplink"   "External network, access point or off" \
      "4 Radio"    "Ad-hoc name, channel, addresses" \
      "5 Ports"    "Ethernet bridge, USB gadget" \
      "6 Install"  "Install, refresh or remove system files" \
      "7 Wi-Fi"    "Join a Wi-Fi network (stops the mesh)" \
      "8 Status"   "Show status" \
      "9 Finish"   "Exit" \
      3>&1 1>&2 2>&3) || break
    case ${choice%% *} in
      1) menu_identity ;;
      2) menu_mesh_status ;;
      3) menu_uplink ;;
      4) menu_radio ;;
      5) menu_ports ;;
      6) menu_install ;;
      7) menu_wifi ;;
      8) show_status ;;
      9) break ;;
    esac
  done
  clear
}

# Entry point.
case "${1:-}" in
  install) set_defaults; write_system_files; exit $? ;;
  status)  show_status ;;
  uninstall) uninstall_mesh; exit $? ;;
  *)       main_menu ;;
esac
