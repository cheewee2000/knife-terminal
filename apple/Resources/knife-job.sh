#!/bin/bash
# knife-job.sh — Knife Terminal's job runner. Runs inside a terminal tab on the
# executor Mac; the tab mirrors to the phone/laptop, so it doubles as the job's
# status view. The app (dispatcher) only opens the tab — a hung job hangs this
# process, never the terminal.
#
#   knife-job.sh run "<request>"   route → an overseer agent opens the project in a
#                                  visible tab, runs claude there and types as you would
#   knife-job.sh adopt <dir>       git init + private GitHub remote for a folder
#   knife-tab <verb> …             (symlink) the overseer's tab tools — see tab()
#
# Reads ~/.knife/manifest.json (written by the app: every machine's projects,
# merged by git remote). Pings ~/.knife-terminal.sock for pushes.
set -u
KNIFE=$HOME/.knife
MANIFEST=${KNIFE_MANIFEST:-$KNIFE/manifest.json}   # overrides: self-check against a scratch repo
CLONES=${KNIFE_CLONES:-$KNIFE/projects}
SOCK=$HOME/.knife-terminal.sock
mkdir -p "$KNIFE/jobs" "$KNIFE/router" "$CLONES"

say()   { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail()  { say "✗ $*"; alert "job failed — $*"; exit 1; }
alert() { # tab attention + phone push, via the app's socket
  [ -n "${KNIFE_TAB:-}" ] && printf 'alert %s %s' "$KNIFE_TAB" "$*" | nc -U -w 1 "$SOCK" >/dev/null 2>&1
}

# ─── knife-tab: the app's "tab …" socket commands, replied to over the same connection ───
# nc on macOS can't half-close, so python does the round trip.
sock() { python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(10); s.connect(sys.argv[1])
s.sendall(sys.stdin.buffer.read()); s.shutdown(socket.SHUT_WR)
out = b""
while True:
    c = s.recv(65536)
    if not c: break
    out += c
sys.stdout.write(out.decode(errors="replace"))' "$SOCK"; }
# note: the overseer's log line, printed onto the job tab's screen through the app —
# the overseer's Bash is sandboxed (no /dev/tty), but the socket is reachable
note() { if [ -n "${KNIFE_TAB:-}" ]; then printf 'tab echo %s \033[2m%s\033[0m' "$KNIFE_TAB" "$*" | sock >/dev/null; else echo "$*" >&2; fi; }
tab() {
  local verb=${1:-}; shift 2>/dev/null; set -- "${1:-}" "${2:-}"
  case "$verb" in
    open|shell) local id; id=$(printf 'tab %s %s' "$verb" "$1" | sock); note "▶ $verb $1 → tab $id"; echo "$id"
                [ -n "${KNIFE_JOB:-}" ] && echo "$id" >> "$KNIFE_JOB.tabs"   # the runner watches these
                sleep 5   # ponytail: fixed settle for claude's TUI; read the screen if it looks early
                ;;
    type)   note "▶ type $1: $2"; printf 'tab type %s %s' "$1" "$2" | sock; echo ;;
    key)    note "▶ key $1 $2"; printf 'tab key %s %s' "$1" "$2" | sock; echo ;;
    read)   printf 'tab read %s' "$1" | sock; echo ;;
    status) printf 'tab status %s' "$1" | sock; echo ;;
    wait)   # block until the tab is waiting for input (attention), or idle for 15 s (claude quit), or 30 min
            local t=0 idle=0 st
            while [ $t -lt 1800 ]; do
              st=$(printf 'tab status %s' "$1" | sock)
              case "$st" in attention|gone) break ;; idle) idle=$((idle+2)); [ $idle -ge 15 ] && break ;; *) idle=0 ;; esac
              sleep 2; t=$((t+2))
            done
            note "▶ wait $1 → $st (${t}s)"; echo "$st"
            ;;
    *) echo "usage: knife-tab open|shell <dir> · type <id> <text> · key <id> <key> · read|status|wait <id>" >&2; return 2 ;;
  esac
}

# Routing/description sessions run under ~/.knife/router so they never bump a
# project's own recency; stdin closed so pending keystrokes aren't eaten.
ask() { (cd "$KNIFE/router" && claude -p --model haiku --output-format text "$@" </dev/null); }

