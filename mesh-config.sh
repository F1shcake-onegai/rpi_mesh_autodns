#!/bin/bash
# mesh-config: raspi-config style tool for the classroom Pi mesh.
#
#   sudo ./mesh-config.sh            interactive menu
#   sudo ./mesh-config.sh install    write all system files non-interactively
#   sudo ./mesh-config.sh status     print status and exit
#
# Design (after meshunderground.com's Raspberry Pi mesh guide):
#   - The Pi's built-in radio runs an open ad-hoc (IBSS) cell with batman-adv on
#     top. Every Pi joins and leaves whenever it likes; batman-adv re-routes.
#   - An ESP32-C5 (ESP-Hosted) is the uplink radio. Per node it either stays
#     with NetworkManager and connects to an external network through one of
#     the user's own saved profiles (eduroam, a home Wi-Fi, PPPoE, anything), or
#     it broadcasts the shared group access point (one SSID on every AP node, so
#     laptops roam between Pis). The script never configures external networks.
#   - Any node that currently has a working internet route outside the mesh
#     becomes a gateway for the others, and stops being one the moment it drops.
#   - Every node's web folder is reachable through any node (Caddy proxies).
#   - The uplink radio can be plugged or unplugged at any time: udev starts its
#     role when it appears and systemd stops it when it disappears.
#
# Everything the node needs lives in /boot/firmware/mesh.conf. This tool edits
# that file, writes the system files that read it, and starts or stops the mesh.
# It is safe to run again at any time; every write is idempotent.
#
# Failure handling: mesh-up.sh checks everything it can before touching a radio,
# and if it still fails half way systemd runs mesh-down.sh (ExecStopPost), so
# the built-in radio always goes back to NetworkManager. Every error this tool
# hits is shown in a scrollable box together with the mesh journal instead of
# being wiped by the next menu.
#
# mesh.conf keys (the menu writes them; an empty value means "derived from the group"):
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
#
# Files written by install (menu 6):
#   /usr/local/sbin/mesh-{up,down,uplink,role,hosts}.sh and /usr/local/lib/mesh/common.sh
#   /etc/systemd/system/mesh.service, mesh-uplink@.service, mesh-role-check.{service,timer},
#     mesh-hosts.{service,timer}, caddy.service.d/mesh.conf
#   /etc/mesh/*.tpl (dnsmasq, hostapd and nftables templates), /etc/caddy/Caddyfile
#   /etc/NetworkManager/conf.d/99-mesh.conf, /etc/NetworkManager/dispatcher.d/50-mesh-dns
#   /etc/udev/rules.d/90-mesh-uplink.rules, /etc/avahi/avahi-daemon.conf, /etc/avahi/services/groupmesh.service
#   /etc/tmpfiles.d/mesh.conf, /etc/sysctl.d/90-mesh.conf, /etc/modules-load.d/batman.conf
#   /etc/resolv.conf (points at the local dnsmasq; NetworkManager is told not to touch it)
# Runtime state: /etc/default/mesh (ID, MYIP, GROUP, MESH_IF, MESH_BSSID), /run/mesh/{up,uplink,gateway,warnings},
#   /run/dnsmasq/upstream.conf (where dnsmasq forwards to right now), /etc/hosts.mesh (names found via mDNS).

set -u
CONF=/boot/firmware/mesh.conf
[ -d /boot/firmware ] || CONF=/boot/mesh.conf
SELF=$(readlink -f "$0")
TITLE="Mesh configuration"
WARN_FILE=/run/mesh/warnings      # written by the mesh scripts, shown after a start
INTERACTIVE=0                     # 1 while the whiptail menu is running

[ "$EUID" -eq 0 ] || exec sudo -E "$SELF" "$@"

# ---------------------------------------------------------------- helpers ----

# Fatal error: always on stderr, also as a dialog while the menu is up.
die() {
  echo "mesh-config: ERROR: $*" >&2
  [ "$INTERACTIVE" = 1 ] && command -v whiptail >/dev/null 2>&1 && whiptail --title "$TITLE: error" --msgbox "$*" 12 70
  exit 1
}

# mesh.conf is one key='value' per line and is also sourced by the mesh scripts,
# so values are stored single-quoted with embedded quotes escaped: nothing a user
# types can be expanded by the shell, and sed never sees the value itself.
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
  { [ -f "$CONF" ] || : > "$CONF"; } 2>/dev/null || die "Cannot create $CONF. Is $(dirname "$CONF") mounted read-write?"
  [ -w "$CONF" ] || die "Cannot write $CONF."
  if grep -q "^$key=" "$CONF"; then
    sed -i "/^$key=/d" "$CONF" || die "Cannot update $CONF."
  fi
  printf "%s='%s'\n" "$key" "$val" >> "$CONF" || die "Cannot update $CONF."
}
# Set a key only when it has no value yet.
cfg_default() { [ -n "$(cfg_get "$1")" ] || cfg_set "$1" "$2"; }
# Store a value, or an empty string when it equals the derived default, so the
# setting keeps following the group name when the group is renamed later.
cfg_set_or_follow() { if [ "$2" = "$3" ]; then cfg_set "$1" ""; else cfg_set "$1" "$2"; fi; }

# Names derived from the group when not set explicitly:
#   group_name   the group ("group" if unset)      mesh_name     ad-hoc network name, <group>.mesh
#   ap_ssid_name access point SSID, <group>-mesh   ap_psk_value  access point passphrase, <group>.mesh
group_name()   { local g; g=$(cfg_get group); echo "${g:-group}"; }
mesh_name()    { local v; v=$(cfg_get mesh_id); echo "${v:-$(group_name).mesh}"; }
ap_ssid_name() { local v; v=$(cfg_get ap_ssid); echo "${v:-$(group_name)-mesh}"; }
ap_psk_value() { local v; v=$(cfg_get ap_psk);  echo "${v:-$(group_name).mesh}"; }

# The menu needs whiptail: install it if missing, otherwise stop with a clear message.
ensure_whiptail() {
  command -v whiptail >/dev/null 2>&1 && return 0
  DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail >/dev/null 2>&1
  command -v whiptail >/dev/null 2>&1 || die "whiptail is missing and could not be installed (offline?). Run: sudo apt-get install whiptail"
}
# Dialog wrappers: message box, text input (with default), password input, yes/no question.
msg()  { whiptail --title "$TITLE" --msgbox "$1" 12 70; }
ask()  { whiptail --title "$TITLE" --inputbox "$1" 11 72 "${2:-}" 3>&1 1>&2 2>&3; }
pass() { whiptail --title "$TITLE" --passwordbox "$1" 10 70 3>&1 1>&2 2>&3; }
yesno(){ whiptail --title "$TITLE" --yesno "$1" 10 70; }

# Show a text file: a scrollable dialog in the menu, plain output otherwise.
show_text() { if [ "$INTERACTIVE" = 1 ]; then whiptail --title "$TITLE: $1" --scrolltext --textbox "$2" 30 100; else cat "$2"; fi; }

