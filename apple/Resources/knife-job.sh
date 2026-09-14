#!/bin/bash
# knife-job.sh — Knife Terminal's job runner. Runs inside a terminal tab on the
# executor Mac; the tab mirrors to the phone/laptop, so it doubles as the job's
# status view. The app (dispatcher) only opens the tab — a hung job hangs this
# process, never the terminal.
#
#   knife-job.sh run "<request>"   route → worktree of last pushed state → claude
#                                  → one commit → push to main, or branch + PR → diff
#   knife-job.sh adopt <dir>       git init + private GitHub remote for a folder
#
# Reads ~/.knife/manifest.json (written by the app: every machine's projects,
# merged by git remote). Pings ~/.knife-terminal.sock for pushes.
set -u
KNIFE=$HOME/.knife
MANIFEST=${KNIFE_MANIFEST:-$KNIFE/manifest.json}   # overrides: self-check against a scratch repo
CLONES=${KNIFE_CLONES:-$KNIFE/projects}
WORKTREES=${KNIFE_WORKTREES:-$KNIFE/worktrees}
SOCK=$HOME/.knife-terminal.sock
mkdir -p "$KNIFE/jobs" "$KNIFE/router" "$CLONES" "$WORKTREES"

say()   { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail()  { say "✗ $*"; alert "job failed — $*"; exit 1; }
alert() { # tab attention + phone push, via the app's socket
  [ -n "${KNIFE_TAB:-}" ] && printf 'alert %s %s' "$KNIFE_TAB" "$*" | nc -U -w 1 "$SOCK" >/dev/null 2>&1
}
cwd_osc() { printf '\033]7;file://%s%s\a' "$(hostname)" "$1"; }   # tell the tab where we are (chat mirror follows it)
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
  local text=$1 id JOB r remote conf cands name repo base wt branch summary verdict outcome diff
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

  say "$name — preparing worktree"
  repo=$(resolve "$remote") || fail "could not clone $remote"
  cd "$repo" || fail "no checkout"
  git fetch -q origin --prune || fail "fetch failed"
  git symbolic-ref -q refs/remotes/origin/HEAD >/dev/null || git remote set-head origin -a >/dev/null 2>&1
  base=$(git symbolic-ref -q --short refs/remotes/origin/HEAD); base=${base#origin/}; base=${base:-main}
  wt=$WORKTREES/$id; branch=knife/$id
  git worktree add -q -b "$branch" "$wt" "origin/$base" || fail "worktree add failed"
  cd "$wt" || fail "no worktree"
  cwd_osc "$wt"

  say "$name — claude working (origin/$base @ $(git rev-parse --short HEAD))"
  claude -p --dangerously-skip-permissions --output-format text "$text

You are working in a throwaway git worktree of this project, checked out at the last pushed state of $base. Make the change requested above. Do not commit, push, or create branches — the runner does that. When you are done, end your reply with exactly these two lines:
SUMMARY: <one-line commit message for the change>
VERDICT: direct
Use VERDICT: direct for a small, low-risk change that is safe to push straight to $base; use VERDICT: pr for anything large, experimental, or that could break things (it will go to a branch and a pull request)." </dev/null | tee "$JOB.out"

  # whatever claude did (even if it committed anyway) becomes exactly one commit on top of origin/$base
  git reset -q --soft "origin/$base"
  if [ -z "$(git status --porcelain)" ]; then
    say "$name — no changes made"; alert "$name — no changes made — $text"
    cd "$repo" && git worktree remove --force "$wt" && git branch -q -D "$branch"
    exit 0
  fi
  summary=$(grep -m1 '^SUMMARY:' "$JOB.out" | sed 's/^SUMMARY: *//'); summary=${summary:-$text}
  verdict=$(grep -m1 '^VERDICT:' "$JOB.out" | awk '{print tolower($2)}'); verdict=${verdict:-pr}
  git add -A && git commit -q -m "$summary" -m "Knife job $id: $text" || fail "commit failed"

  if [ "$verdict" = direct ]; then
    if git push -q origin "HEAD:$base"; then outcome="pushed to $base @ $(git rev-parse --short HEAD) — revert with: git revert $(git rev-parse --short HEAD)"
    else say "push to $base rejected — opening a PR instead"; verdict=pr; fi
  fi
  if [ "$verdict" = pr ]; then
    git push -q -u origin "$branch" || fail "push failed"
    outcome="PR $(gh pr create --base "$base" --head "$branch" --title "$summary" --body "Knife job $id — request: $text" 2>&1 | tail -1)"
  fi

  diff=$(git show -p --stat --format='%h %s' HEAD)
  printf '%s\n' "$diff" > "$JOB.diff"
  say "$name — $outcome"
  printf '%s\n' "$diff"
  # ponytail: APNs caps the push payload — the full diff is on screen and in $JOB.diff
  alert "$name — $outcome
$(printf '%s' "$diff" | head -c 2500)"
  cd "$repo" && git worktree remove --force "$wt"
  [ "$verdict" = direct ] && git branch -q -D "$branch"
  say "done — $JOB.diff"
}

# ─── adopt: make a folder a project (git repo + private GitHub remote) ───
adopt() {
  cd "$1" || exit 1
  [ -d .git ] || git init -q
  git rev-parse -q --verify HEAD >/dev/null || { git add -A; git commit -q -m "initial commit" || git commit -q --allow-empty -m "initial commit"; }
  git remote get-url origin >/dev/null 2>&1 || gh repo create "$(basename "$PWD")" --private --source=. --remote=origin --push || exit 1
  say "$(basename "$PWD") → $(git remote get-url origin)"
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0   # sourced: functions only (self-check below)
case "${1:-}" in
  run)   run "$2" ;;
  adopt) adopt "$2" ;;
  *)     echo "usage: knife-job.sh run \"<request>\" | adopt <dir>"; exit 2 ;;
esac
