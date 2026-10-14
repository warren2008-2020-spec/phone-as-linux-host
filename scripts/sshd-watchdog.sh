#!/data/data/com.termux/files/usr/bin/bash
# sshd watchdog — the portable version of a script I got wrong twice.
#
# WHY NOT `pgrep`:
#   Android's app-freezer suspends background processes. A suspended process still
#   appears in `ps` and still holds its sockets, but executes nothing. On this
#   device `sshd` was observed frozen: present, listening, answering zero bytes.
#   `pgrep` therefore always reports "alive", so a pgrep-based watchdog can never
#   detect the failure it exists to catch.
#
#   Probe the PORT. A frozen process cannot complete a TCP handshake.
#
# WHY `setsid` ON THE RESTART:
#   The sshd we spawn must not die when this watchdog dies — same lesson, one
#   level down.
#
# Adjust: PORT and TAILNET_IP for your device.

PORT=8022
TAILNET_IP=100.x.y.z            # your phone's stable tailnet address
LOG=/data/data/com.termux/files/home/.sshd-keepalive.log
TS_STATE=/data/data/com.termux/files/home/.ts_state
export PATH="/data/data/com.termux/files/usr/bin:/system/bin"

ts_check() {
  # A VPN app cannot be started from Termux (no permission), so a down tailnet is
  # only reportable, not fixable. Notify on TRANSITION ONLY — this loops forever.
  local now=down
  ping -c 1 -W 3 "$TAILNET_IP" >/dev/null 2>&1 && now=up
  local prev
  prev=$(cat "$TS_STATE" 2>/dev/null || echo unknown)
  if [ "$prev" != "$now" ]; then
    echo "$now" > "$TS_STATE"
    if [ "$now" = down ]; then
      termux-toast "Remote tunnel down: Tailscale is offline. SSH is still up." 2>/dev/null
    else
      termux-toast "Remote tunnel restored: Tailscale is back online." 2>/dev/null
    fi
  fi
}

ts_tick=0
while true; do
  if ! timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then
    echo "$(date '+%F %T')  port $PORT did not respond — restarting sshd" >> "$LOG"
    pkill -x sshd 2>/dev/null
    sleep 2
    setsid /data/data/com.termux/files/usr/bin/sshd 2>>"$LOG"
    sleep 5
  fi

  # ~5 min between tailnet checks
  ts_tick=$((ts_tick + 1))
  [ $((ts_tick % 20)) -eq 1 ] && ts_check

  sleep 15
done