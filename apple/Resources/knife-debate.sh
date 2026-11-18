#!/bin/bash
# Multi-agent tab: every prompt typed here goes to all the chosen agents (claude, codex,
# gemini, agy). For each prompt they propose headless and read-only, then critique each
# other's latest position in rounds until every one ends with "VERDICT: AGREE" (or the
# round limit), one merges the result into the common answer, and the lead applies it.
# Earlier prompts and outcomes carry into the next one. Rounds are kept in ~/.knife/debates/.
#
# Layout (on a terminal): output scrolls in the top region; the bottom three rows stay put —
# a live status line (who is doing what, for how long), a separator, and the input line.
#   knife-debate.sh claude,gemini ["first prompt"]      KNIFE_DEBATE_ROUNDS=4
set -euo pipefail

die() { printf 'knife-debate: %s\n' "$1" >&2; exit "${2:-1}"; }

agents=${1:-}
first=${2:-}
max=${KNIFE_DEBATE_ROUNDS:-4}
mode=${KNIFE_MODE:-auto} # auto (triage each prompt) | debate | together

[ -n "$agents" ] || die "usage: knife-debate.sh claude,codex,gemini,agy [\"prompt\"]" 2
[[ "$max" =~ ^[1-9][0-9]*$ ]] || die "invalid KNIFE_DEBATE_ROUNDS '$max' (expected a positive integer)" 2
case "$mode" in
  auto|debate|together) ;;
  *) die "invalid KNIFE_MODE '$mode' (expected 'auto', 'debate' or 'together')" 2 ;;
esac

command -v python3 >/dev/null 2>&1 || die "python3 is required but not found in PATH"
cl_model=()
STREAM="$(cd "$(dirname "$0")" && pwd)/knife-stream.py"
[ -f "$STREAM" ] || die "missing helper script: $STREAM"

IFS=, read -r -a raw_agents <<< "$agents"
ALL=()
for a in "${raw_agents[@]+"${raw_agents[@]}"}"; do
  a=${a// /}
  [ -n "$a" ] || continue
  case "$a" in
    claude|codex|gemini|agy) ;;
    *) die "unknown agent '$a' (expected: claude, codex, gemini, agy)" 2 ;;
  esac
  command -v "$a" >/dev/null 2>&1 || die "agent CLI '$a' is not installed or not in PATH"
  seen=0
  for existing in "${ALL[@]+"${ALL[@]}"}"; do
    if [ "$existing" = "$a" ]; then seen=1; break; fi
  done
  if [ "$seen" = 0 ]; then ALL+=("$a"); fi
done
[ "${#ALL[@]}" -gt 0 ] || die "no valid agents specified" 2

# KNIFE_DEBATE_DIR: one history per tab, kept when the tab switches agents
S=${KNIFE_DEBATE_DIR:-$HOME/.knife/debates/$(date +%Y%m%d-%H%M%S)}
mkdir -p "$S"
[ -f "$S/history.txt" ] || : > "$S/history.txt"

LIVE="$S/live.log"
: > "$LIVE"
off=0
pids=()
names=()
TEAM=("${ALL[@]}") # who takes part in the current prompt: everyone, unless the prompt names some

# Switching agents stops us with SIGTERM: clean up background jobs and leave the screen tidy.
trap 'exit 143' TERM INT

# One headless turn, streamed live: run <agent> <prompt> <final-answer-file> [write].
# stdin is closed so an agent can never swallow what the user types.
run() {
  local a=$1 p=$2 out=$3 w=${4:-} err="$3.err"
  : > "$err"
  case "$a" in
    claude) claude -p ${cl_model[@]+"${cl_model[@]}"} --output-format stream-json --verbose --include-partial-messages --permission-mode "$([ -n "$w" ] && echo acceptEdits || echo plan)" "$p" ;;
    codex)  codex exec --json -s "$([ -n "$w" ] && echo workspace-write || echo read-only)" --skip-git-repo-check "$p" ;;
    gemini) gemini --skip-trust --approval-mode "$([ -n "$w" ] && echo auto_edit || echo plan)" -p "$p" ;;
    agy)    if [ -n "$w" ]; then agy --output-format stream-json -p="$p"; else agy --output-format stream-json -p="Read-only turn: reply in this chat only; do not create, edit or delete any files. $p"; fi ;;
    *)      printf 'unknown agent %s\n' "$a" >&2; return 1 ;;
  esac </dev/null 2>"$err" | KNIFE_COLOR=$ui python3 -I "$STREAM" "$a" "$LIVE" "$out" || true
  if [ ! -s "$out" ] && [ -s "$err" ]; then
    cp "$err" "$out" 2>/dev/null || true
    : > "$out.failed"
  fi
  rm -f "$err"
}

