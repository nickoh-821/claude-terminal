#!/bin/bash
# Claude Code hook: tells ClaudeTerminal which transcript file backs the
# session in this tab (OSC 7779), so ⌘L opens exactly that one. Without it,
# ⌘L falls back to the newest session file for the tab's directory.
#
# Reads the hook payload on stdin, prints nothing, always exits 0. Needs jq.
[ "$TERM_PROGRAM" = "ClaudeTerminal" ] || exit 0

TRANSCRIPT=$(jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$TRANSCRIPT" ] || exit 0

# Hooks run without a terminal of their own: walk up to the first ancestor
# that has one (the claude process) and write to that.
pid=$$
for _ in 1 2 3 4 5 6 7 8; do
  read -r ppid tty <<<"$(ps -o ppid=,tty= -p "$pid" 2>/dev/null)"
  [ -z "$ppid" ] && break
  case "$tty" in
    ttys*|pts*) printf '\033]7779;%s\007' "$TRANSCRIPT" > "/dev/$tty" 2>/dev/null; break ;;
  esac
  pid="$ppid"
  [ "$pid" -le 1 ] && break
done
exit 0
