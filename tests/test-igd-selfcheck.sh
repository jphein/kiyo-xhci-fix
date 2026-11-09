#!/bin/bash
# Offline tests for katana-av/igd/igd-selfcheck + brave-vaapi against a fixture sysfs/dri tree and
# vainfo/dpkg-query shims. Pins: today's state (iGPU off) FAILs with the BIOS hint; a good iGPU PASSes;
# iGPU as primary display FAILs; iHD without H.264 encode FAILs; the wrapper only adds VA-API when the
# Intel node exists, and adds nothing otherwise.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
mkdir -p "$ROOT/tmp"
T="$(mktemp -d "$ROOT/tmp/igd-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "  [ok]   $1"; }
bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }

SHIM="$T/shim"; mkdir -p "$SHIM"
cat > "$SHIM/vainfo" <<'S'
#!/bin/bash
cat "$FX/vainfo"
S
cat > "$SHIM/dpkg-query" <<'S'
#!/bin/bash
case "$*" in
  *Status*intel-media-va-driver) [ -f "$FX/ihd" ] && printf 'install ok installed' ;;
  *Version*intel-media-va-driver) printf '26.1.2+dfsg1-1' ;;
esac
S
chmod +x "$SHIM"/*

build() {   # build <dir> [on]
    local fx="$1"; mkdir -p "$fx/sys/bus/pci/devices" "$fx/dri/by-path" "$fx/sys/bus/pci/drivers/i915" "$fx/home"
    : > "$fx/ihd"
    [ "${2:-}" = on ] || return 0
    local d="$fx/sys/bus/pci/devices/0000:00:02.0"; mkdir -p "$d"
    echo 0x8086 > "$d/vendor"; echo 0x3e98 > "$d/device"; echo 0 > "$d/boot_vga"
    ln -s ../../drivers/i915 "$d/driver"
    : > "$fx/dri/renderD129"; ln -s ../renderD129 "$fx/dri/by-path/pci-0000:00:02.0-render"
    printf '      VAProfileH264Main               :\tVAEntrypointEncSlice\n      VAProfileH264High               :\tVAEntrypointEncSlice\n      VAProfileVP9Profile0            :\tVAEntrypointEncSliceLP\n' > "$fx/vainfo"
}
run_sc() { OUT=$(PATH="$SHIM:$PATH" FX="$1" HOME="$1/home" IGD_SYSFS="$1/sys" IGD_DEV="$1/dri" "$ROOT/katana-av/igd/igd-selfcheck" 2>&1); RC=$?; }

echo "G1 today: iGPU off in the BIOS → FAIL naming the BIOS setting"
fx="$T/g1"; build "$fx"; run_sc "$fx"
[ "$RC" = 1 ] && echo "$OUT" | grep -q "^FAIL  igd-present.*IGD Multi-Monitor = Enabled" && ok "FAIL with the BIOS hint" || { bad "rc=$RC"; echo "$OUT"; }

echo "G2 iGPU on, i915, NVIDIA primary, iHD encodes H.264 → PASS (launcher WARN until igd-enable)"
fx="$T/g2"; build "$fx" on; run_sc "$fx"
[ "$RC" = 0 ] && ok "exit 0" || { bad "rc=$RC"; echo "$OUT"; }
echo "$OUT" | grep -q "^PASS  va-encode.*H264Main/EncSlice" && ok "H.264 encode entrypoint seen" || bad "$(echo "$OUT" | grep va-encode)"
echo "$OUT" | grep -q "^WARN  brave-launcher" && ok "launcher WARN before enable" || bad "$(echo "$OUT" | grep launcher)"

echo "G3 BIOS made the iGPU the primary display → FAIL"
fx="$T/g3"; build "$fx" on; echo 1 > "$fx/sys/bus/pci/devices/0000:00:02.0/boot_vga"; run_sc "$fx"
[ "$RC" = 1 ] && echo "$OUT" | grep -q "^FAIL  primary-gpu" && ok "primary-gpu FAIL" || { bad "rc=$RC"; echo "$OUT"; }

echo "G4 iHD present but no H.264 encode entrypoint → FAIL"
fx="$T/g4"; build "$fx" on; printf '      VAProfileH264Main               :\tVAEntrypointVLD\n' > "$fx/vainfo"; run_sc "$fx"
[ "$RC" = 1 ] && echo "$OUT" | grep -q "^FAIL  va-encode" && ok "va-encode FAIL" || { bad "rc=$RC"; echo "$OUT"; }

echo "G5 no driver bound / package missing → FAIL each"
fx="$T/g5"; build "$fx" on; rm "$fx/sys/bus/pci/devices/0000:00:02.0/driver" "$fx/ihd"; run_sc "$fx"
echo "$OUT" | grep -q "^FAIL  igd-driver" && echo "$OUT" | grep -q "^FAIL  iHD-package" && ok "driver + package FAIL" || { bad "$OUT"; }

echo "G6 brave-vaapi: plain Brave without the Intel node, VA-API args + env with it"
cat > "$SHIM/fakebrave" <<'S'
#!/bin/bash
echo "LIBVA=${LIBVA_DRIVER_NAME:-unset} ARGS=$*"
S
chmod +x "$SHIM/fakebrave"
o=$(BRAVE_BIN="$SHIM/fakebrave" XDG_STATE_HOME="$T/state" bash -c 'sed "s|/dev/dri/by-path|'"$T"'/nodri/by-path|" "'"$ROOT"'/katana-av/igd/brave-vaapi" > "'"$T"'/bv-off"; bash "'"$T"'/bv-off" --x')
[ "$o" = "LIBVA=unset ARGS=--x" ] && ok "no node → plain Brave, args untouched" || bad "got: $o"
mkdir -p "$T/withdri/by-path"; : > "$T/withdri/renderD129"; ln -s ../renderD129 "$T/withdri/by-path/pci-0000:00:02.0-render"
o=$(BRAVE_BIN="$SHIM/fakebrave" XDG_STATE_HOME="$T/state" bash -c 'sed "s|/dev/dri/by-path|'"$T"'/withdri/by-path|" "'"$ROOT"'/katana-av/igd/brave-vaapi" > "'"$T"'/bv-on"; bash "'"$T"'/bv-on" --x')
echo "$o" | grep -q "^LIBVA=iHD ARGS=--render-node-override=$T/withdri/renderD129 .*VaapiVideoEncoder.* --x$" && ok "node → iHD env, override, encoder feature, args kept last" || bad "got: $o"

echo; echo "fail=$fail"
[ "$fail" -eq 0 ]