# ─── screen ───
ui=0
if [ -t 0 ] && [ -t 1 ]; then ui=1; fi
acolor() {
  case "$1" in
    claude) echo 208 ;;
    codex)  echo 75 ;;
    gemini) echo 141 ;;
    agy)    echo 43 ;;
    *)      echo 250 ;;
  esac
}
CC=46
H=24; W=80
B=$'\e[1m'; D0=$'\e[2m'; R0=$'\e[0m'; GR=$'\e[32m'; YE=$'\e[33m'; CY=$'\e[36m'

geom() { # size, and (re)draw the fixed rows when it changed — never clears what is already on screen
  [ "$ui" = 1 ] || return 0
  local h=24 w=80 sz=""
  if sz=$(stty size 2>/dev/null); then
    read -r h w <<< "$sz" || true
  fi
  [[ "${h:-}" =~ ^[0-9]+$ ]] && [ "$h" -ge 6 ] || h=24
  [[ "${w:-}" =~ ^[0-9]+$ ]] && [ "$w" -ge 20 ] || w=80
  if [ "$h" != "$H" ] || [ "$w" != "$W" ] || [ -z "${framed:-}" ]; then
    if [ -z "${framed:-}" ]; then # first time: scroll up 3 lines (content is kept), step back, remember the cursor across the margin reset
      printf '\n\n\n\e[3A\e7'
    else
      printf '\e7'
    fi
    H=$h; W=$w; framed=1
    printf '\e[1;%dr\e[%d;1H\e[2K%s\e8' "$((H-3))" "$((H-1))" "$D0$(printf '─%.0s' $(seq 1 "$W"))$R0"
  fi
}

status() {
  [ "$ui" = 1 ] || return 0
  geom
  printf '\e7\e[%d;1H\e[2K %s\e8' "$((H-2))" "$1"
}

input() { # $1 = prompt text → $REPLY
  if [ "$ui" = 1 ]; then
    geom
    printf '\e[%d;1H\e[2K' "$H"
  fi
  if ! read -r -e -p "$1" REPLY; then
    return 1
  fi
  if [ "$ui" = 1 ]; then
    printf '\e[%d;1H\e[2K\e[%d;1H' "$H" "$((H-3))"
  fi
  return 0
}

leave() {
  if [ "${#pids[@]}" -gt 0 ]; then
    kill "${pids[@]}" 2>/dev/null || true
  fi
  if [ "$ui" = 1 ]; then
    printf '\e[r\e[%d;1H\e[2K\e[%d;1H\e[2K\e[%d;1H\e[2K\e[%d;1H' "$((H-2))" "$((H-1))" "$H" "$((H-2))" || true
  fi
}
trap leave EXIT
if [ "$ui" = 1 ]; then geom; status "${D0}ready${R0}"; fi

# Print whatever the agents have streamed to the live log since last time.
drain() {
  local sz
  sz=$(stat -f%z "$LIVE" 2>/dev/null || echo 0)
  if [ "$sz" -gt "$off" ]; then
    tail -c +"$((off+1))" "$LIVE" | head -c "$((sz-off))" || true
    off=$sz
  fi
}

