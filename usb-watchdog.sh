#!/bin/bash
# USB Watchdog — detects xHCI controller lockups and auto-recovers
# Monitors kernel log for fatal USB errors and escalates recovery
# Runs as a user service with targeted sudoers rules.
#
# Recovery levels:
#   0 — EARLY INTERVENTION: gentle Kiyo-only port cycle on a PRE-CASCADE
#       precursor (stuck URBs / UVC commit stall), while HID is still alive.
#   1 — Rebind the specific USB port (Kiyo camera)
#   2 — Full xHCI controller rebind (PCI unbind/bind)
#   3 — Full xHCI driver reload (modprobe -r / modprobe)
#
# Level 0 rationale (crash-evidence/2026-06-06-v8.1-resume-crash/): the Kiyo's
# firmware-lock precursors ("timeout: still N active urbs on EP", "Failed to set
# UVC commit control : -32") preceded "HC died" by ~14 minutes. Acting on the
# precursor lets us cycle just the camera instead of waiting for the full-bus
# cascade that takes the keyboard and mouse down with it.
#
# Install: ~/Projects/kiyo-xhci-fix/kernel-patches/install-watchdog.sh

XHCI_PCI="0000:00:14.0"
KIYO_VID="1532"
KIYO_PID="0e05"
COOLDOWN=60          # seconds between recovery attempts (from end of last recovery)
LAST_RECOVERY=0
RECOVERING=0         # re-entry guard
CONSEC_FAILS=0       # consecutive failed recoveries
GAVE_UP=0            # set to 1 after all levels fail — stops retrying
XHCI_BUILTIN=0       # set to 1 at startup if xhci_pci is compiled into the kernel
LOG_TAG="usb-watchdog"

# --- Level 0 (early intervention) config ---------------------------------
# Independent of the full-recovery cooldown so a gentle pre-cascade cycle can
# never suppress the hard "HC died" path. Set WATCHDOG_EARLY_INTERVENTION=0 to
# disable (e.g. if a precursor turns out to fire benignly on normal call-end).
EARLY_ENABLED="${WATCHDOG_EARLY_INTERVENTION:-1}"
EARLY_COOLDOWN="${WATCHDOG_EARLY_COOLDOWN:-30}"  # min seconds between gentle cycles
EARLY_LAST=0         # last early-intervention time (separate from LAST_RECOVERY)
EARLY_COUNT=0        # gentle cycles fired this run (datapoint: cascades possibly averted)

# Test mode (driven by run-hammerint.sh / matrix runner):
#   WATCHDOG_MODE=test enables forensics capture + clean exit semantics.
#   Per-cycle dmesg/lsusb dumps land in WATCHDOG_RESULTS_DIR.
#   After WATCHDOG_MAX_RECOVERIES successful recoveries, exit 0 so the
#   outer runner can move on. If recovery fails, exit 1 (don't GAVE_UP-loop).
MODE="${WATCHDOG_MODE:-normal}"
RESULTS_DIR="${WATCHDOG_RESULTS_DIR:-/tmp}"
MAX_RECOVERIES="${WATCHDOG_MAX_RECOVERIES:-3}"
TEST_CYCLE=0
TEST_START_TS=0

# Expected USB devices — recovery is not complete until these are present
declare -A EXPECTED_DEVICES=(
    ["Dygma keyboard"]="1209:2201"
    ["Logitech receiver"]="046d:c548"
)

log() { logger -t "$LOG_TAG" "$1"; echo "$(date '+%H:%M:%S') $1"; }

find_kiyo_port() {
    for dev in /sys/bus/usb/devices/*/; do
        if [ -f "$dev/idVendor" ] && \
           [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$KIYO_VID" ] && \
           [ "$(cat "$dev/idProduct" 2>/dev/null)" = "$KIYO_PID" ]; then
            basename "$dev"
            return 0
        fi
    done
    return 1
}

check_hid_alive() {
    # If any HID device has vanished from sysfs, the controller is likely wedged.
    # We can't filter by `find -name usbhid` because */driver is a symlink whose
    # *name* is "driver" — what we actually want is the symlink's target.
    local hid_count=0
    for d in /sys/bus/usb/devices/*/driver; do
        [ -L "$d" ] || continue
        case "$(readlink "$d")" in
            */usbhid) hid_count=$((hid_count + 1)) ;;
        esac
    done
    if [ "$hid_count" -lt 2 ]; then
        return 1  # fewer than 2 HID interfaces bound = likely dead
    fi
    return 0
}

