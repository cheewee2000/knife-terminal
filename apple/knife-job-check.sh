#!/bin/bash
# Self-check for knife-job.sh's drive() loop, with the overseer and the app's
# socket mocked: a busy tab is waited on and the overseer resumed with its
# status; lines typed into the tab (a pseudo-tty here) become "The owner says:"
# turns, before and after DONE; blank enters are ignored; a tab stopped on a usage
# limit pauses the job instead of resuming the overseer.   bash apple/knife-job-check.sh
set -u
here=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); export MOCK_T=$T
cat > "$T/mock.sh" <<'MOCK'
set -u; T=$MOCK_T; export KNIFE_MANIFEST=/dev/null KNIFE_CLONES=$T/c
. "$1"
JOB=$T/job; name=test; : > "$JOB.out"
overseer() { printf '%s\n' "$1" >> "$T/turns"; printf '%s\n' "${2:-new}" >> "$T/sids"; echo s1 > "$JOB.sid"
  case "$1" in start) echo 7 >> "$JOB.tabs"; echo 7 > "$T/busy"; echo opened ;; "The owner says: hi") echo DONE ;; *) echo "not yet" ;; esac; }
tab() { case "$1" in status) [ -f "$T/busy" ] && echo working || echo idle ;; wait) sleep 1; rm -f "$T/busy"; echo "$MOCK_WAIT" ;; esac; }
alert() { echo ALERT >> "$T/turns"; }
say() { echo "SAY:$*" >> "$T/turns"; }
drive start >/dev/null
MOCK
check() { # $1 = what the busy tab's wait reports, $2 = the expected turns
: > "$T/turns"; : > "$T/sids"; export MOCK_WAIT=$1
python3 - "$T/mock.sh" "$here/Resources/knife-job.sh" <<'PY'
import pty, os, sys, time
pid, fd = pty.fork()
if pid == 0: os.execvp("bash", ["bash", sys.argv[1], sys.argv[2]])
time.sleep(5); os.write(fd, b"\r"); os.write(fd, b"hi\r"); time.sleep(4); os.write(fd, b"more\r"); time.sleep(3); os.kill(pid, 1)
PY
if [ "$(cat "$T/turns")" = "$2" ]; then echo "knife-job-check $1: ok"; else echo "knife-job-check $1: FAILED"; diff <(echo "$2") "$T/turns"; exit 1; fi
# the first turn starts a session; every later one must resume it (drive runs overseer in a subshell)
if [ "$(sort -u "$T/sids" | xargs)" = "new s1" ] && [ "$(head -1 "$T/sids")" = new ]; then echo "knife-job-check $1 resume: ok"; else echo "knife-job-check $1 resume: FAILED"; cat "$T/sids"; exit 1; fi
}
check attention 'start
Tab 7 is now attention. knife-tab read it and continue from step 3.
ALERT
SAY:done — type here to keep talking to the overseer
The owner says: hi
The owner says: more'
check limit 'start
ALERT
SAY:paused — tab 7 hit the usage limit; type here to resume once it resets
The owner says: hi
The owner says: more'
