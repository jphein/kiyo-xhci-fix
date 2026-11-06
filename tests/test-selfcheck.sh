#!/bin/bash
# Offline tests for kiyo-selfcheck against fixture trees + command shims.
# Each case builds a katana-shaped PASS fixture, breaks one layer, and asserts
# the verdict AND the check line that names it. Fixtures live under the repo's
# tmp/ (disk), never /tmp, so the capture-dir check sees a real ext4 and the
# tmpfs case can be exercised explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
mkdir -p "$ROOT/tmp"
T="$(mktemp -d "$ROOT/tmp/selfcheck-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "  [ok]   $1"; }
bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }

# ---------- shims (found first on PATH) ----------
SHIM="$T/shim"; mkdir -p "$SHIM"
cat > "$SHIM/uname" <<'S'
#!/bin/bash
[ "${1:-}" = "-r" ] && { echo "${FX_KVER:-7.0.0-38-generic}"; exit 0; }
exec /usr/bin/uname "$@"
S
cat > "$SHIM/systemctl" <<'S'
#!/bin/bash
# systemctl [--user] is-active|is-enabled <unit>  -> state from $FX_UNITS/<scope>/<unit> ("active enabled")
scope=system; [ "${1:-}" = "--user" ] && { scope=user; shift; }
verb="$1"; unit="$2"; f="$FX_UNITS/$scope/$unit"
[ -f "$f" ] || { echo inactive; exit 1; }
read -r act en < "$f"
case "$verb" in
  is-active)  echo "$act"; [ "$act" = active ] ;;
  is-enabled) echo "$en";  [ "$en" = enabled ] ;;
  *) exit 1 ;;