check_expected_devices() {
    # Verify that ALL expected USB devices are present in sysfs
    local missing=0
    for name in "${!EXPECTED_DEVICES[@]}"; do
        local vidpid="${EXPECTED_DEVICES[$name]}"
        local vid="${vidpid%%:*}"
        local pid="${vidpid##*:}"
        local found=0
        for dev in /sys/bus/usb/devices/*/; do
            if [ -f "$dev/idVendor" ] && \
               [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$vid" ] && \
               [ "$(cat "$dev/idProduct" 2>/dev/null)" = "$pid" ]; then
                found=1
                break
            fi
        done
        if [ "$found" -eq 0 ]; then
            log "HEALTH: $name ($vidpid) NOT found"
            missing=$((missing + 1))
        fi
    done
    return "$missing"
}

dump_crash_log() {
    local logfile="/tmp/usb-watchdog-crash-$(date '+%Y%m%d-%H%M%S').log"
    {
        echo "=== USB Watchdog Crash Dump ==="
        echo "Timestamp: $(date)"
        echo ""
        echo "=== Last 50 lines of dmesg ==="
        # kernel.dmesg_restrict=1 (default on most modern distros) blocks
        # unprivileged dmesg reads. Try sudo first (passwordless via the
        # watchdog sudoers entry); fall back to bare dmesg if sudo fails.
        # Without this, every crash log records "Operation not permitted"
        # and we lose the entire kernel-side incident context.
        sudo -n dmesg 2>/dev/null | tail -50 || dmesg 2>&1 | tail -50
        echo ""
        echo "=== USB devices ==="
        lsusb 2>/dev/null || echo "(lsusb not available)"
        echo ""
        echo "=== HID devices in sysfs ==="
        find /sys/bus/usb/devices/*/driver -maxdepth 0 -name "usbhid" 2>/dev/null | \
            xargs -I{} dirname {} 2>/dev/null
        echo ""
        echo "=== Expected device check ==="
        for name in "${!EXPECTED_DEVICES[@]}"; do
            local vidpid="${EXPECTED_DEVICES[$name]}"
            local vid="${vidpid%%:*}"
            local pid="${vidpid##*:}"
            local status="MISSING"
            for dev in /sys/bus/usb/devices/*/; do
                if [ -f "$dev/idVendor" ] && \
                   [ "$(cat "$dev/idVendor" 2>/dev/null)" = "$vid" ] && \
                   [ "$(cat "$dev/idProduct" 2>/dev/null)" = "$pid" ]; then
                    status="PRESENT"
                    break
                fi
            done
            echo "  $name ($vidpid): $status"
        done
    } > "$logfile" 2>&1
    log "Crash log saved to $logfile"
}

health_check() {
    # Combined health check: HID alive AND expected devices present
    check_hid_alive || return 1
    check_expected_devices || return 1
    return 0
}

within_cooldown() {
    # True if we're still inside the post-recovery cooldown window.
    # Used by soft-WARNING branches to suppress stale matches that arrive in
    # journalctl's pipe after a recovery has already succeeded.
    local now
    now=$(date +%s)
    (( now - LAST_RECOVERY < COOLDOWN ))
}

# --- Test mode helpers (no-ops in normal mode) ---------------------------

test_mode_init() {
    [ "$MODE" != "test" ] && return
    mkdir -p "$RESULTS_DIR"
    TEST_START_TS=$(date +%s)
    {
        echo "=== Test mode init $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
        echo "kernel: $(uname -r)"
        echo "cmdline: $(cat /proc/cmdline)"
        echo "max_recoveries: $MAX_RECOVERIES"
        echo "xhci_pci: $XHCI_PCI"
        echo
        echo "=== Baseline lsusb ==="
        lsusb
        echo
        echo "=== Baseline xhci_hcd state ==="
        ls /sys/bus/pci/drivers/xhci_hcd/ 2>/dev/null
    } > "$RESULTS_DIR/baseline.log" 2>&1
    log "TEST MODE: results=$RESULTS_DIR max_recoveries=$MAX_RECOVERIES"
}

_test_cycle_dir() {
    printf '%s/cycle-%02d' "$RESULTS_DIR" "$TEST_CYCLE"
}

test_mode_record_event() {
    [ "$MODE" != "test" ] && return
    local trigger="$1"
    local cycle_dir
    cycle_dir="$(_test_cycle_dir)"
    mkdir -p "$cycle_dir"
    {
        echo "trigger: $trigger"
        echo "ts_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "elapsed_seconds: $(( $(date +%s) - TEST_START_TS ))"
    } > "$cycle_dir/event.log"
    # Capture dmesg since script start (best-effort — fall back to tail)
    if command -v dmesg >/dev/null; then
        dmesg --since "$(date -d "@$TEST_START_TS" '+%F %T')" \
            > "$cycle_dir/dmesg.log" 2>/dev/null \
            || dmesg | tail -300 > "$cycle_dir/dmesg.log"
    fi
    lsusb > "$cycle_dir/lsusb-pre-recover.log" 2>/dev/null
}

test_mode_after_recover() {
    [ "$MODE" != "test" ] && return
    local outcome="$1"  # ok | failed
    local cycle_dir
    cycle_dir="$(_test_cycle_dir)"
    mkdir -p "$cycle_dir"
    lsusb > "$cycle_dir/lsusb-post-recover.log" 2>/dev/null
    {
        echo "outcome: $outcome"
        echo "recover_done_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >> "$cycle_dir/event.log"

    TEST_CYCLE=$((TEST_CYCLE + 1))

    if [ "$outcome" = "failed" ]; then
        log "TEST MODE: recovery FAILED — controller wedged. Exiting."
        write_test_summary "wedged"
        exit 1
    fi

    if [ "$TEST_CYCLE" -ge "$MAX_RECOVERIES" ]; then
        log "TEST MODE: completed $TEST_CYCLE recoveries — exiting."
        write_test_summary "completed"
        exit 0
    fi
}

write_test_summary() {
    local verdict="$1"
    {
        echo "verdict: $verdict"
        echo "cycles_completed: $TEST_CYCLE"
        echo "max_recoveries: $MAX_RECOVERIES"
        echo "elapsed_seconds: $(( $(date +%s) - TEST_START_TS ))"
        echo "ended_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$RESULTS_DIR/summary.log"
}

# -------------------------------------------------------------------------

# Sentinel keeps Level 4 from firing twice in one boot (each run-of-the-script
# would otherwise re-detect the same wedge and re-spawn Claude). /tmp clears
# on reboot, so this naturally resets when JP recovers manually.
CLAUDE_SENTINEL="/tmp/usb-watchdog-claude-called"

call_claude() {
    # Last-resort escalation: all three recovery levels failed. Bundle the
    # incident, fire desktop notification, spawn a Ghostty + Claude Code
    # session pointed at the bundle so the AI can try novel recoveries
    # (port power cycle, runtime PM, PCIe relink) or at minimum produce a
    # diagnosis JP can read after rebooting.
    if [ -f "$CLAUDE_SENTINEL" ]; then
        log "LEVEL 4: sentinel exists — Claude was already called this boot. Skipping."
        return
    fi
    touch "$CLAUDE_SENTINEL"

    local ts inc
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    inc="/tmp/usb-watchdog-incident-$ts"
    mkdir -p "$inc"

    # Bundle: dmesg, lsusb, sysfs state, watchdog log
    {
        echo "=== Incident at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
        echo "kernel: $(uname -r)"
        echo "cmdline: $(cat /proc/cmdline)"
        echo "xhci_pci: $XHCI_PCI"
    } > "$inc/incident.meta"
    # dmesg requires CAP_SYS_ADMIN with kernel.dmesg_restrict=1 (default on this
    # kernel). JP has passwordless sudo, so use that.
    sudo -n dmesg 2>/dev/null | tail -500 > "$inc/dmesg.log"
    [ -s "$inc/dmesg.log" ] || dmesg 2>/dev/null | tail -500 > "$inc/dmesg.log"
    lsusb > "$inc/lsusb.log" 2>/dev/null
    {
        echo "=== /sys/bus/pci/drivers/xhci_hcd/ ==="
        ls -la /sys/bus/pci/drivers/xhci_hcd/ 2>&1
        echo
        echo "=== xhci device runtime PM ==="
        for f in /sys/bus/pci/devices/$XHCI_PCI/power/*; do
            [ -r "$f" ] || continue
            echo "$(basename $f): $(cat "$f" 2>/dev/null)"
        done
        echo
        echo "=== USB devices summary ==="
        for d in /sys/bus/usb/devices/*/; do
            if [ -f "$d/idVendor" ]; then
                printf '%s\t%s:%s\t%s\n' \
                    "$(basename $d)" \
                    "$(cat $d/idVendor)" "$(cat $d/idProduct)" \
                    "$(cat $d/product 2>/dev/null || echo '?')"
            fi
        done
    } > "$inc/sysfs.log" 2>&1
    journalctl --user -u usb-watchdog.service --since "30 minutes ago" --no-pager \
        > "$inc/watchdog.log" 2>/dev/null

    # Desktop notification — speakers may still work even with USB wedged
    if command -v notify-send >/dev/null 2>&1; then
        notify-send -u critical "USB Wedged" \
            "All recovery levels failed. Calling Claude. See $inc" 2>/dev/null
    fi

    # Build the prompt as a here-doc into a file, then pass the path to claude
    # so we don't have to escape inside a shell -c string.
    local prompt_file="$inc/prompt.md"
    cat > "$prompt_file" <<EOF
