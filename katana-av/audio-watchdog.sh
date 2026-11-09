#!/bin/bash
# audio-watchdog — keeps katana's call audio sane in realtime (JP 2026-10-31: "set up a watchdog monitor that can respond in realtime").
# Loop every INTERVAL s. Deterministic, no LLM. Logs to $LOG; desktop toast on each corrective action (rate-limited).
# Env overrides: INTERVAL, ONCE=1 (single pass), DRY=1 (log only), CALL_APPS (regex of call apps whose mic is kept on the Scarlett).
# Lives in kiyo-xhci-fix/katana-av since 2026-11-08 (moved from ~/Projects/audio-watchdog, which had no git). Same day:
#   - state lines ("no Scarlett card") are logged when they CHANGE, not every pass (296,502 identical lines / 12.7 MB in 7 days);
#   - the log rotates to log.1 above LOG_MAX bytes;
#   - mic-keeper.sh's job moved in: every call app's mic stream (browsers, Zoom, Slack, Signal) is kept on Mic 1,
#     never one that reads a monitor (screen-share audio). mic-keeper's own capture-and-suspend loop is not
#     carried over: a stall stays report-only here (JP's "rebuild audio"), and audio-selfcheck measures it.
set -u
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
INTERVAL="${INTERVAL:-2}"; DRY="${DRY:-0}"
LOGDIR="${AUDIO_WD_STATE:-$HOME/.local/state/audio-watchdog}"; mkdir -p "$LOGDIR"; LOG="$LOGDIR/log"
LOG_MAX="${LOG_MAX:-5242880}"
PSI_IO="${PSI_IO:-/proc/pressure/io}"   # tests point this at a fixture
SCARLETT_PROFILE="HiFi (Line1, Line2, Mic1, Mic2)"
WANT_RATE=48000; WANT_QUANTUM="${WANT_QUANTUM:-4096}"; MIC_PREF="${MIC_PREF:-scarlett}"  # kiyo|scarlett: the Scarlett 2i2 4th-gen capture stalled in 10–20 s stretches on kernel 7.0 (2026-10-31); its playback is fine
CALL_APPS="${CALL_APPS:-ringrtc|brave|chrom|firefox|zoom|slack|teams|discord|linphone}"
last_notify=0; stall_count=0; call_mode=0; psi_count=0; last_state=""; passes=0
pwtop_last(){ pw-top -b -n 2 2>/dev/null | awk '/^S +ID/{blk++} blk>=2' ; }
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
state(){ [ "$*" = "$last_state" ] && return; last_state="$*"; log "$*"; }   # log a condition once, when it changes
rotate(){ local sz; sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0); (( sz > LOG_MAX )) && mv -f "$LOG" "$LOG.1"; return 0; }
act(){ log "ACT $*"; [ "$DRY" = 1 ] && return 1; return 0; }
toast(){ now=$(date +%s); if (( now - last_notify >= 60 )); then notify-send -a "audio-watchdog" -u low "Audio watchdog" "$*" 2>/dev/null; last_notify=$now; fi; }