# Show progress for the background jobs in $pids (agents in $names) until they exit:
# "<label> · ⠹ claude 23s · ✔ agy 41s" — and returns when all are done.
track() {
  local label=$1 i=0 t0=$SECONDS k line alive frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  while :; do
    alive=0
    line="${B}$label${R0}"
    for k in "${!pids[@]}"; do
      if kill -0 "${pids[k]}" 2>/dev/null; then
        alive=1
        line+="  ${YE}${frames:i%10:1}${R0} ${names[k]} $((SECONDS-t0))s"
      else
        line+="  ${GR}✔${R0} ${names[k]}"
      fi
    done
    drain
    status "$line"
    [ "$alive" = 0 ] && break
    sleep 0.15
    i=$((i+1))
  done
  if [ "${#pids[@]}" -gt 0 ]; then
    wait "${pids[@]}" 2>/dev/null || true
  fi
  pids=()
  drain
  status "${D0}ready${R0}"
}

# A titled, color-coded block: every line carries the color's gutter.   block <256-color> <title> <file> <gutter> [heavy]
block() {
  local c=$1 t=$2 f=$3 g=$4 heavy=${5:-} on="" off_code=""
  if [ "$ui" = 1 ]; then
    on=$'\e[38;5;'"$c"'m'
    off_code=$'\e[0m'
  fi
  if [ -n "$heavy" ]; then
    printf '\n%s%s┏━━ %s ━━%s\n' "$B" "$on" "$t" "$off_code"
  else
    printf '\n%s%s── %s%s\n' "$B" "$on" "$t" "$off_code"
  fi
  if [ -f "$f" ]; then
    sed "s/^/$on$g$off_code /" "$f"
  fi
  if [ -n "$heavy" ]; then
    printf '%s%s┗━━%s\n' "$B" "$on" "$off_code"
  fi
}

build_context() {
  local hist
  hist=$(tail -c 6000 "$S/history.txt" 2>/dev/null || true)
  ctx=""
  if [ -n "${KNIFE_PRIOR:-}" ] && [ -f "$KNIFE_PRIOR" ]; then
    ctx="EARLIER IN THIS TAB the user worked with Claude Code; its session transcript (JSONL) is at $KNIFE_PRIOR — read its tail for background if useful.

"
  fi
  if [ -n "$hist" ]; then
    ctx+="EARLIER IN THIS SESSION (user prompts and what was done):
$hist

"
  fi
}