# ─── routing: manifest + request → remote, confidence, top-3 candidates ───
route() {
  local list
  list=$(python3 - "$MANIFEST" <<'PY'
import json, sys, time
now = time.time()
for p in json.load(open(sys.argv[1])):
    if not p.get("remote"): continue
    days = (now - p.get("lastTouched", 0)) / 86400
    print(f"- {p['name']} | {p['remote']} | touched {days:.0f}d ago | {p.get('description') or 'no description'}")
PY
)
  [ -n "$list" ] || fail "manifest is empty — open a project with a git remote first"
  ask "You route a spoken request to one software project.
Projects (name | remote | last touched | description):
$list

Request: \"$1\"

Pick the project the request is about. Recently touched projects are more likely, but a clear name or topic match wins. Reply with only this JSON, nothing else:
{\"remote\": \"<remote url of the best match>\", \"confidence\": <0.0-1.0>, \"candidates\": [\"<remote>\", \"<remote>\", \"<remote>\"]}
candidates = the 3 most likely remotes, best first." | python3 -c '
import json, re, sys
m = re.search(r"\{.*\}", sys.stdin.read(), re.S)
j = json.loads(m.group(0)) if m else {}
c = [r for r in j.get("candidates", []) if r][:3] or ([j["remote"]] if j.get("remote") else [])
print(json.dumps({"remote": j.get("remote") or (c[0] if c else ""), "confidence": float(j.get("confidence", 0) or 0), "candidates": c}))'
}

name_of() { python3 -c '
import json, sys
for p in json.load(open(sys.argv[1])):
    if p.get("remote") == sys.argv[2]: print(p["name"]); break' "$MANIFEST" "$1"; }

# remote → this machine's checkout (any manifest path that exists here and
# points at the remote), cloning into $CLONES when there is none
resolve() {
  local p
  p=$(python3 -c '
import json, os, subprocess, sys
r = sys.argv[2]
for p in json.load(open(sys.argv[1])):
    if p.get("remote") == r and os.path.isdir(p["path"]):
        got = subprocess.run(["git", "-C", p["path"], "remote", "get-url", "origin"], capture_output=True, text=True).stdout.strip()
        if got == r: print(p["path"]); break' "$MANIFEST" "$1")
  if [ -z "$p" ]; then
    p="$CLONES/$(basename "${1%.git}")"
    [ -d "$p/.git" ] || { say "cloning $1" >&2; git clone -q "$1" "$p" >&2 || return 1; }   # stdout is the path
  fi
  echo "$p"
}

run() {
  local text=$1 id JOB r remote conf cands name repo summary sid
  id=$(date +%Y%m%d-%H%M%S)-$RANDOM; JOB=$KNIFE/jobs/$id
  printf '%s\n' "$text" > "$JOB.request"
  say "job $id"; echo "$text"

  say "routing…"
  r=$(route "$text") || fail "routing failed"
  remote=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["remote"])' <<<"$r")
  conf=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["confidence"])' <<<"$r")
  cands=$(python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["candidates"]))' <<<"$r")
  [ -n "$remote" ] || fail "no project matched"
  echo "→ $(name_of "$remote") ($conf)"

  if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 0.75 else 1)' "$conf"; then
    # low confidence: list the candidates, wait for a digit (the phone sends "1⏎")
    local i=1 names=() line prompt="which project?"
    while IFS= read -r line; do [ -n "$line" ] || continue; names+=("$line"); prompt="$prompt $i $(name_of "$line") ·"; i=$((i+1)); done <<<"$cands"
    say "which project? (type the number, ⏎)"
    for ((i = 0; i < ${#names[@]}; i++)); do echo "  $((i+1))  $(name_of "${names[$i]}")   ${names[$i]}"; done
    alert "${prompt% ·}"
    read -r pick
    pick=${pick//[^0-9]/}
    [ -n "$pick" ] && [ "$pick" -ge 1 ] && [ "$pick" -le ${#names[@]} ] || fail "no project picked"
    remote=${names[$((pick-1))]}
  fi
  name=$(name_of "$remote"); name=${name:-$(basename "${remote%.git}")}
  repo=$(resolve "$remote") || fail "could not clone $remote"

  # The overseer: a claude session whose only tool is knife-tab. It opens the project
  # in a real tab, runs claude there, types the request and answers its questions —
  # everything it does shows in that tab and is echoed here.
  say "$name — overseer starting ($repo)"
  mkdir -p "$KNIFE/bin"; ln -sf "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")" "$KNIFE/bin/knife-tab"
  # prompt first: --allowedTools is variadic and would swallow a trailing positional
  local prompt="You oversee terminal tabs in Knife Terminal on this Mac, working the way its owner would. Your only tool is the knife-tab command (run it with Bash):
  knife-tab open <dir>        new tab in <dir> running claude → prints the tab id (waits 5 s for claude to start)
  knife-tab shell <dir>       new tab in <dir> with a plain shell → tab id
  knife-tab type <id> <text>  type text into the tab and press enter (quote the text)
  knife-tab key <id> <key>    press one key: enter, esc, ctrl-c, up, down, tab, or a single character
  knife-tab read <id>         the tab's current screen
  knife-tab status <id>       working | attention (claude is waiting for input) | idle | gone
  knife-tab wait <id>         block until the tab is waiting for input or idle

Task: carry out this request in the project checked out at $repo:
\"$text\"

Do it like this:
1. knife-tab open $repo, then knife-tab read it. If claude shows a question (trust this folder? a menu?), answer it (enter, or the right key) and read again until the claude prompt is ready.
2. knife-tab type the request into that tab, verbatim, followed by: \"When done, commit with a one-line message and push.\"
3. knife-tab wait, then knife-tab read. If claude asks a question or wants a permission, answer as the owner would (usually yes / enter). Repeat wait + read until claude is done and has pushed.
4. When claude in the tab has finished and pushed, reply with three lines — the tab id, what changed (from what you read on screen), whether it was pushed — and then a last line that is exactly DONE. Leave the tab open.
If you end a reply without DONE, you are paused: the runner waits until the tab next needs input or goes quiet, then resumes you with its status — so never promise to wait, just end the reply.
Never run anything but knife-tab. Never close or kill the tab."

  # The overseer's turns end whenever it stops calling tools; the runner is the
  # scheduler: while its last reply isn't DONE and a tab it opened is busy, wait
  # on that tab here, then resume the same session with the tab's new status.
  : > "$JOB.tabs"
  local report sid="" rounds=0 busy id st
  report=$(overseer "$prompt"); printf '%s\n' "$report" | tee -a "$JOB.out"
  until grep -qx 'DONE' <<<"$report" || [ $rounds -ge 40 ]; do   # ponytail: 40 naps cap a runaway overseer
    busy=""
    for id in $(cat "$JOB.tabs"); do case "$(tab status "$id")" in working|attention) busy=$id ;; esac; done
    [ -n "$busy" ] || break
    st=$(tab wait "$busy"); rounds=$((rounds+1))
    report=$(overseer "Tab $busy is now $st. knife-tab read it and continue from step 3." "$sid"); printf '%s\n' "$report" | tee -a "$JOB.out"
  done

  summary=$(tail -c 2500 "$JOB.out")
  say "done"
  alert "$name — $summary"
}

# one overseer turn: $1 prompt, $2 session to resume (empty = new) → prints its reply, sets $sid
overseer() {
  local out
  out=$(cd "$KNIFE/jobs" && PATH="$KNIFE/bin:$PATH" KNIFE_JOB="$JOB" claude -p "$1" ${2:+--resume "$2"} --model sonnet \
        --output-format json --allowedTools "Bash(knife-tab:*)" </dev/null)
  sid=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' <<<"$out" 2>/dev/null)
  python3 -c 'import json,sys; print(json.load(sys.stdin).get("result",""))' <<<"$out" 2>/dev/null || printf '%s\n' "$out"
}

# ─── adopt: make a folder a project (git repo + private GitHub remote) ───
adopt() {
  cd "$1" || exit 1
  [ -d .git ] || git init -q
  git rev-parse -q --verify HEAD >/dev/null || { git add -A; git commit -q -m "initial commit" || git commit -q --allow-empty -m "initial commit"; }
  git remote get-url origin >/dev/null 2>&1 || gh repo create "$(basename "$PWD")" --private --source=. --remote=origin --push || exit 1
  say "$(basename "$PWD") → $(git remote get-url origin)"
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0   # sourced: functions only
[ "$(basename "$0")" = knife-tab ] && { tab "$@"; exit $?; }
case "${1:-}" in
  run)   run "$2" ;;
  adopt) adopt "$2" ;;
  tab)   shift; tab "$@" ;;
  *)     echo "usage: knife-job.sh run \"<request>\" | adopt <dir> | tab <verb> …"; exit 2 ;;
esac
