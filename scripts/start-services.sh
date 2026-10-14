#!/data/data/com.termux/files/usr/bin/bash
# Boot entrypoint, invoked by the Termux:Boot app on every device boot.
#
# The one thing that matters here: everything long-lived is started with `setsid`.
# Without it these processes stay children of this script's session and get reaped
# when it ends — which means your remote entrypoint vanishes on every reboot, and
# only on every reboot, which is the worst possible failure mode to debug.
#
# Second thing: log. A boot script with no output is a boot script you will
# one day end up diagnosing by guesswork.

exec >>/data/data/com.termux/files/home/.termux/boot/startup.log 2>&1
echo "=== $(date '+%F %T') boot ==="

termux-wake-lock
sleep 8

# --- sshd: probe before starting, so a re-run doesn't spam "already running" ---
if timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/8022' 2>/dev/null; then
  echo "sshd responding — skip"
else
  echo "starting sshd"
  setsid /data/data/com.termux/files/usr/bin/sshd
  sleep 2
fi

# --- watchdog: don't start a second copy ---
if pgrep -f 'sshd-watchdog' >/dev/null 2>&1; then
  echo "watchdog already running — skip"
else
  echo "starting watchdog"
  setsid nohup /data/data/com.termux/files/usr/bin/bash \
    /data/data/com.termux/files/home/.local/bin/sshd-watchdog.sh \
    </dev/null >/dev/null 2>&1 &
fi

# --- belt-and-braces: ask Android's own scheduler to re-run the keepalive.
#     On some OEM ROMs this registers (exit 0) and is then never scheduled again.
#     Verify with `termux-job-scheduler -p` rather than trusting the exit code.
/data/data/com.termux/files/usr/bin/termux-job-scheduler --job-id 9001 \
  --script /data/data/com.termux/files/usr/home/.local/bin/sshd-keepalive.sh \
  --period-ms 900000 --network none --persisted true

echo "=== done ==="
exit 0