pass(){
  local card sink src prof rate quant
  card=$(pactl list cards short 2>/dev/null | awk '/Scarlett/{print $1; exit}')
  [ -z "$card" ] && { state "no Scarlett card; waiting (logged once until it changes)"; return; }
  # 1. profile
  prof=$(pactl list cards 2>/dev/null | awk '/Scarlett/{f=1} f&&/Active Profile:/{sub(/.*Active Profile: /,""); print; exit}')
  if [ "$prof" != "$SCARLETT_PROFILE" ]; then act "profile '$prof' -> '$SCARLETT_PROFILE'" && pactl set-card-profile "$card" "$SCARLETT_PROFILE" && toast "Scarlett profile restored"; sleep 1; fi
  sink=$(pactl list sinks short 2>/dev/null | awk '$2 ~ /Scarlett.*Line1__sink$/{print $1; exit}')
  if [ "$MIC_PREF" = kiyo ]; then src=$(pactl list sources short 2>/dev/null | awk '$2 ~ /Kiyo/ && $2 !~ /monitor/{print $1; exit}'); else src=$(pactl list sources short 2>/dev/null | awk '$2 ~ /Scarlett.*Mic1__source$/{print $1; exit}'); fi
  [ -z "$sink" ] || [ -z "$src" ] && { state "scarlett nodes missing (sink=$sink src=$src)"; return; }
  state "Scarlett present (card $card, sink $sink, mic $src)"
  # 2. clock
  rate=$(pw-metadata -n settings 0 clock.force-rate 2>/dev/null | grep -oE "value:'[0-9]+'" | grep -oE '[0-9]+')
  quant=$(pw-metadata -n settings 0 clock.force-quantum 2>/dev/null | grep -oE "value:'[0-9]+'" | grep -oE '[0-9]+')
  [ "${rate:-0}" != "$WANT_RATE" ] && act "force-rate ${rate:-0} -> $WANT_RATE" && pw-metadata -n settings 0 clock.force-rate $WANT_RATE >/dev/null
  [ "${quant:-0}" != "$WANT_QUANTUM" ] && act "force-quantum ${quant:-0} -> $WANT_QUANTUM" && pw-metadata -n settings 0 clock.force-quantum $WANT_QUANTUM >/dev/null
  # 3. defaults
  local dsink dsrc
  dsink=$(pactl get-default-sink 2>/dev/null); dsrc=$(pactl get-default-source 2>/dev/null)
  [[ "$dsink" != *Scarlett*Line1__sink ]] && act "default sink $dsink -> Scarlett" && pactl set-default-sink "$sink"
  srcname=$(pactl list sources short 2>/dev/null | awk -v i="$src" '$1==i{print $2}')
  [ "$dsrc" != "$srcname" ] && act "default source $dsrc -> $srcname" && pactl set-default-source "$src"
  # 4. call streams (ringrtc = Signal) onto the Scarlett
  local incall=0
  while read -r id s; do
    [ -z "$id" ] && continue; incall=1
    [ "$s" != "$sink" ] && act "move Signal playback #$id $s -> $sink" && pactl move-sink-input "$id" "$sink" && toast "Signal headphones back on Scarlett"
  done < <(pactl list sink-inputs 2>/dev/null | awk '/^Sink Input/{id=$3} /Sink:/{s=$2} /application.name = "ringrtc"/{sub("#","",id); print id, s}')
  # every call app's mic (was mic-keeper.sh): onto Mic 1 unless it reads a monitor on purpose (screen-share audio)
  local monitors
  monitors=" $(pactl list sources short 2>/dev/null | awk '$2 ~ /\.monitor$/{printf "%s ", $1}')"
  while read -r id s app; do
    [ -z "$id" ] && continue; incall=1
    [ "$s" = "$src" ] && continue
    [[ "$monitors" == *" $s "* ]] && continue
    act "move $app mic #$id $s -> $src ($MIC_PREF)" && pactl move-source-output "$id" "$src" && toast "$app mic back on $MIC_PREF"
  done < <(pactl list source-outputs 2>/dev/null | awk -v re="$CALL_APPS" '
      /^Source Output #/{if (id != "" && app ~ re) print id, s, app; id=substr($3,2); s=""; app=""}
      /^\tSource:/{s=$2}
      /application.name = /{a=$0; sub(/.*application.name = "/,"",a); sub(/".*/,"",a); app=tolower(a); gsub(/ /,"_",app)}
      END{if (id != "" && app ~ re) print id, s, app}')
  # 5. mic stall: Scarlett Mic1 has a consumer but no processing time for 3 passes -> restart wireplumber (max 1/5 min)
  if [ "$incall" = 1 ]; then
    local busy micpat; micpat="Mic1__source"; [ "$MIC_PREF" = kiyo ] && micpat="Kiyo"
    busy=$(pwtop_last | awk -v n="$micpat" '$1=="R" && index($NF,n) && !index($NF,".split") && !index($NF,"monitor") {print $6}' | tail -1)
    if [ -n "$busy" ] && [ "$busy" = "0.0us" ]; then stall_count=$((stall_count+1)); else stall_count=0; fi
    if (( stall_count == 5 )); then
      log "SUSPECT Scarlett mic stall x$stall_count (report-only; say 'rebuild audio' to restart wireplumber)"; toast "Mic may have stalled: say 'rebuild audio'"
    fi
  fi
  # 5b. health line every pass during a call (the "why" timeline): HEALTH.log, ring of 3000 lines
  if [ "$incall" = 1 ]; then
    local sinkq sinkr micb psi cpuwa sigcpu obscpu xr
    read -r sinkq sinkr micb < <(pwtop_last | awk '$1=="R" && $NF=="ringrtc" && $3+0>0 {q=$3; r=$4} $1=="R" && (index($NF,"Mic1__source") || index($NF,"Kiyo")) && !index($NF,".split") && !index($NF,"monitor") {b=$6} END{print q+0, r+0, b}')
    psi=$(awk '/^full/{split($2,a,"="); print a[2]}' "$PSI_IO" 2>/dev/null)
    cpuwa=$(awk '/^cpu /{t=$2+$3+$4+$5+$6+$7+$8; print $6, t}' /proc/stat)
    sigcpu=$(ps -o pcpu= -C signal-desktop --sort=-pcpu 2>/dev/null | head -1 | tr -d ' ')
    obscpu=$(ps -o pcpu= -C obs 2>/dev/null | head -1 | tr -d ' ')
    xr=$(journalctl --user -u pipewire --since "-${INTERVAL}s" --no-pager 2>/dev/null | grep -ciE 'xrun|underrun')
    printf '%s signal=%s/%s micbusy=%s psi_io_full=%s cpu_wa_ticks=%s sig=%s%% obs=%s%% xruns=%s\n' "$(date '+%T')" "$sinkq" "$sinkr" "${micb:-none}" "${psi:-?}" "${cpuwa% *}" "${sigcpu:-0}" "${obscpu:-0}" "$xr" >> "$LOGDIR/health.log"
    [ "$(wc -l < "$LOGDIR/health.log")" -gt 3000 ] && tail -n 2000 "$LOGDIR/health.log" > "$LOGDIR/health.tmp" && mv "$LOGDIR/health.tmp" "$LOGDIR/health.log"
  fi
  # 6. call mode: governor + priorities
  if [ "$incall" = 1 ] && [ "$call_mode" = 0 ]; then
    act "call mode ON: governor performance, renice signal/obs -5" && { for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo -n tee "$c" >/dev/null 2>&1; done; for p in $(pgrep -x signal-desktop) $(pgrep -x obs); do sudo -n renice -n -5 -p "$p" >/dev/null 2>&1; done; call_mode=1; }
  elif [ "$incall" = 0 ] && [ "$call_mode" = 1 ]; then
    act "call mode OFF: governor powersave" && { for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo powersave | sudo -n tee "$c" >/dev/null 2>&1; done; call_mode=0; }
  fi
  # 7. I/O pressure from a terminal window (GPU wait) during a call: LOG only, never kill, never toast.
  #    2026-11-09: 8 of these during JP's test call (full 41-49 %, top = the Ghostty "Seneschal" window, io.stat empty =
  #    GPU wait, no disk) while Mic 1 measured 0 dropouts / 0 xruns over 18 min: the toast told him his audio was at
  #    risk when it was not. The log line stays for `why`.
  if [ "$incall" = 1 ]; then
    local full; full=$(awk '/^full/{split($2,a,"="); print int(a[2])}' "$PSI_IO" 2>/dev/null)
    if (( ${full:-0} > 40 )); then psi_count=$((psi_count+1)); else psi_count=0; fi
    if (( psi_count == 3 )); then
      local hog; hog=$(for f in /sys/fs/cgroup/user.slice/user-*/user@*/app.slice/*/io.pressure; do printf '%s %s\n' "$(awk '/^some/{split($2,a,"="); print int(a[2])}' "$f")" "$(basename "$(dirname "$f")")"; done 2>/dev/null | sort -rn | head -1)
      log "IO pressure full=$full during call; top cgroup: $hog (log only; no toast since 2026-11-09)"
    fi
  fi
}
if [ "${1:-}" = "why" ]; then
  # Explain the last N minutes (default 10): anomalies in the health timeline + actions taken.
  mins="${2:-10}"; since=$(date -d "-$mins min" '+%T')
  echo "== actions since $since"; awk -v s="$(date -d "-$mins min" '+%F %T')" '$1" "$2 >= s' "$LOG" | grep -E 'ACT|IO pressure|stall|Scarlett present|no Scarlett' | tail -20
  echo "== health anomalies since $since (rate!=48000, mic busy 0, psi>40, xruns>0, signal>45%)"
  awk -v s="$since" '$1 >= s' "$LOGDIR/health.log" 2>/dev/null | awk '{
    bad=""; if ($2 !~ /\/48000$/) bad=bad" rate"; if ($3=="micbusy=0.0us") bad=bad" mic-stalled";
    split($4,p,"="); if (p[2]+0>40) bad=bad" io-pressure"; split($8,x,"="); if (x[2]+0>0) bad=bad" xruns"; split($6,g,"="); if (g[2]+0>45) bad=bad" signal-cpu";
    if (bad!="") print $1, bad, "|", $0 }' | tail -40
  echo "== last health line"; tail -1 "$LOGDIR/health.log" 2>/dev/null; exit 0
fi
rotate
log "start interval=$INTERVAL dry=$DRY"
if [ "${ONCE:-0}" = 1 ]; then pass; exit 0; fi
while true; do
  pass; passes=$((passes+1))
  [ "${MAX_PASSES:-0}" -gt 0 ] && [ "$passes" -ge "${MAX_PASSES:-0}" ] && exit 0   # tests: N passes in one process
  (( passes % 900 == 0 )) && rotate                                               # ~30 min at INTERVAL=2
  sleep "$INTERVAL"
done
