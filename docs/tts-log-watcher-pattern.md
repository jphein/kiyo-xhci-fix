# TTS Log Watcher Pattern

A technique for real-time system monitoring using Claude Code background agents and a text-to-speech MCP pipeline.

## What It Does

A background Claude Code agent continuously monitors kernel logs (`journalctl -k -f`) for specific USB/xHCI error patterns. When it detects anomalies, it announces them aloud through a TTS MCP server (speech-to-cli), giving the user immediate audio alerts without needing to watch a terminal.

The main Claude Code conversation continues working normally while the watcher runs in the background. The main agent can also read the watcher's output file to see what it reported and act on findings autonomously.

## How It Works

### Architecture

```
┌─────────────────────┐     ┌──────────────────────┐     ┌─────────────┐
│  Main Claude Code   │────>│  Background Agent     │────>│ speech-to-  │
│  conversation       │     │  (usb-watcher)        │     │ cli MCP     │
│                     │     │                       │     │ server      │
│  - fixes code       │     │  - tails journalctl   │     │             │
│  - deploys changes  │     │  - pattern matches    │──┐  │  speak()    │
│  - reads watcher    │<──┐ │  - speaks alerts      │  │  └──────┬──────┘
│    output file      │   │ │  - logs findings      │  │         │
└─────────────────────┘   │ └──────────────────────┘  │         v
                          │                            │  ┌─────────────┐
                          │   output file              │  │ Azure TTS   │
                          └───(/tmp/claude-*/tasks/    │  │ via speakers│
                               <agent-id>.output)      │  └─────────────┘
                                                       │
                                                       └── also announces
                                                           recovery, status
```

### Components

1. **Claude Code Agent tool** — `run_in_background: true` spawns an autonomous subagent that persists while the main conversation continues
2. **Bash tool** — the agent runs `journalctl -k -f` to tail kernel messages in real time
3. **MCP speech-to-cli `speak` tool** — converts text alerts to spoken audio via Azure TTS through PipeWire
4. **Output file** — the agent's full activity log, readable by the main agent at any time

### Prerequisites

- `speech-to-cli` MCP server running and configured in Claude Code
- `journalctl` access (user-level is sufficient for `-k` kernel messages)
- PipeWire/PulseAudio for audio output

## Implementation

### Launching the Watcher

From the main Claude Code conversation, spawn the agent:

```
Agent tool call:
  description: "Watch USB logs and speak alerts"
  name: "usb-watcher"
  run_in_background: true
  prompt: |
    You are a USB log monitor. Your job is to tail the kernel logs
    for USB-related events and use the speech MCP tool to announce
    any concerning USB events.

    Steps:
    1. Use the speak tool to announce: "USB log watcher online.
       Monitoring for anomalies."
    2. Run: journalctl -k -f --grep='usb|xhci|USB' --no-pager
       in the background via Bash
    3. Every ~30 seconds, check the output. If you see concerning
       USB messages (errors, resets, disconnect, overcurrent,
       watchdog, controller halt), use the speak tool to announce
       a brief summary.
    4. If things look normal, stay quiet — only speak on anomalies.
    5. Keep monitoring indefinitely.

    Use the mcp__speech-to-cli__speak tool for voice announcements.
    Keep announcements short and clear.
```

### What the Watcher Monitors

| Pattern | Severity | Example Announcement |
|---------|----------|---------------------|
| `HC died` | Critical | "Alert: xHCI host controller declared dead" |
| `not responding to stop` | Critical | "Warning: xHCI controller not responding" |
| `USB disconnect` (mass) | High | "Multiple USB devices disconnecting on bus 1" |
| `error -32` (EPIPE) | Medium | "UVC pipe error on Kiyo camera" |
| `error -110` (ETIMEDOUT) | Medium | "USB timeout detected, monitoring for cascade" |
| `error -71` (EPROTO) | Medium | "USB protocol error on camera" |
| `TRB.*no TDs queued` | Low | "TRB warnings on xHCI controller" |
| Device re-enumeration | Info | "USB devices re-enumerating, recovery in progress" |

### Reading Watcher Output from Main Agent

The main agent can check what the watcher has reported:

```bash
# Read the watcher's output file
grep -o '"text":"[^"]*"' /tmp/claude-*/tasks/<agent-id>.output | tail -10

# Or check for specific alerts
grep -i 'HC died\|not responding\|disconnect' /tmp/claude-*/tasks/<agent-id>.output
```

### Autonomous Response Loop

The key insight: the main agent doesn't just receive alerts — it can act on them:

1. **Watcher detects anomaly** → speaks alert via TTS
2. **User tells main agent** "the watcher will tell you, debug and deploy yourself"
3. **Main agent reads watcher output** → sees the alert details
4. **Main agent investigates** → reads crash logs, checks dmesg, diagnoses root cause
5. **Main agent fixes** → edits watchdog script, restarts service
6. **No human in the loop** for the debug/deploy cycle

## Adapting This Pattern

### For Other Log Sources

Replace `journalctl -k -f` with any streaming log source:

- `journalctl -u myservice.service -f` — watch a specific service
- `tail -f /var/log/nginx/error.log` — web server errors
- `kubectl logs -f deployment/myapp` — Kubernetes pod logs
- `docker logs -f container_name` — container logs

### For Other Alert Channels

Replace `mcp__speech-to-cli__speak` with:

- Desktop notifications via `notify-send`
- Slack messages via Slack MCP server
- Email via SMTP
- Any MCP tool that can deliver alerts

### Prompt Template

```
You are a [SYSTEM] log monitor. Monitor [LOG_SOURCE] for
[PATTERN_DESCRIPTION].

1. Announce you're online via [ALERT_TOOL]
2. Run [LOG_COMMAND] in the background
3. Check output every [INTERVAL] seconds
4. On anomaly: announce via [ALERT_TOOL] with a brief summary
5. On normal: stay quiet
6. Keep monitoring indefinitely
```

## Lessons Learned

- **The agent is autonomous** — it decides what's anomalous and how to phrase alerts. Good prompt engineering matters for reducing false positives.
- **Audio alerts are non-intrusive** — unlike terminal popups, TTS announcements don't steal focus. You hear them while working on something else.
- **The output file is the bridge** — the main agent reads it to understand what happened, enabling the autonomous debug/deploy loop.
- **Background agents don't notify on activity** — only on completion. Since the watcher runs indefinitely, the main agent must proactively check the output file. The user acts as the relay ("did you see the warnings?") until the main agent learns to check periodically.
