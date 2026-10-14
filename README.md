# Turning a Dead-Flagship Android Phone into a Headless Linux Host

**No root. No bootloader unlock. No custom ROM. A phone from 2017, running as a 24/7 server.**

> *"Is this thing on?"*
> `ps` says yes. `ss` says the port is listening. Android's own process manager
> lists it as *protected*. And yet nothing answers.
>
> This repo is about that gap — and the handful of small scripts that close it.

---

## TL;DR

A Huawei Nova 2s (2017, Kirin 970, Android 9) now runs as an always-on Linux box:

| | |
|---|---|
| **Real Linux userspace** | Debian 12 (bookworm), aarch64, via `proot-distro` |
| **Remote shell** | OpenSSH on **port 8022**, over a Tailscale mesh |
| **Works while out of the house** | Yes — no computer at home required |
| **Survives reboots** | Yes (autostart + watchdog, both below) |
| **Root / unlocked bootloader** | None |
| **Hardware** | 8× Cortex-A73 @ 1.84 GHz, 5.7 GB RAM, 43 GB free |
| **Free hardware cost** | A phone you'd otherwise put in a drawer |

The catch: **this is Android, and Android lies to you about whether your services are alive.**
Everything below is either a workaround for that, or a consequence of it.

---

## Table of contents

