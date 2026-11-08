#!/bin/bash
# RETIRED 2026-11-08 (luna-katana-av): it never had a unit, and its stream-moving now runs
# inside katana-av/audio-watchdog.sh (every call app's mic onto Mic 1, never a monitor
# stream). Its capture-and-suspend step is NOT carried over: it wrote its probe to a
# /var/tmp path that need not exist, read the empty result as "Mic1 delivering nothing"
# and would suspend the Scarlett (headphones too) every 15 s. A stall is measured by
# katana-av/audio-selfcheck and stays report-only in the watchdog. Kept for history.
# mic-keeper.sh — keep call apps attached to the Scarlett Mic1 across USB re-enumerations
#
# Born 2026-09-24 mid-call: each xHCI host death re-enumerates the Scarlett, PipeWire
# creates new source ids, Brave stays attached to the dead id (silence) and the default
# source falls back to the dock's audio. Loop every 3 s:
#   - if Mic1 source id changed or default source != Mic1 → set default
#   - any brave/zoom/slack/firefox mic stream not on Mic1 → move it
#   - every 15 s: 1 s test capture from Mic1; empty → suspend/resume Scarlett nodes
#     (the scarlett-storm-guard fix) so PipeWire reopens the device
# Log: scratch/mic-keeper.log
MIC=alsa_input.usb-Focusrite_Scarlett_2i2_4th_Gen_S2A4HVU52AA44B-00.HiFi__Mic1__source
LOG="$(dirname "$0")/scratch/mic-keeper.log"
log(){ echo "$(date +%T) $*" | tee -a "$LOG"; }
last=""; tick=0
log "keeper start"
while :; do
    id=$(pactl list sources short 2>/dev/null | awk -v m="$MIC" '$2==m{print $1}')
    if [ -z "$id" ]; then sleep 3; continue; fi
    if [ "$id" != "$last" ]; then
        [ -n "$last" ] && log "Mic1 re-enumerated ($last -> $id)"
        last=$id
    fi
    def=$(pactl get-default-source 2>/dev/null)
    [ "$def" != "$MIC" ] && pactl set-default-source "$MIC" && log "default source restored"
    pactl list source-outputs 2>/dev/null | awk '
        /^Source Output #/{if(id)print id,src,app; id=substr($3,2);src="";app=""}
        /^\tSource:/{src=$2} /application.name/{app=tolower($0)}
        END{print id,src,app}' | while read -r so src app; do
        case "$app" in *brave*|*zoom*|*slack*|*firefox*|*chrom*) ;; *) continue;; esac
        [ "$src" = "$id" ] && continue
        pactl move-source-output "$so" "$MIC" 2>/dev/null && log "moved stream $so ($app) -> Mic1"
    done
    tick=$((tick+1))
    if (( tick % 5 == 0 )); then
        node=$(pw-dump 2>/dev/null | python3 -c "import sys,json;print(next(o['id'] for o in json.load(sys.stdin) if o.get('info',{}).get('props',{}).get('node.name','')=='$MIC'))" 2>/dev/null)
        if [ -n "$node" ]; then
            f=$(mktemp /var/tmp/claude-1000/mk.XXXX.wav); timeout 1.5 pw-record --target "$node" "$f" 2>/dev/null
            sz=$(stat -c %s "$f" 2>/dev/null || echo 0); rm -f "$f"
            if (( sz <= 44 )); then
                log "Mic1 delivering nothing — reopening Scarlett nodes"
                for s in $(pactl list sinks short | grep -i scarlett | cut -f2); do pactl suspend-sink "$s" 1; done
                for s in $(pactl list sources short | grep -i scarlett | grep -v monitor | cut -f2); do pactl suspend-source "$s" 1; done
                sleep 1
                for s in $(pactl list sinks short | grep -i scarlett | cut -f2); do pactl suspend-sink "$s" 0; done
                for s in $(pactl list sources short | grep -i scarlett | grep -v monitor | cut -f2); do pactl suspend-source "$s" 0; done
            fi
        fi
    fi
    sleep 3
done