# Run a command and keep its output. On failure, show that output together with
# the recent mesh journal in a scrollable box, so the error is never wiped off
# the screen by the next menu.
run_checked() {
  local out rc
  out=$(mktemp)
  "$@" >"$out" 2>&1; rc=$?
  if [ $rc -ne 0 ]; then
    {
      echo "FAILED (exit $rc): $*"; echo
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

# Wi-Fi interfaces present right now, with their drivers (for menu texts), and
# the ones that could carry the uplink role (anything but the built-in brcmfmac).
wifi_ifaces() {
  local d
  for d in /sys/class/net/*; do
    [ -e "$d/phy80211" ] || continue
    printf '%s(%s) ' "$(basename "$d")" "$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)")"
  done
}
# Interfaces that could carry the uplink role: every Wi-Fi interface except the built-in radio.
uplink_candidates() {
  local d
  for d in /sys/class/net/*; do
    [ -e "$d/phy80211" ] || continue
    [ "$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)")" = brcmfmac ] || basename "$d"
  done
}

# Are the system files in place? Is the mesh running right now? Does it start at boot?
installed() { [ -x /usr/local/sbin/mesh-up.sh ] && [ -f /etc/systemd/system/mesh.service ] && [ -f /usr/local/lib/mesh/common.sh ] && [ -x /usr/local/sbin/mesh-uplink.sh ]; }
mesh_active() { systemctl is-active --quiet mesh.service; }
mesh_enabled() { systemctl is-enabled --quiet mesh.service 2>/dev/null; }

# Fill mesh.conf with defaults for anything unset, after migrating keys from earlier layouts.
set_defaults() {
  # One-time carry-over from earlier layouts of mesh.conf.
  if [ -z "$(cfg_get group)" ] && [ -n "$(cfg_get course)" ]; then cfg_set group "$(cfg_get course)"; fi
  [ "$(cfg_get mesh_id)" = watiam-mesh ] && cfg_set mesh_id ""      # now follows the group: <group>.mesh
  [ "$(cfg_get ap_psk)" = watiam-mesh ]  && cfg_set ap_psk ""       # now follows the group: <group>.mesh
  [ "$(cfg_get uplink)" = eduroam ]      && cfg_set uplink external # external networks are NetworkManager's job now
  cfg_default group      group
  cfg_default mesh_if    auto
  cfg_default uplink_if  auto
  cfg_default uplink     ap
  cfg_default uplink_profile auto
  cfg_default ap_channel auto
  cfg_default mesh_channel 6
  cfg_default mesh_prefix 10
  cfg_default bridge_eth0 no
  cfg_default usb_gadget no
}

# ------------------------------------------------------------ system files ----

write_system_files() (
  # Runs in a subshell with "exit on error": any failed write stops the install
  # and names the failing line instead of silently carrying on. Call it plainly
  # and check $? afterwards; "write_system_files || ..." would switch set -e off.
  set -eE
  trap 'echo "mesh-config: install FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
  trap 'systemctl unmask hostapd >/dev/null 2>&1 || true' EXIT
  fail() { echo "mesh-config: ERROR: $*" >&2; exit 1; }

  systemctl is-active --quiet NetworkManager \
    || fail "NetworkManager is not running. This tool needs it to own the radios while the mesh is off and to reach external networks (Raspberry Pi OS Bookworm or newer)."
  [ -f "$CONF" ] || : > "$CONF" || fail "cannot create $CONF (is $(dirname "$CONF") mounted read-write?)"

  echo "Installing packages..."
  # Keep hostapd from starting with its stock config the moment it is installed;
  # the mesh scripts start it with our config when needed.
  systemctl mask hostapd >/dev/null 2>&1 || true
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y batctl hostapd dnsmasq avahi-daemon avahi-utils \
         nftables curl iw bridge-utils whiptail >/dev/null; then
    echo "WARNING: apt-get install failed (offline?). Checking what is already installed..." >&2
    missing=""
    for b in batctl hostapd dnsmasq avahi-daemon nft iw; do
      command -v "$b" >/dev/null 2>&1 || missing="$missing $b"
    done
    [ -z "$missing" ] || fail "required programs are missing:$missing. Connect to the internet and retry."
  fi
  if ! command -v caddy >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y caddy >/dev/null 2>&1 || echo "WARNING: caddy not in apt; install it from caddyserver.com" >&2
  fi
  systemctl unmask hostapd >/dev/null 2>&1 || true

  install -d /etc/mesh /usr/local/lib/mesh /etc/nftables.d /etc/dnsmasq.d /etc/avahi/services /etc/hostapd \
             /etc/systemd/system/caddy.service.d /etc/NetworkManager/conf.d /etc/NetworkManager/dispatcher.d \
             /etc/udev/rules.d /etc/tmpfiles.d /var/www/mesh /usr/local/sbin /run/mesh /run/dnsmasq
  # Leftovers from earlier layouts (the template in dnsmasq.d made dnsmasq refuse to start;
  # eduroam/dhcpcd handling moved to NetworkManager).
  rm -f /etc/dnsmasq.d/mesh.conf.tpl /etc/hostapd/hostapd.conf.tpl /etc/wpa_supplicant/wpa_supplicant-wlan1.conf.tpl \
        /etc/wpa_supplicant/wpa_supplicant-wlan0.conf /etc/mesh/wpa_supplicant-uplink.conf.tpl /etc/mesh/dhcpcd.conf.tpl \
        /etc/systemd/system/mesh-role.service /etc/systemd/system/mesh-role@.service /etc/avahi/services/watiam.service

  # --- runtime directories must survive a reboot (/run is a tmpfs)
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

# render TEMPLATE DEST KEY=VALUE...  Literal replacement of @KEY@ tags; sed would
# trip over / & \ in passphrases.
render() {
  local tpl dest kv
  tpl=$(cat "$1") || return 1
  dest=$2; shift 2
  for kv in "$@"; do tpl=${tpl//"@${kv%%=*}@"/"${kv#*=}"}; done
  printf '%s\n' "$tpl" > "$dest"
}

# The Pi's built-in radio (brcmfmac), whatever name it got this boot. Names are
# not stable once a second radio is attached: whichever driver probes first is wlan0.
detect_mesh_if() {
  local d
  for d in /sys/class/net/*; do
    [ -e "$d/phy80211" ] || continue
    [ "$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)")" = brcmfmac ] && { basename "$d"; return 0; }
  done
  [ -e /sys/class/net/wlan0 ] && { echo wlan0; return 0; }
  return 1
}
# First Wi-Fi interface that is not the mesh radio ($1): the ESP32-C5, usually wlan1.
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

# Interface carrying the system default route, unless it belongs to the mesh.
# Whatever NetworkManager connected (ESP32 radio, Ethernet, PPPoE, ...) shows up here.
external_dev() {
  local mif; mif=$(sed -n 's/^MESH_IF=//p' /etc/default/mesh 2>/dev/null)
  ip -4 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}' \
    | grep -vx -e br0 -e bat0 -e lo -e "${mif:-none}" | head -1
}
EOF

  # --- NetworkManager dispatcher: while the mesh is off, dnsmasq forwards to the
  #     DNS servers NetworkManager currently has; while it is on, every network
  #     change re-evaluates the gateway role right away.
  cat > /etc/NetworkManager/dispatcher.d/50-mesh-dns <<'EOF'
#!/bin/bash
# Called by NetworkManager as "50-mesh-dns IFACE ACTION" and by the mesh scripts
# as "50-mesh-dns any refresh".
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
# nmcli -g joins several servers as "a | b"; strip the separators and spaces.
nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: '$2=="connected"{print $1}' \
  | while read -r dev; do nmcli -g IP4.DNS device show "$dev" 2>/dev/null; done \
  | tr '|' '\n' | sed 's/[[:space:]]//g; /^$/d; s/^/server=/' | awk '!seen[$0]++' > /run/dnsmasq/upstream.conf.new
mv -f /run/dnsmasq/upstream.conf.new /run/dnsmasq/upstream.conf
if pkill -HUP -x dnsmasq 2>/dev/null; then
  # dnsmasq is running: the resolver must point at it (undo any earlier fallback)
  grep -qx 'nameserver 127.0.0.1' /etc/resolv.conf 2>/dev/null \
    || { rm -f /etc/resolv.conf; printf 'nameserver 127.0.0.1\nsearch mesh\n' > /etc/resolv.conf; }
else
  # dnsmasq is NOT running: without this the whole machine would have no DNS.
  # Point the resolver at NetworkManager's servers directly until dnsmasq is back.
  sed 's/^server=/nameserver /' /run/dnsmasq/upstream.conf > /etc/resolv.conf.new
  if [ -s /etc/resolv.conf.new ]; then
    rm -f /etc/resolv.conf; mv -f /etc/resolv.conf.new /etc/resolv.conf
    logger -t mesh-dns -p user.err "dnsmasq is not running; /etc/resolv.conf points at NetworkManager's DNS servers directly (systemctl status dnsmasq)"
  else
    rm -f /etc/resolv.conf.new
  fi
fi
exit 0
EOF
  chmod 755 /etc/NetworkManager/dispatcher.d/50-mesh-dns

  # --- udev: hot plug of the uplink radio. mesh-uplink@.service is a no-op while
  #     the mesh is off; the built-in radio (brcmfmac) is excluded.
  cat > /etc/udev/rules.d/90-mesh-uplink.rules <<'EOF'
# Written by mesh-config: start the uplink role when a Wi-Fi interface appears.
SUBSYSTEM=="net", ACTION=="add", ENV{DEVTYPE}=="wlan", DRIVERS!="brcmfmac", TAG+="systemd", ENV{SYSTEMD_WANTS}+="mesh-uplink@$name.service"
EOF
  udevadm control --reload >/dev/null 2>&1 || true

  # --- sysctl, modules
  printf 'net.ipv4.ip_forward = 1\nnet.ipv4.conf.all.rp_filter = 0\n' > /etc/sysctl.d/90-mesh.conf
  echo batman-adv > /etc/modules-load.d/batman.conf

  # --- templates, rendered by the mesh scripts (@TAG@ replaced). They must NOT
  #     live in /etc/dnsmasq.d or similar directories that daemons read whole.
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
  # A harmless placeholder so dnsmasq can start before the first mesh-up
  [ -f /etc/dnsmasq.d/mesh.conf ] || printf 'no-resolv\nservers-file=/run/dnsmasq/upstream.conf\n' > /etc/dnsmasq.d/mesh.conf

  cat > /etc/mesh/hostapd.conf.tpl <<'EOF'
interface=@UPLINK_IF@
bridge=br0
driver=nl80211
# Shared by every AP node in the group, so laptops roam between Pis.
ssid=@AP_SSID@
country_code=CA
ieee80211d=1
hw_mode=a
# Fixed per node: ESP-Hosted has no automatic channel selection. Non-DFS 5 GHz only.
channel=@AP_CHANNEL@
ieee80211n=1
# If hostapd refuses to start on the ESP32 (journalctl -u hostapd), try removing ieee80211ac=1.
ieee80211ac=1
wmm_enabled=1
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_passphrase=@AP_PSK@
rsn_pairwise=CCMP
EOF

  # --- firewall table used only while this node is a gateway (rendered with the
  #     interface that actually carries the internet route at that moment)
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

  # --- Caddy: every node serves its own folder and proxies /<id>/ to that node
  cat > /etc/caddy/Caddyfile <<'EOF'
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
EOF
  cat > /etc/systemd/system/caddy.service.d/mesh.conf <<'EOF'
[Unit]
# Started by mesh-up.sh and stopped with the mesh. PartOf (not Requires) so that
# enabling or starting caddy can never pull the mesh up by itself.
After=mesh.service
PartOf=mesh.service

[Service]
EnvironmentFile=/etc/default/mesh
EOF

  # --- scripts
  cat > /usr/local/sbin/mesh-up.sh <<'EOF'
#!/bin/bash
# Bring the mesh up. Runs as ExecStart of mesh.service.
# Any failure stops here with a clear line in the journal; systemd then runs
# mesh-down.sh (ExecStopPost), so the radio always goes back to NetworkManager.
set -eu
. /usr/local/lib/mesh/common.sh
install -d "$RUN"; : > "$WARN"; rm -f "$RUN/up" "$RUN/uplink" "$RUN/gateway"
# fail: log and abort (systemd then runs mesh-down.sh). warn: log, remember for the menu, carry on.
fail() { echo "mesh-up: ERROR: $*" >&2; logger -t mesh-up -p user.err "ERROR: $*"; exit 1; }
warn() { echo "mesh-up: WARNING: $*" >&2; logger -t mesh-up -p user.warning "WARNING: $*"; echo "$*" >> "$WARN"; }
trap 'rc=$?; echo "mesh-up: FAILED (exit $rc) at line $LINENO: $BASH_COMMAND" >&2; logger -t mesh-up -p user.err "FAILED at line $LINENO: $BASH_COMMAND"' ERR

[ -f "$CONF" ] || fail "$CONF not found. Run mesh-config first."
load_conf
ID=${id:-}; [ -n "$ID" ] || fail "id= is missing in $CONF (mesh-config menu 1)."
[[ $ID =~ ^[a-z0-9]+$ ]]    || fail "id='$ID' must be lowercase letters and digits only."
[[ $GROUP =~ ^[a-z0-9]+$ ]] || fail "group='$GROUP' must be lowercase letters and digits only."
PFX=${mesh_prefix:-10}
UPLINK=${uplink:-ap}
MESH_ID=${mesh_id:-$GROUP.mesh}
case "${mesh_channel:-6}" in 1) FREQ=2412;; 11) FREQ=2462;; *) FREQ=2437;; esac
# Same cell id on every Pi with the same mesh name, so the ad-hoc cells merge
# instead of splitting: a locally administered MAC derived from the name.
BSSID=02:$(printf %s "$MESH_ID" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*/\1:\2:\3:\4:\5/')

# 0. Pre-flight. Everything that can be known in advance is checked here, before
#    any interface is touched, so a doomed start never costs the connection.
MESH_IF=""
for _ in $(seq 30); do   # at boot the radio may still be probing
  MESH_IF=$(resolve_mesh_if || true)
  [ -n "$MESH_IF" ] && [ -e "/sys/class/net/$MESH_IF" ] && break
  sleep 0.5
done
[ -n "$MESH_IF" ] && [ -e "/sys/class/net/$MESH_IF" ] || fail "no mesh radio found (mesh_if=${mesh_if:-auto}). The mesh needs the Pi's built-in Wi-Fi."
command -v iw >/dev/null 2>&1 || fail "iw is not installed (mesh-config menu 6)."
modes=$(iw phy "$(cat "/sys/class/net/$MESH_IF/phy80211/name" 2>/dev/null)" info 2>/dev/null \
        | sed -n '/Supported interface modes:/,/^\t[^\t]/p' || true)
if [ -n "$modes" ] && ! echo "$modes" | grep -q '\* IBSS'; then
  fail "$MESH_IF does not support ad-hoc (IBSS) mode (this radio offers:$(echo "$modes" | sed -n 's/^.*\* / /p' | tr -d '\n')). The mesh cannot run on it."
fi
modprobe batman-adv || fail "kernel module batman-adv is missing (reboot after a kernel update?)."
command -v batctl >/dev/null 2>&1 || fail "batctl is not installed (mesh-config menu 6)."
[ -f "$TPL/dnsmasq.conf.tpl" ] || fail "$TPL/dnsmasq.conf.tpl is missing: run mesh-config menu 6 (install) again."
systemctl is-active --quiet NetworkManager || warn "NetworkManager is not running; the radio cannot be handed back to it when the mesh stops, and no external network can be reached."
[ -z "${mesh_psk:-}" ] || warn "mesh_psk is set but ignored: the ad-hoc mesh runs open (brcmfmac has no usable IBSS encryption)."
rfkill unblock wifi 2>/dev/null || true

# 1. Identity
hostnamectl set-hostname "$ID"
if grep -q '^127\.0\.1\.1' /etc/hosts; then sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$ID/" /etc/hosts; else printf '127.0.1.1\t%s\n' "$ID" >> /etc/hosts; fi
id -u "$ID" >/dev/null 2>&1 || useradd -m -s /bin/bash "$ID"
install -d -o "$ID" -g "$ID" -m 755 "/home/$ID/public"
chmod 755 "/home/$ID"

# 2. Address from the mesh radio's MAC: stable per Pi, and how peers turn a
#    gateway's batman originator address into its IP.
m=$(cat "/sys/class/net/$MESH_IF/address")
X=$((0x${m:12:2})); Y=$((0x${m:15:2}))
MYIP="$PFX.$X.$Y.1"; IP_PREFIX="$PFX.$X.$Y"

# 3. Take the mesh radio and the bridged ports away from NetworkManager. From
#    here on any failure makes systemd run mesh-down.sh, which gives them back.
ports=""
[ "${bridge_eth0:-no}" = yes ] && [ -e /sys/class/net/eth0 ] && ports="eth0" || true
[ "${usb_gadget:-no}" = yes ] && [ -e /sys/class/net/usb0 ] && ports="$ports usb0" || true
for d in "$MESH_IF" $ports; do
  nmcli device set "$d" managed no >/dev/null 2>&1 || true
done
# NetworkManager reports "unmanaged" at once, but its wpa_supplicant lets go of
# the radio only a moment later, and on the way out it puts the interface back
# into managed mode. Touching the radio before that happens makes the ad-hoc
# join fail with "Operation not supported", so wait for both.
for _ in $(seq 30); do
  case "$(nmcli -g GENERAL.STATE device show "$MESH_IF" 2>/dev/null || true)" in
    *unmanaged*|"") [ -e "/run/wpa_supplicant/$MESH_IF" ] || break ;;
  esac
  sleep 0.5
done
[ -e "/run/wpa_supplicant/$MESH_IF" ] && warn "wpa_supplicant still holds $MESH_IF after 15 s; trying anyway."
sleep 1

# 4. Ad-hoc cell on the mesh radio, batman-adv on top, bridge br0 for everything else
for attempt in 1 2 3; do
  ip link set "$MESH_IF" down
  iw dev "$MESH_IF" set type ibss || fail "$MESH_IF refused ad-hoc (IBSS) mode."
  # batman-adv prefers 1532 so its header fits without fragmenting. brcmfmac (Pi 4/5)
  # only allows 1500 and batman-adv then fragments by itself, so this is best-effort.
  ip link set "$MESH_IF" mtu 1532 2>/dev/null || true
  ip link set "$MESH_IF" up
  sleep 0.5
  # Make sure nothing flipped it back to managed mode behind our back before joining.
  iw dev "$MESH_IF" info 2>/dev/null | grep -q 'type IBSS' && break
  [ "$attempt" = 3 ] && fail "$MESH_IF keeps falling back out of ad-hoc mode; something else (wpa_supplicant?) still controls it."
  logger -t mesh-up "$MESH_IF was reset to managed mode by something else; setting ad-hoc again (attempt $attempt)"
done
iw dev "$MESH_IF" ibss leave 2>/dev/null || true
iw dev "$MESH_IF" ibss join "$MESH_ID" "$FREQ" fixed-freq "$BSSID" \
  || fail "could not join ad-hoc cell '$MESH_ID' ($FREQ MHz, cell $BSSID) on $MESH_IF."
ip link add bat0 type batadv 2>/dev/null || true
batctl if add "$MESH_IF" 2>/dev/null || batctl if 2>/dev/null | grep -q "^$MESH_IF:" || fail "batctl could not attach $MESH_IF to bat0."
batctl gw_mode client
ip link add br0 type bridge 2>/dev/null || true
ip link set bat0 master br0
ip link set bat0 up
ip link set br0 up
ip addr replace "$MYIP/8" dev br0
for p in $ports; do
  { ip link set "$p" master br0 && ip link set "$p" up; } || warn "could not bridge $p into the mesh."
done
for _ in $(seq 20); do   # joining or creating the cell takes a few seconds
  iw dev "$MESH_IF" link 2>/dev/null | grep -q 'Joined IBSS' && break
  sleep 0.5
done
iw dev "$MESH_IF" link 2>/dev/null | grep -q 'Joined IBSS' \
  || warn "$MESH_IF has not joined the ad-hoc cell yet (check: iw dev $MESH_IF link). It may still be scanning."

# 5. Per-node files and the services on the bridge
render "$TPL/dnsmasq.conf.tpl" /etc/dnsmasq.d/mesh.conf IP="$MYIP" IP_PREFIX="$IP_PREFIX" ID="$ID" GROUP="$GROUP"
printf 'ID=%s\nMYIP=%s\nGROUP=%s\nMESH_IF=%s\nMESH_BSSID=%s\n' "$ID" "$MYIP" "$GROUP" "$MESH_IF" "$BSSID" > /etc/default/mesh
install -d /run/dnsmasq; : > /run/dnsmasq/upstream.conf
touch /etc/hosts.mesh
install -d /var/www/mesh
[ -e /var/www/mesh/index.html ] || echo "<h1>$GROUP</h1><p>Looking for other nodes...</p>" > /var/www/mesh/index.html
systemctl restart dnsmasq || { journalctl -t dnsmasq -n 5 --no-pager >&2 || true; fail "dnsmasq rejected the rendered /etc/dnsmasq.d/mesh.conf (see above)."; }
grep -qx 'nameserver 127.0.0.1' /etc/resolv.conf 2>/dev/null \
  || { rm -f /etc/resolv.conf; printf 'nameserver 127.0.0.1\nsearch mesh\n' > /etc/resolv.conf; }   # undo the dispatcher's no-dnsmasq fallback
systemctl start avahi-daemon || warn "avahi-daemon failed to start; other nodes' names will not resolve (journalctl -u avahi-daemon)."
# caddy is ordered After=mesh.service, so it must be queued (--no-block): waiting
# for it from inside mesh.service's own start would deadlock until the timeout.
if command -v caddy >/dev/null 2>&1; then
  systemctl restart --no-block caddy || warn "caddy could not be started (journalctl -u caddy)."
fi

# 6. The mesh is up. The uplink radio's role (external network / access point) is
#    a separate unit, so the ESP32 can be plugged and unplugged at any time: udev
#    starts mesh-uplink@IFACE when it appears, systemd stops it when it goes.
#    Gateway status is re-evaluated on every network change and every 2 minutes.
touch "$RUN/up"
UPLINK_IF=$(resolve_uplink_if "$MESH_IF" || true)
if [ "$UPLINK" = off ]; then
  :
elif [ -n "$UPLINK_IF" ] && [ -e "/sys/class/net/$UPLINK_IF" ]; then
  systemctl start --no-block "mesh-uplink@$UPLINK_IF.service" || warn "could not queue the uplink role on $UPLINK_IF."
else
  warn "no uplink radio is attached (uplink_if=${uplink_if:-auto}); the mesh runs without it. Plug in the ESP32-C5 and its '$UPLINK' role starts by itself."
fi
systemctl start --no-block mesh-role-check.service 2>/dev/null || true
n=$(wc -l < "$WARN")
logger -t mesh-up "node $ID up at $MYIP on $MESH_IF (cell '$MESH_ID' $BSSID, $FREQ MHz), uplink=$UPLINK on ${UPLINK_IF:-none}, warnings=$n"
exit 0
EOF

  cat > /usr/local/sbin/mesh-down.sh <<'EOF'
#!/bin/bash
# Undo mesh-up.sh and hand every interface back to NetworkManager.
# Runs as ExecStopPost of mesh.service, so it also runs when mesh-up.sh failed
# half way. Every step tolerates things that never came up; it can run twice.
set -u
. /usr/local/lib/mesh/common.sh
load_conf
MESH_IF=$(sed -n 's/^MESH_IF=//p' /etc/default/mesh 2>/dev/null)
[ -n "$MESH_IF" ] || MESH_IF=$(resolve_mesh_if || true)
UPLINK_IF=$(cat "$RUN/uplink" 2>/dev/null || true)

rm -f "$RUN/up"
systemctl stop 'mesh-uplink@*.service' 2>/dev/null          # runs the uplink "down" action
systemctl stop mesh-role-check.timer mesh-hosts.timer hostapd caddy avahi-daemon 2>/dev/null
nft delete table inet meshgw 2>/dev/null
rm -f "$RUN/uplink" "$RUN/gateway"

[ -n "$MESH_IF" ] && batctl if del "$MESH_IF" 2>/dev/null
ip link del bat0 2>/dev/null
ip link del br0 2>/dev/null                      # releases eth0 / usb0

# Reset the mesh radio only while it is still ours. When NetworkManager already
# has it (second run, or a start that failed before the hand-over) leave it
# alone: the reset would knock it off the Wi-Fi it has just rejoined.
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

# DNS: drop the mesh upstreams and use whatever NetworkManager has right now.
# (If dnsmasq cannot start, the dispatcher points resolv.conf at those servers directly.)
systemctl is-active --quiet dnsmasq || systemctl start dnsmasq 2>/dev/null
if [ -x /etc/NetworkManager/dispatcher.d/50-mesh-dns ]; then
  /etc/NetworkManager/dispatcher.d/50-mesh-dns any refresh
else
  : > /run/dnsmasq/upstream.conf 2>/dev/null; pkill -HUP -x dnsmasq 2>/dev/null
fi
logger -t mesh-down "mesh stopped, radios returned to NetworkManager"
exit 0
EOF

  cat > /usr/local/sbin/mesh-uplink.sh <<'EOF'
#!/bin/bash
# Apply or clear the uplink radio's role: "mesh-uplink.sh IFACE up|down|check".
# Runs from mesh-uplink@IFACE.service, which udev starts when the radio appears
# and systemd stops when it is unplugged or the mesh stops. "check" is the
# two-minute fallback in case udev missed an event.
#
# Roles:  external  the radio stays with NetworkManager, which connects it to the
#                   user's own saved profile (eduroam, home Wi-Fi, ...). Nothing
#                   about that network is configured here.
#         ap        hostapd broadcasts the group's shared access point on it.
set -u
. /usr/local/lib/mesh/common.sh
IF=${1:-}; ACTION=${2:-up}
[ "$IF" = - ] && IF=""
load_conf
UPLINK=${uplink:-ap}
PROFILE=${uplink_profile:-auto}
# Log a warning and remember it for the menu's status page.
warn() { echo "mesh-uplink: WARNING: $*" >&2; logger -t mesh-uplink -p user.warning "WARNING: $*"; echo "$*" >> "$WARN"; }
MESH_IF=$(sed -n 's/^MESH_IF=//p' /etc/default/mesh 2>/dev/null)
is_uplink() {   # is $1 the interface the uplink role belongs to?
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
      systemctl stop "mesh-uplink@$cur.service" 2>/dev/null     # unplugged and udev missed it
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
      # This interface carried the role: stop what belonged to it. An external
      # connection is NetworkManager's and is left as it is.
      systemctl stop hostapd 2>/dev/null
      rm -f "$RUN/uplink"
      [ -x /usr/local/sbin/mesh-role.sh ] && /usr/local/sbin/mesh-role.sh UNPLUGGED   # re-evaluate the gateway role
      logger -t mesh-uplink "$IF released"
    fi
    exit 0 ;;
esac

# up
[ -e "$RUN/up" ] || { echo "mesh-uplink: the mesh is not running" >&2; exit 0; }
[ -n "$IF" ] && [ -e "/sys/class/net/$IF" ] || { echo "mesh-uplink: interface '$IF' is not present" >&2; exit 1; }
is_uplink "$IF" || { echo "mesh-uplink: $IF is not the uplink radio (uplink_if=${uplink_if:-auto}); nothing to do" >&2; exit 0; }
cur=$(cat "$RUN/uplink" 2>/dev/null || true)
if [ -n "$cur" ] && [ "$cur" != "$IF" ] && [ -e "/sys/class/net/$cur" ]; then
  echo "mesh-uplink: $cur already carries the uplink role; ignoring $IF" >&2; exit 0
fi
[ "$UPLINK" = off ] && { logger -t mesh-uplink "$IF present but uplink=off"; exit 0; }
echo "$IF" > "$RUN/uplink"
case "$UPLINK" in
  external)
    # NetworkManager owns the radio. If a saved profile was chosen, activate it;
    # with "auto", NetworkManager's own autoconnect does the job.
    nmcli device set "$IF" managed yes >/dev/null 2>&1 || true
    if [ "$PROFILE" != auto ]; then
      if ! nmcli -g connection.id connection show "$PROFILE" >/dev/null 2>&1; then
        warn "NetworkManager has no profile called '$PROFILE'. Connect to the external network once (desktop, or 'nmcli device wifi connect ...' while the mesh is off) so the profile exists, then pick it in mesh-config menu 3."
      else
        # A Wi-Fi profile made on the built-in radio is pinned to it; it must float to the ESP32.
        if [ "$(nmcli -g connection.interface-name connection show "$PROFILE" 2>/dev/null)" = "$MESH_IF" ]; then
          nmcli connection modify "$PROFILE" connection.interface-name "" >/dev/null 2>&1 \
            && logger -t mesh-uplink "profile '$PROFILE' was pinned to $MESH_IF; unpinned so it can use $IF"
        fi
        if [ "$(nmcli -g connection.type connection show "$PROFILE" 2>/dev/null)" = 802-11-wireless ]; then
          nmcli -w 30 connection up id "$PROFILE" ifname "$IF" >/dev/null 2>&1 \
            || nmcli -w 30 connection up id "$PROFILE" >/dev/null 2>&1 \
            || warn "could not bring up NetworkManager profile '$PROFILE' on $IF (nmcli connection up '$PROFILE')."
        else
          nmcli -w 30 connection up id "$PROFILE" >/dev/null 2>&1 \
            || warn "could not bring up NetworkManager profile '$PROFILE' (nmcli connection up '$PROFILE')."
        fi
      fi
    fi
    systemctl start --no-block mesh-role-check.service 2>/dev/null
    logger -t mesh-uplink "$IF handed to NetworkManager (profile: $PROFILE); gateway role follows the internet route"
    ;;
  ap)
    AP_SSID=${ap_ssid:-$GROUP-mesh}                  # one SSID for the whole group: laptops roam between AP nodes
    AP_CHANNEL=${ap_channel:-auto}
    if [ "$AP_CHANNEL" = auto ]; then
      # ESP-Hosted cannot pick a channel itself, so spread the AP nodes over the
      # four non-DFS 5 GHz channels by hashing the node id.
      AP_CHANNEL=$((36 + 4 * (0x$(printf %s "${id:-}" | md5sum | cut -c1-2) % 4)))
    fi
    nmcli device set "$IF" managed no >/dev/null 2>&1 || true
    render "$TPL/hostapd.conf.tpl" /etc/hostapd/hostapd.conf UPLINK_IF="$IF" AP_SSID="$AP_SSID" AP_CHANNEL="$AP_CHANNEL" AP_PSK="${ap_psk:-$GROUP.mesh}"
    systemctl start hostapd \
      || { warn "hostapd (access point '$AP_SSID' on $IF, channel $AP_CHANNEL) failed to start (journalctl -u hostapd). Is the ESP-Hosted driver built with ap_support?"; exit 1; }
    logger -t mesh-uplink "$IF broadcasting '$AP_SSID' on channel $AP_CHANNEL (max 8 clients per ESP32)"
    ;;
esac
exit 0
EOF

  cat > /usr/local/sbin/mesh-role.sh <<'EOF'
#!/bin/bash
# Promote or demote this node as an internet gateway for the mesh, depending on
# whether some NetworkManager connection outside the mesh (the ESP32 radio on
# eduroam or a home Wi-Fi, Ethernet, PPPoE, ...) currently reaches the internet.
# Called on every network change (NetworkManager dispatcher), by the two-minute
# timer, and when the uplink radio is unplugged. Arg: an event name, for the log.
set -u
. /usr/local/lib/mesh/common.sh
EV=${1:-CHECK}; [ "$EV" = - ] && EV=CHECK
# Only meaningful while the mesh runs; otherwise leave routes and DNS alone.
case "$(systemctl is-active mesh.service 2>/dev/null)" in active|activating) ;; *) exit 0 ;; esac
load_conf
PFX=${mesh_prefix:-10}
WAS=$(cat "$RUN/gateway" 2>/dev/null || true)     # interface we are currently a gateway on, if any