1. [The real problem: "alive" ≠ "working"](#1-the-real-problem-alive--working)
2. [Hardware](#2-hardware)
3. [The stack](#3-the-stack)
4. [Build it](#4-build-it)
5. [Remote access without a computer at home](#5-remote-access-without-a-computer-at-home)
6. [Surviving reboots (autostart)](#6-surviving-reboots)
7. [The watchdog](#7-the-watchdog)
8. [Wounds](#8-wounds) ← the useful part
9. [Postmortem: the outage of 2026-10-14](#9-postmortem-the-outage-of-2026-10-14)
10. [Measurements](#10-measurements)
11. [Hard limits](#11-hard-limits)
12. [Reproduce this checklist](#12-reproduce-this-checklist)

---

## 1. The real problem: "alive" ≠ "working"

The single most expensive lesson from this build:

> **On a mobile OS, "the process exists" tells you almost nothing.**
> Android's app-freezer keeps processes in the process table while denying them CPU.
> Your SSH daemon can be `running`, its port can be `listening`, and it will not
> answer a single byte of handshake traffic.

Every multi-day debugging detour in this project came back to that one fact. If you
take one thing from this repo: **always verify a service by talking to it**, never by
looking at `ps`.

```bash
# Wrong. Reports "alive" for a frozen daemon.
pgrep -x sshd

# Right. A frozen process cannot complete a TCP handshake.
timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/8022'
```

Section [8](#8-wounds) and [9](#9-postmortem-the-outage-of-2026-10-14) are the receipts.

---

## 2. Hardware

Nothing special — which is the point. This is a **used phone that was already in a drawer**.

```
Model      Huawei Nova 2s  (HWI-AL00)
SoC        Kirin 970 (hi3660) — 8× Cortex-A73 @ 1.844 GHz
RAM        5.7 GB total
Storage    52 GB, ~43 GB free at build time
Android    9 (EMUI 9.1.0.219)
USB        USB-C
```

Deliberately **not** used: root, Magisk, TWRP, kernel modules, any unlock procedure.
If your only path to a host requires defeating secure boot, it is not a cheap host —
it is a hobby that eats weekends. Every technique below works on a stock, unmodified,
unrooted phone.

---

## 3. The stack

```
        ┌──────────────────────────────────────────┐
your    │  laptop / desktop                       │
laptop  └───────────────┬──────────────────────────┘
                        │  ssh -p 8022 <tailscale-ip>
                        │  (anywhere, via mesh VPN)
        ┌───────────────▼──────────────────────────┐
phone   │  Tailscale        (overlay network)      │
        │  sshd             (:8022)   ← entrypoint │
        │  watchdog         (keeps sshd honest)     │
        │  Termux ──────────────────────────────────┼──┐
        │    └─ Debian 12 bookworm (proot-distro) ──┘  │
        │                                           │
        │  Android 9 / EMUI  (the host OS)         │
        └───────────────────────────────────────────┘
```

| Component | Why this one |
|---|---|
| **Termux** | The only sane Android terminal. Its `/data/data/com.termux/files/usr` is a real usr tree. |
| **proot-distro** | Gives a genuine Debian 12 userspace with working `apt`. No root, uses `ptrace` + bind mounts. |
| **OpenSSH** | The entrypoint. Chosen because it survives everything Android can throw at it. |
| **Tailscale** | WireGuard overlay. Reaches the phone from any network without port forwarding. |
| **Termux:Boot** | Runs one script on device boot. The backbone of survival. |

> **Port 8022, not 22.** Termux's sshd listens on 8022 by default. `Connection refused`
> on port 22 means *nothing is wrong* — it means you haven't learned this yet. Check 8022 first.

---

## 4. Build it

### 4.1 Termux + Debian

```bash
# Termux:API, Termux:Boot from F-Droid (not the abandoned Play Store build)
pkg update && pkg upgrade -y
pkg install proot-distro termux-api
termux-setup-storage            # only if you need shared storage

proot-distro install debian
proot-distro login debian
# inside Debian:
apt update && apt upgrade -y
```

Give it a one-letter alias — you'll use it daily:

```bash
echo 'alias d="proot-distro login debian-arm64"' >> ~/.bashrc
```

**proot does not nest.** If `d` errors with
`attempted to run proot-distro in a proot session`, you are *already inside* Debian.
`exit` first. That error is never a broken install — check for a running
`proot --kill-on-exit` before debugging anything else.

### 4.2 Debian needs a route out

If `apt update` hangs, read this before blaming the mirror: **Android permits exactly one
VPN at a time.** A locally-installed VPN client (Clash and friends) will silently
displace Tailscale and starve the container of connectivity. Either keep the proxy off
while syncing, or transfer packages from another machine:

```bash
# On a better-connected machine:
docker create --platform linux/arm64 debian:bookworm-slim out
docker export out | gzip > debian.tar.gz

# Push and install on the phone:
proot-distro install debian-arm64 ./debian.tar.gz
```

> `docker save` fails on multi-arch images with
> `unable to create manifests file: NotFound`. Use `create` + `export`. This cost an hour.

### 4.3 SSH

```bash
pkg install openssh
passwd                          # Termux user has no password by default
sshd -i                          # generate host keys (once)
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# copy your public key into ~/.ssh/authorized_keys (chmod 600)
sshd                             # start
```

Verify from the laptop: `ssh -p 8022 <phone-ip> 'echo OK'`

---

## 5. Remote access without a computer at home

This is the point of the whole exercise: **the phone is the host.** No home PC needs to
be awake, reachable, or even present.

```bash
# On the phone
pkg install tailscale
tailscale up --advertise-tags=server

# On the laptop
tailscale up
ping <phone-tailnet-ip>          # 100.x.y.z, stable forever
ssh -p 8022 phone@<phone-tailnet-ip>
```

- Same WiFi → direct connection, single-digit ms.
- Different network → transparently relayed (DERP), still works, still encrypted.
- **No port forwarding, no dynamic DNS, no static IP.** The tailnet IP never changes.

Lock it down and it becomes a self-sufficient box:

```bash
# Only this laptop's key may connect; and only into Debian
# (Match blocks live in $PREFIX/etc/ssh/sshd_config)
Match User u0_a161 Address 100.x.y.z/32
    ChrootDirectory ...   # or simply: ForceCommand proot-distro login debian-arm64
```

---

## 6. Surviving reboots

Two components, both in `scripts/`:

**`Termux:Boot`** (an APK, opened once by hand) invokes
`~/.termux/boot/start-services.sh` on every boot. The essential detail:

```bash
setsid /data/data/com.termux/files/usr/bin/sshd
setsid nohup .../sshd-watchdog.sh </dev/null >/dev/null 2>&1 &
```

### Why `setsid` is not optional

Without `setsid`, both daemons remain **children of the boot script's session**.
When that session ends, the platform reaps the whole process group — and your SSH
entrypoint silently vanishes.

This is exactly the kind of bug that survives months: `setsid` looks like a no-op
because everything works fine *right up until the next reboot*. The build log for this
project contains that mistake in writing: *"the watchdog must be started with
`setsid`, otherwise it dies with the session that spawned it"* — filed under "lessons
learned", then never applied to the file that actually runs at boot.

Rule: **anything that must outlive the thing that started it needs `setsid`.**
Every time. Including things you are certain about.

`start-services.sh` also writes to `~/.termux/boot/startup.log`. Adding logging to a
boot script is the cheapest possible observability, and its absence is why a multi-day
outage had to be diagnosed by guesswork.

---

## 7. The watchdog

The watchdog's entire reason for existing is section [1](#1-the-real-problem-alive--working).
The naive version is wrong:

```bash
# WRONG — never fails, therefore never useful on this device
while true; do
  pgrep -x sshd >/dev/null 2>&1 || sshd
  sleep 15
done
```

A frozen `sshd` is *present*. `pgrep` succeeds. The watchdog sleeps through the outage.

The correct version probes the service the way a client would:

```bash
# scripts/sshd-watchdog.sh
PORT=8022
while true; do
  if ! timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then
    pkill -x sshd; sleep 2
    setsid sshd 2>>"$LOG"     # the restart needs setsid for the same reason
    sleep 5
  fi
  sleep 15
done
```

One probe per 15 s costs one TCP handshake. It emits a completed `sshd` child that
exits immediately. That is the cheapest possible proof of life, and it catches both
failure modes — dead *and* frozen — with one check.

It also watches the tailnet and notifies on **state change only**, so it cannot spam:

```bash
ping -c 1 -W 3 "$TAILNET_IP" || termux-toast "remote tunnel down"
```

**Verified behaviour:** `pkill -x sshd` → service restored within one probe interval.

---

## 8. Wounds

The vendor-specific part. Huawei's EMUI is not hostile, but it is *opinionated*, and
every one of these cost real debugging time.

### 8.1 `adb` over TCP dies the moment you unplug

The usual trick is `adb tcpip 5555`. On this device, `adbd` **kills itself on USB
disconnect**, and `persist.adb.tcp.port` cannot be set (the property is not writable;
`ro.secure=1`). Verified dead ends:

```
setprop persist.adb.tcp.port 5555   →  setprop: failed
```

**Workaround: never let it see the unplug.** Keep the phone tethered to *any* always-on
USB host — here, an HDMI television that is powered but screen-off. `USB powered: true`
keeps `adbd` alive indefinitely. The TV's Tailscale state is irrelevant; it only needs
to stay powered.

> **A powered-off screen is not a powered-off device.** The TV draws 1–2 W in deep
> standby and keeps the anchor alive. Verified: TV offline for 2 hours, phone `adb`
> still enumerating, camera still streaming.

**Recovery when it has already died — both steps, neither is optional:**
1. Settings → Developer options → enable **USB debugging** *and* **ADB while charging only**.
2. **Unplug and replug the cable.** Just toggling switches does nothing.

Root cause of #2: while the phone is tethered as an MTP device, the active USB
function table is read by `init` **at the moment of insertion**. Developer-option
changes only take effect on the next physical insertion.

### 8.2 The freezer

EMUI's app-freezer suspends background processes. A suspended process still appears in
`ps`, still holds its sockets, still answers with a socket that is bound — and executes
no instructions. On a server this is a catastrophic, invisible failure mode.

Its fingerprints:

- `load average` pinned at **~41 on 8 cores** while the box is provably idle.
- A busy-loop benchmark reporting ~96% CPU utilisation on an idle machine.
- TCP connects that reach `SYN_RCV` and then time out — the handshake is never *processed*.

Developer options → *Background process limits → Standard* and per-app *manual*
management (all three toggles on) keep it out of the freezer. With that set, 40
consecutive SSH probes passed with zero failures.

### 8.3 `termux-job-scheduler` registers and never fires

```bash
termux-job-scheduler --job-id 9001 --script ~/.local/bin/keepalive.sh \
  --period-ms 900000 --network none --persisted true
# exit 0 — success!
termux-job-scheduler -p     # → empty, forever
```

Exit code 0 is a lie. On this ROM the task is registered and never scheduled. Do not
build your recovery plan on it; treat it as a bonus if it ever runs. (Also: the
JSON-on-stdin form is obsolete and fails with `No script path given`.)

### 8.4 Huawei's app launcher manager

Apps classified as *protected* get frozen aggressively on battery saver. Tailscale's
Android app and Termux both landed in that bucket. Set **manual management** with all
three switches enabled, per app. Otherwise you are debugging phantom outages that a
phone reboot silently "fixes".

### 8.5 Debugging by USB is possible but narrow

If the phone is tethered to a laptop, you can drive it without any network at all —
useful precisely because it works when everything else has failed.

`adb shell am startservice -n com.termux/.app.RunTermuxService` **does not work**
(current Termux has no such component — `Error: not found`). What works is foreground +
synthetic keystrokes:

```bash
adb shell 'am start -n com.termux/.app.TermuxActivity'
sleep 2
adb shell 'input text "sshd"'
sleep 2                        # ← mandatory, see below
adb shell 'input keyevent 66'   # ENTER
```

Two sharp edges, both paid for:

- **`input text` drops characters.** Typing `sshd` can land as `shd`. Always pause
  after typing, before ENTER. Re-type once on `command not found`.
- **A full-screen TUI in Termux swallows input.** If a CLI prompt (a trust dialog,
  a TUI app) owns the screen, your keystrokes go to *it*. Dismiss it with
  `input keyevent 111` (ESC) first. Do **not** press ENTER blindly — on a dialog
  that is how you terminate the user's running process.

---

## 9. Postmortem: the outage of 2026-10-14

Worth writing down, because the wrong diagnosis was more expensive than the fix.

**Symptom.** Node offline for 8 hours. 100% packet loss. All layers appeared healthy.

**Wrong diagnosis (mine).** Huawei's app-launcher had frozen Termux and Tailscale.
Evidence cited: both package names appeared in `logcat` under
`ApplistMgr: Standby protected apps: [...]`.

**Why it was wrong.** That log line is a routine bookkeeping entry about the standby
*list*, not a report of an active freeze. The decisive counter-evidence was ignored:
**the Termux main process had been alive, unbroken, for 8 h 57 min.** A frozen app
does not keep a process alive for nine hours. And the launch-manager settings were
already correct — nothing had been misconfigured.

> Method note: a log line containing a package name is not evidence that the package
> is frozen. Verify process liveness directly. Correlation in a log is not cause.

**Actual cause — two bugs in my own boot setup, neither visible from the symptoms:**

1. The boot script started the watchdog **without `setsid`** (§6). When the boot
   session ended, the watchdog was reaped, leaving `sshd` unsupervised.
2. The watchdog **checked `pgrep` instead of probing the port** (§7), so even while
   alive it was structurally incapable of detecting the failure it existed to catch.

Together: after a reboot, `sshd` was unsupervised *and* unobservable. Both defects
were documented in the project notes — in prose, in a section about pitfalls — and
neither had been applied to the file that runs. **Documentation that doesn't reach the
file is not a fix.**

**Recovery.** USB tether + synthetic keystroke to restart `sshd` (§8.5). Fixed in
under five minutes. Then the two files were rewritten, and the fix verified by
`pkill`-ing the daemon and watching it self-heal.

**Port note.** The first thing attempted was port 22, which of course refused
connections, because Termux uses 8022. It cost a diagnostic round-trip that the
documentation had already paid for.

---

## 10. Measurements

| Metric | Value | Note |
|---|---|---|
| Debian userspace | 12 (bookworm), aarch64 | `apt` functional |
| Memory available | ~3.2 GB of 5.7 GB | after trimming |
| Storage free | 43 GB of 52 GB | apps on `/system`; uninstalling frees no bytes |
| Load average (idle) | ~41 | **phantom** — see §8.2 |
| CPU idle | ~800% | the real number |
| Cold `sshd` recovery | < 25 s | watchdog, measured |
| Enabled packages | 198 → 82 | `pm uninstall -k --user 0` |
| Memory reclaimed | +241 MB available | 22 packages frozen, then uninstalled |

Trimming note: on Android, **uninstalling a system app frees memory, not storage** —
the APK lives on a read-only partition regardless. Expect RAM savings and zero disk
savings, and say so plainly rather than letting the numbers surprise you.

---

## 11. Hard limits

Stated plainly, because a post that oversells is a post that wastes your afternoon.

- **Do not reboot the device casually.** Anything set at runtime is lost on reboot.
  Recovery requires physical access to the phone and a cable re-insertion. Treat a
  reboot as a site visit.
- **Screen mirroring is view-only.** Mirroring with input injection crashes on this
  ROM (`NoClassDefFoundError` in the mirror server's context bootstrap). The
  view-only flags work; control does not. Upstream reports are open and unresolved.
- **No disk-level passthrough, no real block devices.** The container shares the
  phone's storage.
- **Battery is the only part that can't be engineered away.** The phone must stay
  plugged in. A host that sleeps is not a host.

---

## 12. Reproduce this checklist

Ordered by "cheapest thing that unblocks the next step."

```
[ ] Termux (F-Droid) + Termux:API + Termux:Boot installed
[ ] proot-distro + Debian 12 installed; alias d works
[ ] Only ONE VPN client active at a time — check before blaming apt
[ ] openssh installed; host keys generated; public key authorized
[ ] sshd listening on 8022 — verify by HANDSHAKE, not by pgrep
[ ] Tailscale up on phone and laptop; tailnet IP is stable
[ ] ssh -p 8022 works from a *different* network (the real test)
[ ] start-services.sh: setsid on everything long-lived
[ ] Boot log exists at ~/.termux/boot/startup.log
[ ] Watchdog probes a PORT, not a process
[ ] Watchdog restarts use setsid too
[ ] Test the watchdog for real: pkill -x sshd, wait, confirm
[ ] USB anchor strategy decided and documented (for adb-dependent work)
[ ] Reboot-survival test performed *before* you need it
```

The last two are the ones people skip. Do them on a day when nothing is on fire.

---

## Files

```
scripts/start-services.sh     # Termux:Boot entrypoint — setsid, logging, no duplicates
scripts/sshd-watchdog.sh      # port-probing watchdog + change-only notifications
```

Both are drop-in. Adjust `$PREFIX` paths and the tailnet IP; nothing else is
device-specific.

---

## License

MIT. Use it, adapt it, tell me what you broke.