USB host controller is wedged. The watchdog tried three recovery levels and
all failed:

  Level 1 — Kiyo USB port unbind/rebind
  Level 2 — xHCI PCI device unbind/rebind
  Level 3 — \`modprobe -r xhci_pci xhci_pci_renesas\` and re-load

Goal: try novel recoveries that don't require a reboot. Possibilities to
explore (in roughly increasing aggressiveness):

  - Toggle individual USB port power via /sys/bus/usb/devices/X/authorized
  - Force runtime PM cycle on the xHCI device
    (/sys/bus/pci/devices/$XHCI_PCI/power/control)
  - PCIe link retrain or device-level reset via
    /sys/bus/pci/devices/$XHCI_PCI/reset (if exposed)
  - Remove + rescan the PCI device:
    echo 1 > /sys/bus/pci/devices/$XHCI_PCI/remove
    echo 1 > /sys/bus/pci/rescan

Strict constraints:
  - DO NOT reboot or schedule a reboot.
  - DO NOT touch any disk-related path (/dev/sd*, /dev/nvme*, mount, fs).
  - This is the kiyo-xhci-fix project; you're allowed full access there.
  - JP's keyboard is most likely USB and currently dead — work autonomously.
    Use mcp__speech-to-cli__speak (voice Davis, hd) to narrate progress so
    JP can hear what you're doing.

Incident bundle (read these first):
  $inc/incident.meta
  $inc/dmesg.log         (last 500 lines of dmesg)
  $inc/lsusb.log
  $inc/sysfs.log
  $inc/watchdog.log

When done, write a verdict file at:
  $inc/claude-verdict.md

The verdict should include: what was tried, what worked or didn't, your
best diagnosis of root cause, and what to put in the LKML reply to Michal
Pecio (he's expecting hammerint test results — this wedge IS the result).

Project context: $HOME/Projects/kiyo-xhci-fix (read CLAUDE.md there).
EOF

    log "LEVEL 4: bundled incident at $inc"

    # Generate a tiny launcher script — avoids the shell-quoting trap of
    # passing a multi-paragraph prompt through `bash -c`.
    # We deliberately do NOT `exec claude`: when claude exits we want to
    # keep the terminal alive so JP can still read the verdict and the
    # incident path after the session ends, instead of having the Ghostty
    # window auto-close.
    local launcher="$inc/launch-claude.sh"
    cat > "$launcher" <<EOF
#!/bin/bash
cd "\$HOME/Projects/kiyo-xhci-fix" || exit
claude --dangerously-skip-permissions "\$(cat '$prompt_file')"
echo
echo "============================================================"
echo "Claude session ended. Incident bundle: $inc"
echo "Verdict (if written): $inc/claude-verdict.md"
echo "Window will stay open. Type 'exit' (or close it manually) to dismiss."
echo "============================================================"
exec bash
EOF
    chmod +x "$launcher"

    # Spawn Ghostty + launcher fully detached.
    #
    # CRITICAL: ghostty runs as a GTK single-instance app
    # (--gtk-single-instance=true). Plain `snap run ghostty -e CMD` delivers
    # the -e argument to the existing instance, which can REPLACE the
    # currently-focused window's shell with CMD instead of opening a new
    # window. Use the `+new-window` action to force a fresh window.
    #
    # We also `setsid -f` so the spawned process is in its own session and
    # process group — so a SIGHUP to the watchdog (or its parent shell)
    # cannot propagate to the Ghostty window.
    log "LEVEL 4: spawning claude in ghostty (+new-window)"
    setsid -f snap run ghostty +new-window -e "$launcher" \
        </dev/null >/dev/null 2>&1 || \
        log "LEVEL 4: WARN — ghostty spawn returned non-zero (window may have failed)"

    log "LEVEL 4: Claude session spawned (incident=$inc). Watchdog will not retry until reboot."
}

early_intervene() {
    # Level 0 — gentle, pre-cascade Kiyo-only port cycle. Triggered by the
    # documented precursors to the firmware-lock -> xHCI cascade BEFORE the host
    # controller dies (see header + crash-evidence/2026-06-06).
    #
    # Safety invariants that make this low-risk to run on a live precursor:
    #   - Touches ONLY the Kiyo. The keyboard/mouse (the EXPECTED_DEVICES that
    #     health_check guards) are never cycled, so health stays green and the
    #     -19/-110/uvcvideo "|| recover" branches won't escalate during it.
    #   - Has its OWN cooldown (EARLY_LAST/EARLY_COOLDOWN) and NEVER writes
    #     LAST_RECOVERY/GAVE_UP/RECOVERING — so it cannot delay or suppress the
    #     hard "HC died" recovery if the cascade proceeds anyway.
    #   - Respects the full-recovery cooldown (within_cooldown): right after a
    #     real recovery, journalctl replays the crash's precursor lines; we must
    #     not cycle the Kiyo on those stale matches.
    #
    # Intentional tradeoff: a precursor that fires mid-call blips the camera for
    # a few seconds. That is far cheaper than the alternative — the whole USB bus
    # (keyboard + mouse) dying ~14 minutes later.
    local trigger="${1:-precursor}"

    [ "$EARLY_ENABLED" = "1" ] || return
    [ "$MODE" = "test" ] && return
    [ "$RECOVERING" -eq 1 ] && return
    [ "$GAVE_UP" -eq 1 ] && return
    within_cooldown && return   # just recovered — ignore stale replayed precursors

    local now
    now=$(date +%s)
    if (( now - EARLY_LAST < EARLY_COOLDOWN )); then
        return  # rate-limit gentle cycles independently of full recovery
    fi

    local port
    port=$(find_kiyo_port)
    if [ -z "$port" ]; then
        # Kiyo already gone — cascade may be underway. Nothing to cycle, and we
        # deliberately DON'T arm EARLY_LAST, so the hard paths stay free to act.
        log "EARLY: precursor ($trigger) but Kiyo absent — deferring to recovery paths"
        return
    fi

    EARLY_LAST=$now
    EARLY_COUNT=$((EARLY_COUNT + 1))
    log "EARLY #$EARLY_COUNT: $trigger — cycling Kiyo port $port (pre-cascade; HID untouched)"

    echo "$port" | sudo tee /sys/bus/usb/drivers/usb/unbind >/dev/null 2>&1
    sleep 2
    echo "$port" | sudo tee /sys/bus/usb/drivers/usb/bind >/dev/null 2>&1
    sleep 3

    if find_kiyo_port >/dev/null; then
        log "EARLY #$EARLY_COUNT OK: Kiyo re-enumerated after gentle cycle — cascade hopefully averted"
    else
        log "EARLY #$EARLY_COUNT: Kiyo did not return after cycle — watching for cascade (HC-died path still armed)"
    fi
}

recover() {
    # Trigger reason from caller (for log + test record). Empty if caller didn't pass one.
    local trigger="${1:-unspecified}"

    # Prevent re-entry — recovery generates kernel messages that match our patterns
    if [ "$RECOVERING" -eq 1 ]; then
        return
    fi

    local now
    now=$(date +%s)
    if (( now - LAST_RECOVERY < COOLDOWN )); then
        return  # silent skip during cooldown — stale post-recovery matches land here
    fi

    if [ "$GAVE_UP" -eq 1 ]; then
        return  # all levels exhausted — don't hammer a wedged controller
    fi

    RECOVERING=1
    LAST_RECOVERY=$now

    # Log FATAL only after we've cleared cooldown/GAVE_UP — keeps the log honest
    # when stale "HC died" lines arrive after a successful recovery.
    log "FATAL: $trigger — initiating recovery"
    test_mode_record_event "$trigger"

    # Save crash context
    dump_crash_log

    # Level 1: Try to reset just the Kiyo's USB port
    local port
    port=$(find_kiyo_port)
    if [ -n "$port" ]; then
        log "LEVEL 1: Unbinding Kiyo port $port..."
        echo "$port" | sudo tee /sys/bus/usb/drivers/usb/unbind >/dev/null 2>&1
        sleep 2
        echo "$port" | sudo tee /sys/bus/usb/drivers/usb/bind >/dev/null 2>&1
        sleep 3

        if health_check; then
            log "LEVEL 1 OK: All devices alive after port rebind"
            LAST_RECOVERY=$(date +%s); RECOVERING=0; CONSEC_FAILS=0
            test_mode_after_recover ok
            return
        fi
    fi

    # Level 2: Full xHCI controller rebind (single attempt — retries make wedged controllers worse)
    log "LEVEL 2: Full xHCI rebind ($XHCI_PCI)..."
    echo "$XHCI_PCI" | sudo tee /sys/bus/pci/drivers/xhci_hcd/unbind >/dev/null 2>&1
    sleep 5
    echo "$XHCI_PCI" | sudo tee /sys/bus/pci/drivers/xhci_hcd/bind >/dev/null 2>&1
    sleep 10

    if health_check; then
        log "LEVEL 2 OK: All devices alive after xHCI rebind"
        LAST_RECOVERY=$(date +%s); RECOVERING=0; CONSEC_FAILS=0
        test_mode_after_recover ok
        return
    fi

    # Level 3: Full xHCI driver reload (single attempt)
    # Only viable if xhci_pci is a loadable module. On Ubuntu HWE kernels it's
    # builtin, so modprobe -r fails with "Module is builtin" and modprobe is a
    # no-op — falsely reporting "LEVEL 3 OK" while the kernel's own hub-driver
    # port power-cycle was actually doing the rescue. When builtin, give L2 more
    # time to settle instead.
    if [ "$XHCI_BUILTIN" -eq 1 ]; then
        log "LEVEL 3 SKIPPED: xhci is builtin to kernel — extending L2 settle wait"
        sleep 15
        if health_check; then
            log "LEVEL 2+ OK: All devices alive after extended settle wait"
            LAST_RECOVERY=$(date +%s); RECOVERING=0; CONSEC_FAILS=0
            test_mode_after_recover ok
            return
        fi
    else
        log "LEVEL 3: Full driver reload..."
        sudo /sbin/modprobe -r xhci_pci xhci_pci_renesas 2>&1 | while read -r l; do log "modprobe-r: $l"; done
        sleep 3
        sudo /sbin/modprobe xhci_pci xhci_pci_renesas 2>&1 | while read -r l; do log "modprobe: $l"; done
        sleep 12

        if health_check; then
            log "LEVEL 3 OK: All devices alive after driver reload"
            LAST_RECOVERY=$(date +%s); RECOVERING=0; CONSEC_FAILS=0
            test_mode_after_recover ok
            return
        fi
    fi

    # All levels exhausted — STOP, don't retry. Controller is wedged, needs reboot.
    log "ALL LEVELS FAILED — controller is wedged. Stopping recovery to prevent cascade."
    dump_crash_log

    # Level 4: hand off to Claude for novel-recovery / diagnosis. One-shot.
    call_claude

    log "ACTION REQUIRED: Reboot to restore USB if Claude doesn't recover."
    LAST_RECOVERY=$(date +%s)
    RECOVERING=0
    GAVE_UP=1
    test_mode_after_recover failed   # exits 1 in test mode; no-op in normal mode
}

log "Started — watching for xHCI lockups on $XHCI_PCI (mode=$MODE)"
log "Expected devices:"
for name in "${!EXPECTED_DEVICES[@]}"; do
    log "  $name: ${EXPECTED_DEVICES[$name]}"
done

# Detect whether xhci is builtin (affects Level 3 recovery strategy).
# `lsmod` only lists loadable modules. If neither xhci_pci nor xhci_hcd shows up
# but the controller is clearly working, the driver is compiled in.
if ! lsmod 2>/dev/null | grep -qE '^xhci_(pci|hcd)\b'; then
    XHCI_BUILTIN=1
    log "NOTE: xhci is builtin to this kernel — LEVEL 3 (modprobe reload) will be replaced with extended L2 settle wait"
fi

# Initial health check
if health_check; then
    log "Initial health check PASSED — all expected devices present"
else
    log "Initial health check WARNING — some expected devices missing (see above)"
fi

test_mode_init

# Watch kernel log for fatal USB/xHCI error patterns.
#
# The FATAL log line is emitted INSIDE recover() (after cooldown/GAVE_UP checks)
# rather than here in the case branch, so we don't leave misleading "FATAL"
# entries in the log when stale matching lines arrive after a recovery.
#
# ROBUSTNESS (2026-05-30): the detector must NEVER depend solely on the log
# feed. The previous form — `journalctl -k -f | while read -r line` — blocked
# forever on an empty pipe (`anon_pipe_read`) whenever the feed went silent
# (journald hiccup, log rotation, or the kernel log going quiet as the HC
# dies). The watchdog stayed "running" in `ps` but was deaf, and EVERY recovery
# path lives behind that read, so a real HC death went unhandled for 19 min.
# Two defenses, so neither failure mode can blind us again:
#   1) `read -t $POLL_INTERVAL` — a quiet feed now wakes us on a fixed cadence
#      to run an INDEPENDENT health poll (event-driven AND polling).
#   2) Persistent FD via process substitution + EOF respawn — if journalctl
#      EXITS (rc<=128) we reopen the feed instead of falling off the end of the
#      script and dying. A read timeout (rc>128) leaves journalctl running.
# A 2-poll debounce keeps an intentional device unplug from forcing a rebind.
POLL_INTERVAL="${WATCHDOG_POLL_INTERVAL:-15}"
poll_degraded=0

open_feed() {
    # (Re)open the kernel-log follow on FD 3. Closing+reopening makes the old
    # journalctl see EOF on its next write and exit.
    exec 3<&- 2>/dev/null
    exec 3< <(journalctl -k -f --no-pager 2>/dev/null)
}
open_feed

while true; do
    # Capture read's exit code DIRECTLY — `rc=$?` after the `fi` would read the
    # `if` statement's status (0 when the condition is false with no else),
    # misclassifying every timeout as EOF and respawning journalctl on a loop.
    if read -r -t "$POLL_INTERVAL" -u 3 line; then rc=0; else rc=$?; fi
    if [ "$rc" -eq 0 ]; then
        poll_degraded=0   # a line arrived → feed is alive
        case "$line" in
            *"HC died"*|*"Host System Error"*|*"host system error"*)
                recover "xHCI host controller died (HC died/HSE)"
                ;;
            *"xHCI host not responding"*|*"xhci_hcd"*"not responding to stop"*)
                recover "xHCI not responding"
                ;;
            *"timeout"*"active urbs on EP"*)
                # LEVEL 0 PRECURSOR — earliest signal. In the 2026-06-06 crash,
                # "usb 2-3: timeout: still 12 active urbs on EP #82" (iso video
                # endpoint) fired ~4s before the UVC commit stall and ~14 min
                # before HC died. Cycle the Kiyo now, while HID is still alive.
                [ "$MODE" = "test" ] && continue
                early_intervene "stuck URBs on endpoint"
                ;;
            *"Failed to set UVC commit control"*)
                # LEVEL 0 PRECURSOR — UVC commit-control stall (-32/-110/-108).
                # NOTE: the older "*uvcvideo*error -32*" branch below never
                # matched this — the kernel prints "...commit control : -32",
                # NOT "error -32" (this gap let the 06-06 precursor slip past).
                # A healthy camera never fails this, so one occurrence is enough.
                # DO NOT widen this to "Failed to set UVC probe control": that
                # line fires on EVERY enumeration of this camera (-32, exp. 26)
                # with the device healthy — benign per-probe artifact, not a
                # precursor (verified 2026-06-10 across three enumerations).
                [ "$MODE" = "test" ] && continue
                early_intervene "UVC commit-control stall"
                ;;
            *"Cannot set alt interface"*"ret = -19"*|*"usb_set_interface failed"*"-19"*)
                # -19 = ENODEV, device gone mid-transfer.
                # Skip in test mode — this is expected noise during hammerint and
                # would cause spurious recoveries. We only act on hard HC death.
                [ "$MODE" = "test" ] && continue
                # Suppress during cooldown — stale matches from a just-recovered crash.
                within_cooldown && continue
                log "WARNING: USB device gone (-19) — checking health"
                sleep 2
                health_check || recover "USB device gone (-19) + health degraded"
                ;;
            *"device descriptor read"*"error -110"*|*"device not accepting address"*"error -110"*)
                # -110 = ETIMEDOUT, controller may be wedging.
                # Same skip rationale as -19 above.
                [ "$MODE" = "test" ] && continue
                within_cooldown && continue
                log "WARNING: USB timeout (-110) — checking health"
                sleep 5
                health_check || recover "USB timeout (-110) + health degraded"
                ;;
            *"uvcvideo"*"error -71"*|*"uvcvideo"*"error -32"*)
                # UVC protocol/pipe errors — camera crashing.
                # Hammerint never goes through uvcvideo, so any uvcvideo line
                # during the test is unrelated noise.
                [ "$MODE" = "test" ] && continue
                within_cooldown && continue
                log "WARNING: UVC error on camera — monitoring for cascade"
                sleep 5
                health_check || recover "uvcvideo cascade after -71/-32"
                ;;
            *"USB disconnect"*"$XHCI_PCI"*)
                # Mass disconnect event on our controller
                sleep 2
                health_check || recover "mass USB disconnect on $XHCI_PCI"
                ;;
        esac
        continue
    fi

    if [ "$rc" -gt 128 ]; then
        # read timed out: feed quiet for POLL_INTERVAL. journalctl is still
        # running — this is the deadlock safety net. Poll health directly.
        [ "$MODE" = "test" ] && continue
        within_cooldown && continue
        if health_check; then
            poll_degraded=0
        else
            poll_degraded=$((poll_degraded + 1))
            log "POLL: health degraded ($poll_degraded/2) — log feed silent ${POLL_INTERVAL}s"
            if [ "$poll_degraded" -ge 2 ]; then
                recover "periodic poll: expected devices missing + feed silent (deadlock-safe path)"
                poll_degraded=0
            fi
        fi
        continue
    fi

    # rc <= 128 → EOF: journalctl exited. Respawn the feed rather than die.
    log "WARNING: kernel log feed ended (rc=$rc) — restarting journalctl follow"
    sleep 2
    open_feed
done