# online: does interface $1 really reach the internet?  peer_ip: a batman originator MAC
# to that node's mesh address.  nm_name: NetworkManager's connection name on interface $1.
online()  { curl -fsm5 -o /dev/null --interface "$1" http://detectportal.firefox.com/success.txt; }
peer_ip() { echo "$PFX.$((0x${1:12:2})).$((0x${1:15:2})).1"; }
nm_name() { nmcli -g GENERAL.CONNECTION device show "$1" 2>/dev/null; }
upstream_from() {   # dnsmasq upstream list = the DNS servers NetworkManager got on $1
  local dns; dns=$(nmcli -g IP4.DNS device show "$1" 2>/dev/null | tr '|' '\n' | sed 's/[[:space:]]//g; /^$/d')
  { for d in ${dns:-1.1.1.1}; do echo "server=$d@$1"; done; } > /run/dnsmasq/upstream.conf
}

# Become a gateway: NAT out of $1 (the interface with the internet route), announce it
# via batman-adv, and forward the mesh's DNS to the servers NetworkManager got on $1.
gateway_on() {
  nft delete table inet meshgw 2>/dev/null
  render "$TPL/meshgw.nft.tpl" /etc/nftables.d/meshgw.nft UPLINK_IF="$1" && nft -f /etc/nftables.d/meshgw.nft
  ip route del default dev br0 2>/dev/null
  batctl gw_mode server 50mbit/20mbit
  upstream_from "$1"
  echo "$1" > "$RUN/gateway"
  logger -t mesh-role "gateway ON via $1 ('$(nm_name "$1")', event=$EV)"
}
# Stop being a gateway and route through the best gateway batman-adv knows about, if any.
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
  [ -n "$WAS" ] && logger -t mesh-role "gateway OFF (was via $WAS, event=$EV)"
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
# Rebuild /etc/hosts.mesh from mDNS and regenerate the group directory page.
systemctl is-active --quiet mesh.service || exit 0
. /usr/local/lib/mesh/common.sh
load_conf
avahi-browse -trp _groupmesh._tcp 2>/dev/null \
  | awk -F';' '$1=="=" && $3=="IPv4" {print $8, $4".mesh"}' \
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
# ExecStopPost, not ExecStop: it also runs when mesh-up.sh failed half way, so
# the radio always goes back to NetworkManager.
ExecStopPost=/usr/local/sbin/mesh-down.sh

[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/mesh-uplink@.service <<'EOF'
[Unit]
Description=Uplink radio role on %i (external network or access point)
# Runs only while the mesh is up (condition) and only while the radio exists
# (BindsTo its device): udev starts it when %i appears, systemd stops it when
# %i is unplugged, and stopping the mesh stops it first (PartOf + After).
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
  # The timers belong to mesh.service: started with it (Wants= there), not
  # started if it fails and stopped whenever it goes down (BindsTo= + After=
  # here), never enabled at boot on their own. Running them while the mesh is
  # off used to wipe the DNS upstream list every two minutes.
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

  # --- activate
  # hostapd is started by the mesh scripts only. NetworkManager's own
  # wpa_supplicant.service is deliberately left alone: stopping it drops Wi-Fi.
  systemctl disable --now hostapd dhcpcd >/dev/null 2>&1 || true
  systemctl disable caddy >/dev/null 2>&1 || true
  systemctl daemon-reload
  systemctl disable mesh-hosts.timer mesh-role-check.timer >/dev/null 2>&1 || true   # older installs ran them at boot
  systemctl enable dnsmasq >/dev/null 2>&1 || echo "WARNING: could not enable dnsmasq at boot" >&2
  systemctl reset-failed dnsmasq >/dev/null 2>&1 || true
  if ! systemctl restart dnsmasq; then
    journalctl -t dnsmasq -n 10 --no-pager >&2 || true
    fail "dnsmasq failed to start (see above). The resolver was left untouched, so the network still works."
  fi

  # --- DNS hand-over to dnsmasq, done last and only once dnsmasq runs:
  #     seed its upstream list from the servers in use right now, stop
  #     NetworkManager writing resolv.conf, then point resolv.conf at dnsmasq.
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
  rm -f /etc/resolv.conf     # usually a symlink into /run/NetworkManager, which would dangle after a reboot
  printf 'nameserver 127.0.0.1\nsearch mesh\n' > /etc/resolv.conf

  sysctl -q --system >/dev/null 2>&1 || true
  modprobe batman-adv 2>/dev/null || echo "WARNING: kernel module batman-adv did not load (reboot after a kernel update?)" >&2
  install -m 755 "$SELF" /usr/local/sbin/mesh-config 2>/dev/null || true
  echo "System files written."
)

# Enable or disable the USB-C gadget port (dwc2 overlay + g_ether) in the boot files, per usb_gadget.
apply_usb_gadget() {
  local cfg=/boot/firmware/config.txt cmd=/boot/firmware/cmdline.txt
  [ -f "$cfg" ] || { cfg=/boot/config.txt; cmd=/boot/cmdline.txt; }
  [ -f "$cfg" ] && [ -f "$cmd" ] || { msg "Cannot find config.txt and cmdline.txt (looked in /boot/firmware and /boot); USB gadget setting not applied."; return 1; }
  if [ "$(cfg_get usb_gadget)" = yes ]; then
    grep -q '^dtoverlay=dwc2' "$cfg" || echo 'dtoverlay=dwc2' >> "$cfg"
    grep -q 'modules-load=dwc2,g_ether' "$cmd" || sed -i 's/$/ modules-load=dwc2,g_ether/' "$cmd"
  else
    sed -i '/^dtoverlay=dwc2$/d' "$cfg"
    sed -i 's/ modules-load=dwc2,g_ether//' "$cmd"
  fi
}

# ------------------------------------------------------------------ menus ----

# Menu 1: node identity (ID, group, display name) and the matching Linux user and web folder.
menu_identity() {
  local id group display rc
  id=$(ask "ID (letters and digits only). Becomes the hostname, the DNS name and the folder name under the group address." "$(cfg_get id)") || return
  id=$(echo "$id" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')
  [ -n "$id" ] || { msg "The ID cannot be empty."; return; }
  group=$(ask "Group name. Must be identical on every Pi in the group. Becomes the shared address <group>.mesh/$id/, the mesh name <group>.mesh and the access point <group>-mesh." "$(cfg_get group)") || return
  group=$(echo "$group" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')
  [ -n "$group" ] || group=group
  display=$(ask "Display name (optional, shown on your folder's page)." "$(cfg_get display)") || return
  cfg_set id "$id"; cfg_set group "$group"; cfg_set display "$display"
  if id -u "$id" >/dev/null 2>&1; then
    msg "Saved. Linux user '$id' already exists; the web folder is /home/$id/public."
  elif yesno "Create Linux user '$id' now with a password, so the student can log in and edit /home/$id/public?"; then
    clear
    if useradd -m -s /bin/bash "$id"; then
      install -d -o "$id" -g "$id" -m 755 "/home/$id/public"; chmod 755 "/home/$id"
      passwd "$id" || echo "passwd failed; set it later with: sudo passwd $id"
    else
      echo "useradd '$id' failed; see the message above."
    fi
    read -rp "Press Enter to continue"
  fi
  if ! installed; then
    yesno "System files are not installed yet. Install them now? (needed before the mesh can start)" || return
    clear; write_system_files; rc=$?
    [ $rc -eq 0 ] || echo "INSTALL FAILED (exit $rc) - see the messages above."
    read -rp "Press Enter to continue"
  fi
}

# Turn the mesh off and make sure the teardown really ran. A start that failed
# half way leaves the unit "failed", and for that unit "systemctl stop" does
# nothing at all, so mesh-down.sh is run directly in that case.
mesh_off() {
  local was_active=0
  mesh_active && was_active=1
  run_checked systemctl stop mesh.service || true
  systemctl reset-failed mesh.service 2>/dev/null
  [ "$was_active" = 1 ] || run_checked /usr/local/sbin/mesh-down.sh || true
}

# After a start or stop: say what happened, including the mesh scripts' warnings.
report_mesh_state() {
  local f
  if mesh_active; then
    if [ -s "$WARN_FILE" ]; then
      f=$(mktemp)
      {
        echo "Mesh is ON. This node is $(sed -n 's/^MYIP=//p' /etc/default/mesh 2>/dev/null) on $(sed -n 's/^MESH_IF=//p' /etc/default/mesh 2>/dev/null)."; echo
        echo "The mesh scripts reported these warnings:"; echo; sed 's/^/  - /' "$WARN_FILE"
      } > "$f"
      show_text "started with warnings" "$f"; rm -f "$f"
    else
      msg "Mesh is ON. This node is $(sed -n 's/^MYIP=//p' /etc/default/mesh 2>/dev/null) on $(sed -n 's/^MESH_IF=//p' /etc/default/mesh 2>/dev/null)."
    fi
  else
    msg "Mesh is OFF. The radios belong to NetworkManager again. Use menu 7 or 'nmcli device wifi connect <SSID> password <pw>' for normal Wi-Fi."
  fi
}

# Re-apply the uplink role without restarting the whole mesh.
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
    msg "Uplink role '$(cfg_get uplink)' applied on $cur. Check menu 8 (Status) in a few seconds."
  else
    msg "No uplink radio is attached right now. The role starts by itself when the ESP32-C5 is plugged in."
  fi
}

# Menu 2: turn the mesh on, off or restart it now; enable or disable it at boot.
menu_mesh_status() {
  local now boot choice
  mesh_active && now="ON" || now="OFF"
  mesh_enabled && boot="yes" || boot="no"
  choice=$(whiptail --title "$TITLE" --menu "Mesh is $now now. Start at boot: $boot.\n\nWhen the mesh is OFF, the radios belong to NetworkManager and normal Wi-Fi works." 18 70 6 \
      "1" "Turn mesh ON now" \
      "2" "Turn mesh OFF now (back to normal Wi-Fi)" \
      "3" "Restart mesh (apply changed settings)" \
      "4" "Start mesh at boot: enable" \
      "5" "Start mesh at boot: disable" \
      3>&1 1>&2 2>&3) || return
  installed || { msg "Install system files first (menu 6)."; return; }
  case $choice in 1|3) [ -n "$(cfg_get id)" ] || { msg "Set the node identity first (menu 1)."; return; } ;; esac
  clear
  case $choice in
    1) run_checked systemctl start mesh.service ;;
    2) mesh_off ;;
    3) run_checked systemctl restart mesh.service ;;
    4) run_checked systemctl enable mesh.service && msg "The mesh will start at boot."; return ;;
    5) run_checked systemctl disable mesh.service && msg "The mesh will not start at boot."; return ;;
  esac
  sleep 1
  report_mesh_state
}