# Run one prompt through the group; sets $final to the common answer, "" if nothing usable.
debate() {
  local task=$1 D="$S/$2" round=1 a b p others keep f agree=0 all lead reason
  mkdir -p "$D"
  A=("${TEAM[@]}")
  final=""
  build_context

  while :; do
    pids=(); names=()
    if [ "$round" = 1 ]; then
      printf '\n%s── round 1 · each of %s proposes its own solution%s\n' "$CY" "${A[*]}" "$R0"
    else
      printf '\n%s── round %s · cross-checking each other'"'"'s positions and revising%s\n' "$CY" "$round" "$R0"
    fi
    for a in "${A[@]}"; do
      if [ "$round" = 1 ]; then
        p="${ctx}You are one of ${#A[@]} engineers (${A[*]}) independently solving the user's request in this repository. Inspect the code as needed (read-only). Propose your best solution: approach, the files to change, risks. Be concrete and concise.

REQUEST: $task"
      else
        others=""
        for b in "${A[@]}"; do
          if [ "$b" != "$a" ]; then
            others+="--- $b's latest position ---
$(cat "$D/r$((round-1))-$b.txt" 2>/dev/null || true)

"
          fi
        done
        p="${ctx}You are $a, in a debate with the other engineers (${A[*]}) to reach the strongest solution to the user's request. Read their positions, check their claims against the code, and point out real flaws or missing cases. Then give your revised full proposal, adopting any better ideas. Finish with exactly one last line: 'VERDICT: AGREE' if the group's solution is now sound and you would accept it with no material change, otherwise 'VERDICT: DISAGREE'.

REQUEST: $task

YOUR PREVIOUS POSITION:
$(cat "$D/r$((round-1))-$a.txt" 2>/dev/null || true)

$others"
      fi
      ( s=$SECONDS; run "$a" "$p" "$D/r$round-$a.txt"; echo $((SECONDS-s)) > "$D/t$round-$a" ) &
      pids+=($!); names+=("$a")
    done
    track "round $round/$max"

    # an agent that errored (not logged in, quota, crash) sits out instead of blocking the others
    keep=()
    for a in "${A[@]}"; do
      f="$D/r$round-$a.txt"
      if [ ! -s "$f" ] || { head -c 400 "$f" 2>/dev/null || true; } | grep -qiE 'invalid api key|not logged in|please (log|sign) in|unauthenticated|authentication failed'; then
        reason=$(head -c 120 "$f" 2>/dev/null | tr '\r\n' '  ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
        printf '  %s✖ %s gave no usable answer — sitting out%s%s\n' "$YE" "$a" "$R0" "${reason:+ ($reason)}"
      else
        keep+=("$a")
      fi
    done
    A=("${keep[@]+"${keep[@]}"}")
    if [ "${#A[@]}" -lt 2 ]; then
      if [ "${#A[@]}" = 1 ]; then
        printf '  Only %s is left; using its answer.\n' "${A[0]}"
        final=$(grep -v '^VERDICT: ' "$D/r$round-${A[0]}.txt" 2>/dev/null || true)
      else
        printf '  %s✖ no agents produced a usable answer%s\n' "$YE" "$R0"
      fi
      return 0
    fi

    agree=0
    for a in "${A[@]}"; do
      local elapsed
      elapsed=$(cat "$D/t$round-$a" 2>/dev/null || echo "?")
      if [ "$round" = 1 ]; then
        printf '  %s✔%s %s proposed (%ss)\n' "$GR" "$R0" "$a" "$elapsed"
      elif { tail -n 3 "$D/r$round-$a.txt" 2>/dev/null || true; } | grep -q 'VERDICT: AGREE'; then
        agree=$((agree+1))
        printf '  %s✔%s %s agrees (%ss)\n' "$GR" "$R0" "$a" "$elapsed"
      else
        printf '  %s↻%s %s still wants changes (%ss)\n' "$YE" "$R0" "$a" "$elapsed"
      fi
    done
    if [ "$round" -gt 1 ] && [ "$agree" -eq "${#A[@]}" ]; then
      printf '%s✔ consensus after %s rounds%s\n' "$GR" "$round" "$R0"
      break
    fi
    if [ "$round" -ge "$max" ]; then
      printf '%s✖ no full agreement after %s rounds (%s/%s agree) — merging the best of both%s\n' "$YE" "$round" "$agree" "${#A[@]}" "$R0"
      break
    fi
    round=$((round+1))
  done

  lead=${A[0]}; all=""
  for a in "${A[@]}"; do
    grep -v '^VERDICT: ' "$D/r$round-$a.txt" > "$D/answer-$a.txt" 2>/dev/null || : > "$D/answer-$a.txt"
    all+="--- $a ---
$(cat "$D/answer-$a.txt")

"
  done
  printf '\n%s── %s is merging the common answer%s\n' "$CY" "$lead" "$R0"
  ( run "$lead" "${ctx}Merge these final positions into one clear implementation plan for the request: the common answer they agree on. Where they still differ, choose the best option and say why. Output only the plan.

REQUEST: $task

$all" "$D/final.txt" ) &
  pids=($!); names=("$lead"); track "merging"
  final=$(grep -v '^VERDICT: ' "$D/final.txt" 2>/dev/null || true)
  if [ -z "$final" ] && [ -s "$D/answer-$lead.txt" ]; then
    final=$(cat "$D/answer-$lead.txt")
  fi
  echo
  for a in "${A[@]}"; do
    block "$(acolor "$a")" "$a — final answer" "$D/answer-$a.txt" "▌"
  done
  block "$CC" "COMMON ANSWER — $([ "$agree" -eq "${#A[@]}" ] && echo "agreed by all" || echo "no full agreement, best of both")" <(printf '%s\n' "$final") "┃" 1
}

# Work together: a lead splits the request into steps, one per agent; the agents carry them out in turn
# (editing the code); then everyone reviews the combined result and the lead fixes what they find.
together() {
  local task=$1 D="$S/$2" a p line who text i=0 total=0 plan lead issues round=1 ok step_out
  mkdir -p "$D"
  A=("${TEAM[@]}")
  lead=${A[0]}
  final=""
  build_context

  # 1. the lead plans
  printf '\n%s── planning · %s splits the work between %s%s\n' "$CY" "$lead" "${A[*]}" "$R0"
  ( run "$lead" "${ctx}You lead ${#A[@]} engineers (${A[*]}) who will work together on the user's request in this repository. Inspect the code as needed (read-only), then split the work into concrete steps, each given to exactly one engineer, in the order they should happen (later engineers build on earlier work; never have two engineers editing the same file at once; give every engineer at least one step if the task allows). Output ONLY lines of the form
STEP <engineer>: <what to do>
using the engineer names exactly as written. No other text.

REQUEST: $task" "$D/plan.txt" ) &
  pids=($!); names=("$lead"); track "planning"

  steps=(); stepwho=()
  while IFS= read -r line; do
    who=${line#STEP }
    who=${who%%:*}
    who=${who// /}
    text=${line#*:}
    text=${text# }
    for a in "${A[@]}"; do
      if [ "$who" = "$a" ] && [ -n "$text" ]; then
        steps+=("$text")
        stepwho+=("$a")
      fi
    done
  done < <(sed -n 's/^[[:space:]0-9.*-]*\(STEP [a-z][a-z]*:[[:space:]]*.*\)/\1/p' "$D/plan.txt" 2>/dev/null || true)

  if [ "${#steps[@]}" = 0 ]; then # no usable plan: each takes the whole request in turn
    printf '  %sno step list from %s — every agent takes the request in turn%s\n' "$YE" "$lead" "$R0"
    for a in "${A[@]}"; do
      steps+=("Do your share of the request, building on what the earlier engineers did.")
      stepwho+=("$a")
    done
  fi
  total=${#steps[@]}
  plan=$(sed -n 's/^[[:space:]0-9.*-]*\(STEP [a-z][a-z]*:[[:space:]]*.*\)/\1/p' "$D/plan.txt" 2>/dev/null || true)
  [ -n "$plan" ] || plan="(each in turn)"
  printf '%s  plan:%s\n' "$D0" "$R0"
  for i in "${!steps[@]}"; do
    printf '   %s▌%s %-7s %s\n' "$([ "$ui" = 1 ] && printf '\e[38;5;%sm' "$(acolor "${stepwho[i]}")" || true)" "$R0" "${stepwho[i]}" "${steps[i]}"
  done

  # 2. the steps, one after another
  local done_so_far=""
  for i in "${!steps[@]}"; do
    a=${stepwho[i]}; pids=(); names=()
    printf '\n%s── step %s/%s · %s%s\n' "$CY" "$((i+1))" "$total" "$a" "$R0"
    ( run "$a" "${ctx}You are $a, working together with ${A[*]} on the user's request in this repository. Edit files as needed.

REQUEST: $task

THE PLAN:
$plan

DONE SO FAR:
${done_so_far:-(nothing yet)}

YOUR STEP: ${steps[i]}

Do your step now; leave the other engineers' steps alone. Finish with a 2-4 line summary of what you changed." "$D/step-$i-$a.txt" write ) &
    pids+=($!); names+=("$a"); track "step $((i+1))/$total"
    step_out=$(tail -c 2000 "$D/step-$i-$a.txt" 2>/dev/null || true)
    if [ -z "$step_out" ]; then
      printf '  %s✖ %s produced no output for step %s%s\n' "$YE" "$a" "$((i+1))" "$R0"
      step_out="(no output)"
    fi
    done_so_far+="- $a: $step_out
"
  done

  # 3. everyone reviews; the lead fixes
  ok=0
  while :; do
    pids=(); names=(); issues=""
    printf '\n%s── review %s · everyone checks the combined result%s\n' "$CY" "$round" "$R0"
    for a in "${A[@]}"; do
      ( run "$a" "${ctx}You are $a, reviewing the work the engineers (${A[*]}) just did together for the user's request. Read the changed files / run git diff (read-only). Report only real bugs, broken behaviour or missing pieces — not style. Finish with exactly one last line: 'VERDICT: LGTM' if it is good as is, otherwise 'VERDICT: ISSUES'.

REQUEST: $task

WHAT WAS DONE:
$done_so_far" "$D/review$round-$a.txt" ) &
      pids+=($!); names+=("$a")
    done
    track "review $round"
    ok=0
    for a in "${A[@]}"; do
      f="$D/review$round-$a.txt"
      if { tail -n 3 "$f" 2>/dev/null || true; } | grep -q 'VERDICT: LGTM'; then
        ok=$((ok+1))
        printf '  %s✔%s %s: looks good\n' "$GR" "$R0" "$a"
      elif [ -s "$f" ] && [ ! -e "$f.failed" ]; then
        printf '  %s↻%s %s found issues\n' "$YE" "$R0" "$a"
        issues+="--- $a ---
$(grep -v '^VERDICT: ' "$f" 2>/dev/null || true)
"
      else
        printf '  %s✖%s %s gave no review\n' "$YE" "$R0" "$a"
        ok=$((ok+1))
      fi
    done
    if [ "$ok" -eq "${#A[@]}" ]; then
      printf '%s✔ everyone is happy with the result%s\n' "$GR" "$R0"
      break
    fi
    if [ "$round" -ge "$max" ]; then
      printf '%s✖ still open after %s review rounds — the notes are in the recap%s\n' "$YE" "$round" "$R0"
      break
    fi
    pids=(); names=("$lead")
    printf '\n%s── %s is fixing what the reviewers found%s\n' "$CY" "$lead" "$R0"
    ( run "$lead" "${ctx}You are $lead. Your teammates reviewed the work done together on the user's request and found problems. Fix the real ones now (edit files), skip anything wrong or only stylistic, then summarize in 2-4 lines what you changed.

REQUEST: $task

REVIEW NOTES:
$issues" "$D/fix$round.txt" write ) &
    pids+=($!); track "fixing"
    done_so_far+="- $lead (fix after review $round): $(tail -c 2000 "$D/fix$round.txt" 2>/dev/null || true)
"
    round=$((round+1))
  done

  # recap: each agent's part in its color, then the shared result
  echo
  for a in "${A[@]}"; do
    : > "$D/part-$a.txt"
    for i in "${!steps[@]}"; do
      if [ "${stepwho[i]}" = "$a" ]; then
        printf '%s\n' "${steps[i]}" >> "$D/part-$a.txt"
        if [ -f "$D/step-$i-$a.txt" ]; then
          cat "$D/step-$i-$a.txt" >> "$D/part-$a.txt"
        fi
      fi
    done
    if [ -s "$D/part-$a.txt" ]; then
      block "$(acolor "$a")" "$a — what it did" "$D/part-$a.txt" "▌"
    fi
  done
  final="$done_so_far"
  if [ "$ok" -eq "${#A[@]}" ]; then
    final+="
Reviewed by ${A[*]}: all happy."
  else
    final+="
Open review notes remain:
$issues"
  fi
  block "$CC" "WORKED TOGETHER — $([ "$ok" -eq "${#A[@]}" ] && echo "reviewed and agreed by all" || echo "review still open")" <(printf '%s\n' "$final") "┃" 1
}

# One agent on its own, like a normal single-agent tab: $1 = request, $2 = turn number, $3 = which agent.
solo() {
  local task=$1 D=$S/$2 who=${3:-${ALL[0]}} ctx=""; mkdir -p "$D"; build_context
  printf '\n%s── %s handles this on its own%s\n' "$CY" "$who" "$R0"
  ( run "$who" "${ctx}$task" "$D/solo.txt" write ) &
  pids=($!); names=("$who"); track "$who"
  final=$(cat "$D/solo.txt" 2>/dev/null || true)
  printf 'USER: %s\nOUTCOME (%s alone): %s\n\n' "$task" "$who" "$(printf '%s' "$final" | head -c 1500)" >> "$S/history.txt"
}

# Did the user ask for something explicit? Names of agents ("claude and gemini look at this") and words like
# "both", "debate", "work together", "until you agree" beat the automatic check. Sets $how, $why, $TEAM
# (just the named agents) and, for "until you agree", a higher round limit. Returns 1 when nothing was asked.
in_all() { local x; for x in "${ALL[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
intent() {
  local lc tok a named=() team_words=0 all_words=0 together_words=0 mapped note=""
  lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  for tok in claude codex gemini agy antigravity; do
    printf '%s' "$lc" | grep -Eqw "$tok" || continue
    case "$tok" in
      antigravity) mapped=agy ;;
      gemini) if in_all gemini; then mapped=gemini; elif in_all agy; then mapped=agy; note=" (gemini → agy, your Gemini plan)"; else mapped=""; fi ;;
      *) mapped=$tok ;;
    esac
    [ -n "$mapped" ] && in_all "$mapped" || continue
    for a in ${named[@]+"${named[@]}"}; do [ "$a" = "$mapped" ] && continue 2; done
    named+=("$mapped")
  done
  printf '%s' "$lc" | grep -Eq "(^|[^a-z])(both|all of you|everyone|each of you|you two|you all|the two of you|all agents)([^a-z]|$)|debate|agree|cross-check|second opinion|consensus|compare notes" && team_words=1
  printf '%s' "$lc" | grep -Eq "(^|[^a-z])(both|all of you|everyone|each of you|you two|you all|the two of you|all agents)([^a-z]|$)" && all_words=1
  printf '%s' "$lc" | grep -Eq "work(ing)? together|collaborat|split the work|divide the work|build it together|pair on" && together_words=1
  if [ "${#named[@]}" -ge 2 ]; then TEAM=("${named[@]}"); why="you asked for ${named[*]}$note"
  elif [ "$all_words" = 1 ] && [ "${#ALL[@]}" -ge 2 ]; then TEAM=("${ALL[@]}"); why="you asked for all of them"
  elif [ "${#named[@]}" = 1 ] && [ "$team_words" = 0 ] && [ "$together_words" = 0 ]; then how=solo; direct=${named[0]}; why="you asked for ${named[0]}$note"; return 0
  elif [ "$team_words" = 1 ] || [ "$together_words" = 1 ]; then [ "${#ALL[@]}" -ge 2 ] || return 1; TEAM=("${ALL[@]}"); why="you asked for several agents"
  else return 1; fi
  if [ "$together_words" = 1 ]; then how=together; else how=debate; fi
  if printf '%s' "$lc" | grep -Eq "(until|till|so that|so) (you|they|it)( both| all)? (agree|are agreed|is agreed)|until (it'?s|its|there'?s) (agreed|consensus)|till (it'?s|its) agreed|until (you )?(reach|have) (a )?consensus"; then
    max=8; why="$why — as many rounds as it takes (up to $max)"
  fi
  return 0
}

# Is this request worth more than one agent? Sets $how (solo | debate | together) and $why. Cheap rules first,
# then one quick question to a small model; anything unclear stays solo — several agents are the exception.
triage() {
  local t=$1 words judge line; words=$(printf '%s' "$t" | wc -w | tr -d ' ')
  how=solo; why=""
  [ "$words" -le 6 ] && { why="short request"; return; }
  case "$t" in *\?) [ "$words" -le 30 ] && { why="a question"; return; } ;; esac
  judge=${ALL[0]}; for a in "${ALL[@]}"; do [ "$a" = claude ] && judge=claude; done
  local sv=$LIVE; LIVE=/dev/null; cl_model=(--model haiku); pids=(); names=("$judge")
  ( run "$judge" "Decide how many engineers this request deserves. Answer with exactly one line, no tools needed.
SOLO: questions, explanations, lookups, small or clear edits, bug fixes with an obvious cause, anything one engineer does reliably.
DEBATE: a real design or architecture decision, an ambiguous or risky change, choosing between approaches, anything where being wrong is costly.
TOGETHER: a large build with clearly separable parts (several files or components).
When unsure choose SOLO. Format: SOLO: <reason> | DEBATE: <reason> | TOGETHER: <reason>

REQUEST: $t" "$S/triage.txt" ) &
  pids+=($!); track "deciding how to handle this"
  LIVE=$sv; cl_model=()
  line=$(grep -m1 -E '^(SOLO|DEBATE|TOGETHER)' "$S/triage.txt" 2>/dev/null || true)
  case "$line" in DEBATE*) how=debate ;; TOGETHER*) how=together ;; *) how=solo ;; esac
  why=${line#*: }; [ -n "$line" ] || why="no clear case for several agents"
}

n=0
legend=""
for a in "${ALL[@]}"; do
  legend+="$(printf '\e[38;5;%sm▌%s\e[0m ' "$(acolor "$a")" "$a")"
done
if [ "$ui" != 1 ]; then legend="${ALL[*]}"; fi
modetxt="deciding per prompt whether it needs more than one agent"
if [ "$mode" = debate ]; then modetxt="debating"; fi
if [ "$mode" = together ]; then modetxt="working together"; fi
printf '%sAgents:%s %s — %s; /exit or Ctrl-D to leave. Per prompt: /solo /debate /together, or /<agent>.\n%sTranscripts: %s%s\n' "$B" "$R0" "$legend" "$modetxt" "$D0" "$S" "$R0"

prompt=$first
while :; do
  if [ -z "$prompt" ]; then
    input "‹${ALL[*]}› " || break
    prompt=$REPLY
  fi
  case "$prompt" in
    "") continue ;;
    /exit|/quit|exit) break ;;
  esac
  printf '\n%s› %s%s\n' "$B" "$prompt" "$R0"
  n=$((n+1))
  how=$mode; direct=""; slash=0; TEAM=("${ALL[@]}"); max=${KNIFE_DEBATE_ROUNDS:-4}
  case "$prompt" in # per-prompt overrides: /solo /debate /together, or /<agent> to send it to one agent
    "/solo "*) how=solo; slash=1; prompt=${prompt#/solo } ;;
    "/debate "*) how=debate; slash=1; prompt=${prompt#/debate } ;;
    "/together "*) how=together; slash=1; prompt=${prompt#/together } ;;
    /*" "*) for a in "${ALL[@]}"; do case "$prompt" in "/$a "*) how=solo; slash=1; direct=$a; prompt=${prompt#/$a } ;; esac; done ;;
  esac
  if [ "$slash" = 0 ] && intent "$prompt"; then
    printf '  %s⇢ %s%s  %s%s%s\n' "$B" "$how" "$R0" "$D0" "$why" "$R0"
  elif [ "$how" = auto ]; then
    triage "$prompt"
    printf '  %s⇢ %s%s  %s%s%s\n' "$B" "$how" "$R0" "$D0" "$why — /solo, /debate or /together to override" "$R0"
  fi
  if [ "$how" = solo ]; then solo "$prompt" "$n" "$direct"; prompt=""; continue; fi
  if [ "$how" = together ]; then
    together "$prompt" "$n"
    printf 'USER: %s\nOUTCOME (worked together): %s\n\n' "$prompt" "$(printf '%s' "$final" | head -c 1500)" >> "$S/history.txt"
    prompt=""; continue
  fi
  debate "$prompt" "$n"
  if [ -n "$final" ]; then
    lead=${A[0]}
    input "Apply with $lead? [Enter = yes, n = plan only, or an agent name] " || break
    who=""
    case "$REPLY" in
      "") who=$lead ;;
      n|N|no) ;;
      *)
        for a in "${ALL[@]}"; do
          if [ "$REPLY" = "$a" ]; then who=$a; fi
        done
        ;;
    esac
    out="plan only, not applied"
    if [ -n "$who" ]; then
      printf '\n%s── %s is applying it%s\n' "$CY" "$who" "$R0"
      ( run "$who" "Implement this plan in the repository now, then summarize in a few lines what you changed.

REQUEST: $prompt

$final" "$S/apply.txt" write ) &
      pids=($!); names=("$who"); track "applying"
      out=$(cat "$S/apply.txt" 2>/dev/null || true)
    fi
    printf 'USER: %s\nOUTCOME (%s): %s\n\n' "$prompt" "$([ -n "$who" ] && echo "applied by $who" || echo "plan only")" "$(printf '%s' "$out" | head -c 1500)" >> "$S/history.txt"
  fi
  prompt=""
done
