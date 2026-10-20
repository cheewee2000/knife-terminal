#!/bin/bash
# knife-remote.sh — hand a tab's Claude session to another Mac, so it keeps running
# with this one closed. Runs inside the tab: copies the transcript over, resumes it
# in tmux there, and attaches; the tab reattaches after sleep or a network drop.
# Closing the tab leaves the remote session running; reopening (or restore) attaches.
# When the remote claude exits, its transcript comes home and the tab is a local shell.
#
#   knife-remote.sh send <cwd> [transcript.jsonl]   (newest transcript for cwd if omitted)
#
# Config ~/.knife/remote, sourced (no file → the app hides "Send to Remote Mac"):
#   KNIFE_REMOTE_HOST=user@host.local                    key-based ssh, tmux installed there
#   KNIFE_REMOTE_MAP='/Users/me/Dropbox/=/Users/them/Dropbox/'   local prefix=remote prefix
set -u
. "${KNIFE_REMOTE_CONF:-$HOME/.knife/remote}" || exit 1
host=$KNIFE_REMOTE_HOST
from=${KNIFE_REMOTE_MAP%%=*} to=${KNIFE_REMOTE_MAP#*=}
RPATH='export PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH;'
slug() { printf %s "$1" | sed 's/[^A-Za-z0-9]/-/g'; }   # Claude Code's ~/.claude/projects dir name
q()    { printf %q "$1"; }
r()    { ssh -o ConnectTimeout=5 "$host" "$RPATH $1"; }
# swap path prefixes inside a transcript so file references resolve on the other side
remap() { A=$1 B=$2 perl -pe 's/\Q$ENV{A}\E/$ENV{B}/g'; }

[ "${1:-}" = send ] || { sed -n 2,14p "$0"; exit 1; }
cwd=$2 t=${3:-}
case $cwd in "$from"*) rcwd=$to${cwd#"$from"} ;; *) echo "✗ $cwd isn't under $from — $host can't see it"; exit 1 ;; esac
[ -n "$t" ] || t=$(ls -t "$HOME/.claude/projects/$(slug "$cwd")"/*.jsonl 2>/dev/null | head -1)
[ -f "$t" ] || { echo "✗ no Claude transcript for $cwd"; exit 1; }
id=$(basename "$t" .jsonl) s=knife-${id:0:8}
rt=.claude/projects/$(slug "$rcwd")/$id.jsonl
sent=$HOME/.knife/remote-sent/$id

if ! r "tmux has-session -t $s" 2>/dev/null; then
  [ -f "$sent" ] && { echo "✗ $s on $host is gone; ssh in, or rm $(q "$sent") to send again"; exit 1; }
  echo "→ sending $id to $host"
  remap "$from" "$to" <"$t" | r "mkdir -p $(q "$(dirname "$rt")") && cat > $(q "$rt")" || exit 1
  # prefix off: Claude Code owns ctrl-b; closing the tab is how you detach
  r "tmux new -d -s $s -c $(q "$rcwd") 'PATH=\$HOME/.local/bin:/opt/homebrew/bin:\$PATH claude --resume $id' \; set -t $s status off \; set -t $s prefix None" || exit 1
  mkdir -p "$(dirname "$sent")" && touch "$sent"
fi
printf '\033]0;%s\007' "⇢ $host"
until ssh -t -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$host" "$RPATH tmux attach -t $s"; [ $? -ne 255 ]; do
  echo "[$host unreachable — retrying]"; sleep 3
done
r "tmux has-session -t $s" 2>/dev/null && exit 0   # detached, still running there
r "cat $(q "$rt")" | remap "$to" "$from" >"$t.tmp" && [ -s "$t.tmp" ] && mv "$t.tmp" "$t" && rm -f "$sent"
echo "← session back on this Mac: claude --resume $id"