# Pick one of NetworkManager's saved profiles for the external network.
choose_nm_profile() {
  local cur items=() name type dev
  cur=$(cfg_get uplink_profile)
  items+=("auto" "let NetworkManager autoconnect whatever it knows" "$([ "$cur" = auto ] && echo ON || echo OFF)")
  while IFS=: read -r name type dev; do
    [ -n "$name" ] && [ "$type" != loopback ] || continue
    case $type in 802-11-wireless) type=wifi ;; 802-3-ethernet) type=ethernet ;; esac
    items+=("$name" "${type}${dev:+ (on $dev)}" "$([ "$cur" = "$name" ] && echo ON || echo OFF)")
  done < <(nmcli -t -f NAME,TYPE,DEVICE connection show 2>/dev/null)
  whiptail --title "$TITLE" --radiolist "Saved NetworkManager profile to use for the external network (eduroam, home Wi-Fi, PPPoE, ...). Create it first: connect once from the desktop, or with 'nmcli device wifi connect <SSID> password <pw>' while the mesh is OFF, or 'nmcli connection add' for anything else." 22 76 10 \
      "${items[@]}" 3>&1 1>&2 2>&3
}

# Menu 3: which interface is the uplink radio and what it does (external network / access point / off).
menu_uplink() {
  local ifname role profile psk ssid chan cur_ssid
  ifname=$(ask "Uplink radio interface (the ESP32-C5 via ESP-Hosted). 'auto' = the first Wi-Fi interface that is not the Pi's built-in radio. Wi-Fi interfaces now: $(wifi_ifaces)" "$(cfg_get uplink_if)") || return
  [[ $ifname =~ ^(auto|[A-Za-z0-9_.-]{1,15})$ ]] || { msg "Enter 'auto' or an interface name such as wlan1."; return; }
  role=$(whiptail --title "$TITLE" --radiolist "What should the uplink radio do?\n\nSpace selects, Enter confirms." 17 76 3 \
      "external" "Join an external network via NetworkManager and share it (gateway)" "$([ "$(cfg_get uplink)" = external ] && echo ON || echo OFF)" \
      "ap"       "Broadcast the group access point so laptops can join"          "$([ "$(cfg_get uplink)" = ap ] && echo ON || echo OFF)" \
      "off"      "Leave the uplink radio unused"                                  "$([ "$(cfg_get uplink)" = off ] && echo ON || echo OFF)" \
      3>&1 1>&2 2>&3) || return
  # Nothing is written until every answer is in, so a cancelled dialog cannot
  # leave mesh.conf half updated.
  case $role in
    external)
      profile=$(choose_nm_profile) || return
      cfg_set uplink_if "$ifname"; cfg_set uplink external; cfg_set uplink_profile "$profile"
      msg "The uplink radio stays with NetworkManager, which connects it to '$profile'. Nothing about that network is configured here. Whenever this node actually reaches the internet, on any interface, it becomes a gateway for the mesh; the moment it drops it stops being one."
      ;;
    ap)
      cur_ssid=$(ap_ssid_name)
      ssid=$(ask "Access point name (SSID). Use the SAME name on every AP node so laptops roam between Pis. Default: <group>-mesh" "$cur_ssid") || return
      [ -n "$ssid" ] && [ ${#ssid} -le 32 ] && [[ $ssid != *\"* ]] || { msg "The SSID must be 1 to 32 characters, without double quotes."; return; }
      psk=$(ask "Access point passphrase (8 to 63 characters), the same on every AP node. Default: <group>.mesh" "$(ap_psk_value)") || return
      [ ${#psk} -ge 8 ] && [ ${#psk} -le 63 ] || { msg "Passphrase must be 8 to 63 characters."; return; }
      chan=$(whiptail --title "$TITLE" --radiolist "5 GHz channel for this Pi's access point. ESP-Hosted cannot choose one itself; 'auto' spreads the group over 36/40/44/48 by node ID." 15 74 5 \
          "auto" "one of 36/40/44/48, picked from the node ID" "$([ "$(cfg_get ap_channel)" = auto ] && echo ON || echo OFF)" \
          "36"   "5180 MHz" "$([ "$(cfg_get ap_channel)" = 36 ] && echo ON || echo OFF)" \
          "40"   "5200 MHz" "$([ "$(cfg_get ap_channel)" = 40 ] && echo ON || echo OFF)" \
          "44"   "5220 MHz" "$([ "$(cfg_get ap_channel)" = 44 ] && echo ON || echo OFF)" \
          "48"   "5240 MHz" "$([ "$(cfg_get ap_channel)" = 48 ] && echo ON || echo OFF)" \
          3>&1 1>&2 2>&3) || return
      cfg_set uplink_if "$ifname"; cfg_set uplink ap; cfg_set ap_channel "$chan"
      cfg_set_or_follow ap_ssid "$ssid" "$(group_name)-mesh"
      cfg_set_or_follow ap_psk "$psk" "$(group_name).mesh"
      msg "The uplink radio will broadcast '$ssid' (channel: $chan), bridged into the mesh. Laptops that join any AP node get an address from the mesh and reach every node's folder. Each ESP32 accepts at most 8 laptops, and the ESP-Hosted driver must be built with ap_support."
      ;;
    off) cfg_set uplink_if "$ifname"; cfg_set uplink off ;;
  esac
  if mesh_active; then
    yesno "Apply to the uplink radio now? (The mesh itself keeps running.)" && { clear; apply_uplink_now; }
  elif [ "$role" != off ] && [ -z "$(uplink_candidates)" ]; then
    msg "Note: no uplink radio is attached right now. The setting is saved; the role starts by itself when the ESP32-C5 is plugged in."
  fi
  return 0
}

# Menu 4: the ad-hoc mesh itself (radio interface, network name, channel, address block).
menu_radio() {
  local mif mid ch pfx
  mif=$(ask "Mesh radio interface. 'auto' = the Pi's built-in radio (brcmfmac), whatever it is named. Wi-Fi interfaces now: $(wifi_ifaces)" "$(cfg_get mesh_if)") || return
  [[ $mif =~ ^(auto|[A-Za-z0-9_.-]{1,15})$ ]] || { msg "Enter 'auto' or an interface name such as wlan0."; return; }
  mid=$(ask "Ad-hoc mesh name (the IBSS network name, identical on every Pi; the cell id is derived from it). Default: <group>.mesh" "$(mesh_name)") || return
  [ -n "$mid" ] && [ ${#mid} -le 32 ] && [[ $mid != *\"* ]] || { msg "The mesh name must be 1 to 32 characters, without double quotes."; return; }
  ch=$(whiptail --title "$TITLE" --radiolist "2.4 GHz channel for the mesh (identical on every Pi)" 12 60 3 \
      "1" "2412 MHz" "$([ "$(cfg_get mesh_channel)" = 1 ] && echo ON || echo OFF)" \
      "6" "2437 MHz" "$([ "$(cfg_get mesh_channel)" = 6 ] && echo ON || echo OFF)" \
      "11" "2462 MHz" "$([ "$(cfg_get mesh_channel)" = 11 ] && echo ON || echo OFF)" \
      3>&1 1>&2 2>&3) || return
  pfx=$(ask "First octet of the mesh address block (10 gives 10.X.Y.1/8). Change it only if the external network hands out 10.x addresses." "$(cfg_get mesh_prefix)") || return
  [[ $pfx =~ ^[0-9]+$ ]] && [ "$pfx" -ge 1 ] && [ "$pfx" -le 223 ] || { msg "The first octet must be a number from 1 to 223."; return; }
  cfg_set mesh_if "$mif"; cfg_set mesh_channel "$ch"; cfg_set mesh_prefix "$pfx"
  cfg_set_or_follow mesh_id "$mid" "$(group_name).mesh"
  msg "Saved. The ad-hoc mesh is an OPEN network (the Pi's radio offers no usable ad-hoc encryption): anyone within range can join the group LAN."
  mesh_active && yesno "Restart the mesh now to apply?" && { clear; run_checked systemctl restart mesh.service && report_mesh_state; }
  return 0
}

# Menu 5: wired ways into the mesh (Ethernet bridge, USB-C gadget).
menu_ports() {
  local sel
  sel=$(whiptail --title "$TITLE" --checklist "Wired ways for a laptop to join this Pi's mesh. Space toggles. (Leave Ethernet unticked if eth0 is your external network, e.g. PPPoE.)" 14 74 2 \
      "eth0" "Bridge the Ethernet port into the mesh"             "$([ "$(cfg_get bridge_eth0)" = yes ] && echo ON || echo OFF)" \
      "usb"  "USB-C gadget mode: one cable = power + network (Pi 4/5, needs reboot)" "$([ "$(cfg_get usb_gadget)" = yes ] && echo ON || echo OFF)" \
      3>&1 1>&2 2>&3) || return
  [[ $sel == *eth0* ]] && cfg_set bridge_eth0 yes || cfg_set bridge_eth0 no
  [[ $sel == *usb* ]]  && cfg_set usb_gadget yes  || cfg_set usb_gadget no
  apply_usb_gadget || return
  msg "Saved. USB gadget changes take effect after a reboot; Ethernet bridging applies on the next mesh start."
}

# Menu 6: write or refresh every system file.
menu_install() {
  local rc
  yesno "Write or refresh every system file (scripts, units, templates, firewall, udev, NetworkManager and dnsmasq config) and install packages? Existing mesh.conf settings are kept." || return
  clear; write_system_files; rc=$?
  [ $rc -eq 0 ] || echo "INSTALL FAILED (exit $rc) - see the messages above."
  read -rp "Press Enter to continue"
}

# Menu 7: join a normal Wi-Fi network through NetworkManager (turns the mesh off first).
menu_wifi() {
  local list ssid pw
  if mesh_active; then
    yesno "The mesh is ON and owns the built-in radio. Turn it OFF now so it can join normal Wi-Fi?" || return
    clear; mesh_off; sleep 2
  fi
  clear; echo "Scanning..."; nmcli device wifi rescan 2>/dev/null; sleep 3
  list=$(nmcli -t -f SSID,SIGNAL device wifi list 2>/dev/null | awk -F: '$1!="" && !seen[$1]++ {print $1"\t"$2"%"}' | sort -t$'\t' -k2 -rn | head -20)
  [ -n "$list" ] || { msg "No networks found. Is the mesh off and the radio managed by NetworkManager? Check with: nmcli device status"; return; }
  local -a items=()
  while IFS=$'\t' read -r s sig; do items+=("$s" "$sig"); done <<< "$list"
  ssid=$(whiptail --title "$TITLE" --menu "Pick a network (the profile NetworkManager saves can later serve as the external network)" 22 70 12 "${items[@]}" 3>&1 1>&2 2>&3) || return
  pw=$(pass "Password for $ssid (leave empty for an open network)") || return
  clear
  if [ -n "$pw" ]; then nmcli device wifi connect "$ssid" password "$pw"; else nmcli device wifi connect "$ssid"; fi \
    || echo "Could not connect to '$ssid'; see the message above."
  read -rp "Press Enter to continue"
}

# Menu 8 and "status": one page with config, services, radios, gateway, neighbours, names and the recent log.
show_status() {
  local f mif uif gw; f=$(mktemp)
  mif=$(sed -n 's/^MESH_IF=//p' /etc/default/mesh 2>/dev/null); uif=$(cat /run/mesh/uplink 2>/dev/null); gw=$(cat /run/mesh/gateway 2>/dev/null)
  {
    echo "mesh.conf: $CONF"; echo "----"; sed 's/^\(ap_psk\|mesh_psk\)=.*/\1=(hidden)/' "$CONF" 2>/dev/null
    echo "derived: group=$(group_name) mesh name=$(mesh_name) access point=$(ap_ssid_name)"
    echo; echo "mesh.service: $(systemctl is-active mesh.service) (boot: $(systemctl is-enabled mesh.service 2>/dev/null))"
    echo "dnsmasq: $(systemctl is-active dnsmasq)  avahi: $(systemctl is-active avahi-daemon)  caddy: $(systemctl is-active caddy 2>/dev/null)  hostapd: $(systemctl is-active hostapd)"
    echo; echo "Wi-Fi interfaces: $(wifi_ifaces)"
    echo "Mesh radio: ${mif:-not running}  $(iw dev "${mif:-none}" link 2>/dev/null | head -1)"
    echo "Uplink radio: ${uif:-none attached} (configured: $(cfg_get uplink_if), role: $(cfg_get uplink), profile: $(cfg_get uplink_profile)) mesh-uplink@${uif:-?}: $(systemctl is-active "mesh-uplink@${uif:-none}" 2>/dev/null)"
    [ "$(systemctl is-active hostapd 2>/dev/null)" = active ] && echo "Access point: '$(sed -n 's/^ssid=//p' /etc/hostapd/hostapd.conf 2>/dev/null)' channel $(sed -n 's/^channel=//p' /etc/hostapd/hostapd.conf 2>/dev/null), clients: $(iw dev "${uif:-none}" station dump 2>/dev/null | grep -c '^Station') of 8"
    if [ -n "$gw" ]; then echo "Gateway: ON via $gw ('$(nmcli -g GENERAL.CONNECTION device show "$gw" 2>/dev/null)')"; else echo "Gateway: OFF (using another node's gateway if batctl gwl lists one)"; fi
    echo; echo "Interfaces (NetworkManager view):"; nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null | grep -v '^lo:'
    echo; echo "Addresses:"; ip -4 -br addr 2>/dev/null
    echo; echo "Default routes:"; ip route show default 2>/dev/null
    echo; echo "Gateway mode: $(batctl gw_mode 2>/dev/null)"
    echo; echo "Mesh neighbours (batctl o):"; batctl o 2>/dev/null | tail -n +2 | head -20
    echo; echo "Gateways (batctl gwl):"; batctl gwl 2>/dev/null
    echo; echo "Names (/etc/hosts.mesh):"; cat /etc/hosts.mesh 2>/dev/null
    echo; echo "Upstream DNS:"; cat /run/dnsmasq/upstream.conf 2>/dev/null
    if [ -s "$WARN_FILE" ]; then echo; echo "Warnings from the last mesh start:"; sed 's/^/  - /' "$WARN_FILE"; fi
    echo; echo "Recent mesh log:"; journalctl -u mesh.service -u 'mesh-uplink@*' -u mesh-role-check.service -n 15 --no-pager 2>/dev/null
  } > "$f"
  show_text "status" "$f"
  rm -f "$f"
}

# The interactive whiptail menu loop.
main_menu() {
  INTERACTIVE=1
  ensure_whiptail
  set_defaults
  while true; do
    local id state choice
    id=$(cfg_get id)
    mesh_active && state="ON" || state="OFF"
    choice=$(whiptail --title "$TITLE" --menu "ID: ${id:-<not set>}   Group: $(group_name)   Mesh: $state   uplink: $(cfg_get uplink)" 20 74 9 \
      "1" "Node identity (ID, group, Linux user)" \
      "2" "Mesh status (ON / OFF / at boot)" \
      "3" "Uplink radio (ESP32-C5): external network / access point / off" \
      "4" "Mesh radio (ad-hoc name, channel, address block, interface)" \
      "5" "Wired access ports (Ethernet bridge, USB-C gadget)" \
      "6" "Install or refresh system files" \
      "7" "Join normal Wi-Fi (turns the mesh off)" \
      "8" "Status" \
      "9" "Finish" \
      3>&1 1>&2 2>&3) || break
    case $choice in
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

# Entry point: "install" and "status" are non-interactive, anything else opens the menu.
case "${1:-}" in
  install) set_defaults; write_system_files; exit $? ;;
  status)  show_status ;;
  *)       main_menu ;;
esac