esac
S
cat > "$SHIM/modinfo" <<'S'
#!/bin/bash
# modinfo -F srcversion <ko>  -> sidecar <ko>.srcversion
[ "$1" = "-F" ] && [ "$2" = "srcversion" ] && { cat "$3.srcversion"; exit 0; }
exit 1
S
cat > "$SHIM/notify-send" <<'S'
#!/bin/bash
echo "notify-send $*" >> "$FX_NOTIFY"
S
cat > "$SHIM/hostname" <<'S'
#!/bin/bash
echo fixturehost
S
chmod +x "$SHIM"/*

# ---------- fixture builder: katana-shaped, everything PASS ----------
build_fixture() {   # build_fixture <dir>
    local fx="$1" sys dev
    sys="$fx/sys"
    mkdir -p "$sys/module/uvcvideo" "$sys/module/usbcore/parameters" "$sys/bus/usb/devices" \
             "$fx/proc" "$fx/lib/modules/7.0.0-38-generic/updates/dkms" "$fx/lib/modules/7.0.0-42-generic/updates/dkms" \
             "$fx/boot" "$fx/etc/udev/rules.d" "$fx/etc/sudoers.d" "$fx/run" "$fx/var/log/journal" \
             "$fx/units/user" "$fx/units/system" "$fx/state"
    echo E2EBD0A2BE4DB9E11A6893D > "$sys/module/uvcvideo/srcversion"
    echo > "$sys/module/usbcore/parameters/quirks"
    echo "BOOT_IMAGE=/boot/vmlinuz-7.0.0-38-generic root=UUID=x ro quiet" > "$fx/proc/cmdline"
    for k in 7.0.0-38-generic 7.0.0-42-generic; do
        : > "$fx/lib/modules/$k/updates/dkms/uvcvideo.ko.zst"
        echo E2EBD0A2BE4DB9E11A6893D > "$fx/lib/modules/$k/updates/dkms/uvcvideo.ko.zst.srcversion"
        : > "$fx/boot/vmlinuz-$k"
    done
    : > "$fx/etc/udev/rules.d/99-razer-kiyo-pro.rules"
    : > "$fx/etc/sudoers.d/usb-watchdog"
    for u in usb-watchdog call-watch scarlett-storm-guard; do echo "active enabled" > "$fx/units/user/$u"; done
    echo "inactive enabled" > "$fx/units/system/usb3-no-lpm"
    # root hub ports with permit=0
    for n in 1 2 3; do mkdir -p "$sys/bus/usb/devices/2-0:1.0/usb2-port$n"; echo 0 > "$sys/bus/usb/devices/2-0:1.0/usb2-port$n/usb3_lpm_permit"; done
    # the Kiyo at 2-1.4: SS, quirks 0x410 (NO_LPM + RESET), no lpm attrs, a video node
    dev="$sys/bus/usb/devices/2-1.4"; mkdir -p "$dev/power" "$dev/2-1.4:1.0/video4linux/video0"
    echo 1532 > "$dev/idVendor"; echo 0e05 > "$dev/idProduct"; echo 5000 > "$dev/speed"; echo 0x410 > "$dev/quirks"
}

run_sc() {   # run_sc <fixture> [args]  -> stdout in $OUT, rc in $RC
    local fx="$1"; shift
    OUT=$(PATH="$SHIM:$PATH" FX_KVER="${FX_KVER:-7.0.0-38-generic}" FX_UNITS="$fx/units" FX_NOTIFY="$fx/notify.log" \
          KIYO_SYSFS="$fx/sys" SELFCHECK_PROC="$fx/proc" SELFCHECK_MODULES="$fx/lib/modules" SELFCHECK_BOOT="$fx/boot" \
          SELFCHECK_ETC="$fx/etc" SELFCHECK_RUN="$fx/run" SELFCHECK_VARLOG="$fx/var/log" KIYO_STATE_ROOT="$fx/state" \
          KIYO_PROJECT_DIR="$fx/project" "$ROOT/kiyo-selfcheck" "$@" 2>&1); RC=$?
}
expect_rc()   { [ "$RC" -eq "$1" ] && ok "$2 → exit $RC" || { bad "$2 → exit $RC (want $1)"; echo "$OUT" | sed 's/^/        /'; }; }
expect_line() { echo "$OUT" | grep -qE "$1" && ok "line: $1" || { bad "missing line: $1"; echo "$OUT" | sed 's/^/        /'; }; }

echo "T1 all green (katana-shaped, Kiyo plugged in)"
fx="$T/t1"; build_fixture "$fx"; run_sc "$fx"
expect_rc 0 "PASS tree"; expect_line '^RESULT: PASS'; expect_line '^PASS  kiyo-quirk\[2-1.4\].*0x410'; expect_line '^PASS  kiyo-lpm\[2-1.4\].*absent'; expect_line '^PASS  port-lpm-block.*3 ports'; expect_line '^PASS  nolpm-not-cancelled'

echo "T2 the XOR cancel: usbcore.quirks=1532:0e05:k live on a 7.x kernel"
fx="$T/t2"; build_fixture "$fx"; echo "1532:0e05:k" > "$fx/sys/module/usbcore/parameters/quirks"; sed -i 's/ro quiet/ro usbcore.quirks=1532:0e05:k quiet/' "$fx/proc/cmdline"; run_sc "$fx"
expect_rc 1 "XOR cancel"; expect_line '^FAIL  nolpm-not-cancelled.*XOR-toggles the in-tree NO_LPM OFF'

echo "T2b runtime cleared, cmdline still carries it → WARN only"
fx="$T/t2b"; build_fixture "$fx"; sed -i 's/ro quiet/ro usbcore.quirks=1532:0e05:k quiet/' "$fx/proc/cmdline"; run_sc "$fx"
expect_rc 0 "runtime cleared"; expect_line '^WARN  nolpm-not-cancelled.*cmdline still carries'

echo "T2c a different device's quirk in the list is not a cancel"
fx="$T/t2c"; build_fixture "$fx"; echo "05e3:0612:k" > "$fx/sys/module/usbcore/parameters/quirks"; run_sc "$fx"
expect_rc 0 "other device"; expect_line '^PASS  nolpm-not-cancelled'

echo "T3 loaded module != DKMS on disk"
fx="$T/t3"; build_fixture "$fx"; echo 7CD08F45STOCK > "$fx/sys/module/uvcvideo/srcversion"; run_sc "$fx"
expect_rc 1 "srcversion mismatch"; expect_line '^FAIL  dkms-running-kernel.*7CD08F45STOCK != DKMS on disk E2EBD0A2'

echo "T4 one port still permits LPM while usb3-no-lpm is enabled"
fx="$T/t4"; build_fixture "$fx"; echo u1_u2 > "$fx/sys/bus/usb/devices/2-0:1.0/usb2-port3/usb3_lpm_permit"; run_sc "$fx"
expect_rc 1 "permit u1_u2"; expect_line '^FAIL  port-lpm-block.*usb2-port3/usb3_lpm_permit=u1_u2'

echo "T4b block unit not installed → info, not a failure"
fx="$T/t4b"; build_fixture "$fx"; rm "$fx/units/system/usb3-no-lpm"; echo u1_u2 > "$fx/sys/bus/usb/devices/2-0:1.0/usb2-port3/usb3_lpm_permit"; run_sc "$fx"
expect_rc 0 "no block unit"; expect_line '^info  port-lpm-block.*not enabled'

echo "T5 call-watch inactive"
fx="$T/t5"; build_fixture "$fx"; echo "inactive enabled" > "$fx/units/user/call-watch"; run_sc "$fx"
expect_rc 1 "unit inactive"; expect_line '^FAIL  unit\[call-watch\].*inactive, enabled'

echo "T6 reboot pending → WARN, still PASS"
fx="$T/t6"; build_fixture "$fx"; : > "$fx/run/reboot-required"; echo linux-image-7.0.0-42-generic > "$fx/run/reboot-required.pkgs"; run_sc "$fx"
expect_rc 0 "reboot pending"; expect_line '^WARN  reboot-pending.*linux-image-7.0.0-42-generic'

echo "T7 the next kernel has no DKMS build"
fx="$T/t7"; build_fixture "$fx"; rm -r "$fx/lib/modules/7.0.0-42-generic/updates"; run_sc "$fx"
expect_rc 1 "missing dkms"; expect_line '^FAIL  dkms-all-kernels.*7.0.0-42-generic'

echo "T8 camera enumerated LPM-capable (quirk missing), u1 enabled"
fx="$T/t8"; build_fixture "$fx"; d="$fx/sys/bus/usb/devices/2-1.4"; echo 0x10 > "$d/quirks"; echo enabled > "$d/power/usb3_hardware_lpm_u1"; echo enabled > "$d/power/usb3_hardware_lpm_u2"; run_sc "$fx"
expect_rc 1 "lpm capable"; expect_line '^FAIL  kiyo-quirk\[2-1.4\].*quirks=0x10 lacks NO_LPM'; expect_line '^FAIL  kiyo-lpm\[2-1.4\].*u1=enabled'

echo "T8b camera at USB2 fallback, no video node"
fx="$T/t8b"; build_fixture "$fx"; d="$fx/sys/bus/usb/devices/2-1.4"; echo 480 > "$d/speed"; rm -r "$d/2-1.4:1.0"; run_sc "$fx"
expect_rc 1 "usb2 + no node"; expect_line '^FAIL  kiyo-link\[2-1.4\].*speed=480'; expect_line '^FAIL  kiyo-video\[2-1.4\].*no video node'

echo "T9 no Kiyo plugged in → device checks skipped, PASS"
fx="$T/t9"; build_fixture "$fx"; rm -r "$fx/sys/bus/usb/devices/2-1.4"; run_sc "$fx"
expect_rc 0 "no camera"; expect_line '^info  kiyo-device.*no Kiyo plugged in'

echo "T10 --log on a FAIL tree: history line, last.txt, FAIL file, one notification"
fx="$T/t10"; build_fixture "$fx"; echo "inactive disabled" > "$fx/units/user/usb-watchdog"; mkdir -p "$fx/project"; run_sc "$fx" --log
expect_rc 1 "--log FAIL"
[ -f "$fx/project/scratch/selfcheck/fixturehost.log" ] && grep -q 'RESULT: FAIL' "$fx/project/scratch/selfcheck/fixturehost.log" && ok "history line written" || bad "history line missing"
[ -f "$fx/project/scratch/selfcheck/fixturehost-last.txt" ] && ok "last.txt written" || bad "last.txt missing"
ls "$fx/project/scratch/selfcheck"/FAIL-fixturehost-*.txt >/dev/null 2>&1 && ok "FAIL file written" || bad "FAIL file missing"
[ "$(grep -c '^notify-send' "$fx/notify.log" 2>/dev/null)" = "1" ] && ok "exactly one notify-send" || bad "notify-send count: $(grep -c '^notify-send' "$fx/notify.log" 2>/dev/null)"
run_sc "$fx" --log   # same failure again → logged, not re-notified
[ "$(grep -c '^notify-send' "$fx/notify.log" 2>/dev/null)" = "1" ] && ok "same FAIL set again: no second notification" || bad "re-notified an unchanged FAIL set"
[ "$(grep -c 'RESULT: FAIL' "$fx/project/scratch/selfcheck/fixturehost.log")" = "2" ] && ok "but both runs are in the history" || bad "history missing a run"
echo "inactive enabled" > "$fx/units/user/call-watch"; run_sc "$fx" --log   # a NEW failure joins → notify again
[ "$(grep -c '^notify-send' "$fx/notify.log" 2>/dev/null)" = "2" ] && ok "a changed FAIL set notifies again" || bad "changed FAIL set not notified"

echo "T10b --log on a PASS tree: history line, no FAIL file, no notification"
fx="$T/t10b"; build_fixture "$fx"; mkdir -p "$fx/project"; run_sc "$fx" --log
expect_rc 0 "--log PASS"
grep -q 'RESULT: PASS' "$fx/project/scratch/selfcheck/fixturehost.log" && ok "history line written" || bad "history line missing"
ls "$fx/project/scratch/selfcheck"/FAIL-* >/dev/null 2>&1 && bad "FAIL file written on PASS" || ok "no FAIL file"
[ -e "$fx/notify.log" ] && bad "notification on PASS" || ok "no notification"

echo "T11 kernel 6.x without the parameter → FAIL (it was needed there)"
fx="$T/t11"; build_fixture "$fx"; mv "$fx/lib/modules/7.0.0-38-generic" "$fx/lib/modules/6.17.0-35-generic"; mv "$fx/boot/vmlinuz-7.0.0-38-generic" "$fx/boot/vmlinuz-6.17.0-35-generic"; FX_KVER=6.17.0-35-generic run_sc "$fx"
expect_rc 1 "6.x no param"; expect_line '^FAIL  nolpm-not-cancelled.*predates the in-tree quirk'

echo "T12 capture dir on tmpfs"
fx="$T/t12"; build_fixture "$fx"; tfs="$(mktemp -d /tmp/kiyo-sc-tmpfs.XXXX)"
OUT=$(PATH="$SHIM:$PATH" FX_UNITS="$fx/units" KIYO_SYSFS="$fx/sys" SELFCHECK_PROC="$fx/proc" SELFCHECK_MODULES="$fx/lib/modules" SELFCHECK_BOOT="$fx/boot" SELFCHECK_ETC="$fx/etc" SELFCHECK_RUN="$fx/run" SELFCHECK_VARLOG="$fx/var/log" KIYO_STATE_ROOT="$tfs" KIYO_PROJECT_DIR="$fx/project" "$ROOT/kiyo-selfcheck" 2>&1); RC=$?; rm -rf "$tfs"
if [ "$(stat -f -c %T /tmp)" = tmpfs ]; then expect_rc 1 "tmpfs capture dir"; expect_line '^FAIL  capture-dir.*tmpfs'; else ok "(skipped: /tmp is not tmpfs on this host)"; fi

echo "T13 usage"
run_sc "$T/t1" --bogus; expect_rc 2 "bad flag"

echo; echo "fail=$fail"
[ "$fail" -eq 0 ]
