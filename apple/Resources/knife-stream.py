#!/usr/bin/env python3
"""Turns one agent CLI's output into live, color-coded lines for the debate loop (knife-debate.sh).

    <agent cli> | knife-stream.py <agent> <live-log> <final-file>

Every finished line of text, and every tool the agent runs ("▸ Read m.py"), is appended to the shared
live log as "▌agent  line" (one write per line, so several agents interleave cleanly). The agent's
final answer goes to <final-file>. KNIFE_COLOR=1 turns on the color."""
import json
import os
import sys

if len(sys.argv) < 4:
    sys.stderr.write("usage: knife-stream.py <agent> <live-log> <final-file>\n")
    sys.exit(2)

agent, live, outfile = sys.argv[1:4]
color = os.environ.get("KNIFE_COLOR") == "1"
COLORS = {"claude": 208, "codex": 75, "gemini": 141, "agy": 43}
WRAP_COL = 110
MIN_WRAP = 40

if hasattr(sys.stdin, "reconfigure"):
    sys.stdin.reconfigure(encoding="utf-8", errors="replace")


def paint(code, s):
    return f"\x1b[{code}m{s}\x1b[0m" if color else s


gutter = paint(f"38;5;{COLORS.get(agent, 250)}", f"▌{agent:<7}")
try:
    fd = os.open(live, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
except OSError as exc:
    sys.stderr.write(f"knife-stream.py: cannot open live log {live!r}: {exc}\n")
    sys.exit(1)

buf = ""
final = []     # explicit final answer segments
streamed = []  # streamed text deltas (fallback if CLI exits before a final event)
raw = []       # non-JSON lines (plain-text output or CLI errors)


def emit(line, dim=False):
    body = paint("2", line) if dim else line
    try:
        os.write(fd, f"{gutter} {body}\n".encode("utf-8", errors="replace"))
    except OSError:
        pass


def text(s, record_delta=False):
    """Buffer streamed text; show it a line at a time (long lines are cut at a space)."""
    global buf
    if not s:
        return
    if record_delta:
        streamed.append(s)
    buf += s.replace("\r\n", "\n").replace("\r", "\n")
    while True:
        if "\n" in buf:
            line, buf = buf.split("\n", 1)
            emit(line)
        elif len(buf) > WRAP_COL:
            cut = buf.rfind(" ", MIN_WRAP, WRAP_COL)
            if cut > 0:
                emit(buf[:cut])
                buf = buf[cut + 1:]
            else:
                emit(buf[:WRAP_COL])
                buf = buf[WRAP_COL:]
        else:
            return


def flush():
    global buf
    if buf.strip():
        emit(buf)
    buf = ""


def activity(name, detail=""):
    flush()
    clean = " ".join(str(detail or "").split())
    if len(clean) > 90:
        clean = clean[:89] + "…"
    emit(f"▸ {name} {clean}".rstrip(), dim=True)


def first_value(d):
    if isinstance(d, str):
        try:
            d = json.loads(d)
        except (ValueError, TypeError):
            return ""
    if not isinstance(d, dict):
        return ""
    for k in (
        "file_path", "path", "Path", "AbsolutePath", "TargetFile", "DirectoryPath", "SearchPath",
        "pattern", "Query", "query", "command", "CommandLine", "cmd", "url", "description",
    ):
        val = d.get(k)
        if isinstance(val, str) and val:
            return val
    return next((v for v in d.values() if isinstance(v, str) and v), "")


def format_cmd(cmd):
    if isinstance(cmd, list):
        return " ".join(str(x) for x in cmd)
    return str(cmd or "")


blocks = {}
try:
    for line in sys.stdin:
        line = line.rstrip("\r\n")
        if not line:
            if agent == "gemini":
                text("\n")
                final.append("")
            continue

        j = None
        if line.startswith("{"):
            try:
                parsed = json.loads(line)
                if isinstance(parsed, dict):
                    j = parsed
            except ValueError:
                j = None

        if j is None:  # plain text: gemini's output, or a CLI error
            if agent == "gemini":
                text(line + "\n")
                final.append(line)
            else:
                raw.append(line)
                text(line + "\n")
            continue

        if agent == "claude":
            t = j.get("type")
            if t == "stream_event":
                e = j.get("event") or {}
                et = e.get("type")
                i = e.get("index")
                if et == "content_block_start":
                    cb = e.get("content_block") or {}
                    blocks[i] = {"type": cb.get("type"), "name": cb.get("name") or "tool", "json": ""}
                elif et == "content_block_delta":
                    d = e.get("delta") or {}
                    dt = d.get("type")
                    if dt == "text_delta":
                        text(d.get("text") or "", record_delta=True)
                    elif dt == "input_json_delta" and i in blocks:
                        blocks[i]["json"] += d.get("partial_json") or ""
                elif et == "content_block_stop":
                    b = blocks.pop(i, None)
                    if b and b["type"] == "tool_use":
                        activity(b["name"], first_value(b["json"]))
                    else:
                        flush()
                elif et == "error":
                    err = (e.get("error") or {}).get("message") or e.get("message") or "stream error"
                    activity("⚠", err)
                    raw.append(str(err))
            elif t == "result":
                res = j.get("result")
                if isinstance(res, str) and res.strip():
                    final = [res]
                elif j.get("is_error"):
                    errs = j.get("errors")
                    msg = "; ".join(str(x) for x in errs) if isinstance(errs, list) and errs else (res or "error")
                    activity("⚠", msg)
                    raw.append(str(msg))
            elif t == "error":
                err = (j.get("error") or {}).get("message") or j.get("message") or "error"
                activity("⚠", err)
                raw.append(str(err))

        elif agent == "agy":
            ev = j.get("event")
            if ev == "step_update":
                su = j.get("step_update") or {}
                st = su.get("step_type")
                if st == "tool" and su.get("state") == "ACTIVE":
                    ti = su.get("tool_info") or {}
                    name = su.get("tool_name") or ti.get("name") or "tool"
                    activity(name, first_value(ti.get("parameters") or {}))
                elif st == "agent_response":
                    if su.get("text_delta"):
                        text(su["text_delta"], record_delta=True)
                    if su.get("state") == "DONE":
                        flush()
            elif ev == "result":
                r = j.get("result") or {}
                ans = r.get("response") or r.get("error") or r.get("status") or ""
                if ans:
                    final = [ans]
            elif ev == "error":
                err = j.get("error") or j.get("message") or "error"
                activity("⚠", err)
                raw.append(str(err))

        elif agent == "codex":
            m = j.get("msg")
            if isinstance(m, dict):
                t = m.get("type")
                if t == "agent_message":
                    msg = m.get("message") or ""
                    text(msg + "\n")
                    final.append(msg)
                elif t == "agent_message_delta":
                    text(m.get("delta") or "", record_delta=True)
                elif t == "exec_command_begin":
                    activity("run", format_cmd(m.get("command")))
                elif t == "patch_apply_begin":
                    activity("patch", first_value(m.get("changes") or m))
                elif t == "mcp_tool_call_begin":
                    inv = m.get("invocation") or {}
                    activity(inv.get("tool") or "tool", first_value(inv.get("arguments") or {}))
                elif t in ("background_event", "error", "stream_error"):
                    err = m.get("message") or ""
                    activity("⚠", err)
                    if t in ("error", "stream_error") and err:
                        raw.append(err)
                continue

            # Top-level event schema emitted by newer `codex exec --json` versions
            t = j.get("type")
            item = j.get("item") if isinstance(j.get("item"), dict) else {}
            itype = item.get("type")
            if t == "item.started" and itype == "command_execution":
                activity("run", format_cmd(item.get("command")))
            elif t == "item.completed":
                if itype in ("agent_message", "assistant_message"):
                    msg = item.get("text") or item.get("message") or ""
                    if msg:
                        text(msg + "\n")
                        final.append(msg)
                elif itype == "file_change":
                    changes = item.get("changes")
                    first_path = changes[0].get("path", "") if isinstance(changes, list) and changes and isinstance(changes[0], dict) else ""
                    activity("edit", first_path)
            elif t in ("error", "turn.failed"):
                err = (j.get("error") or {}).get("message") if isinstance(j.get("error"), dict) else (j.get("message") or j.get("error") or "")
                if err:
                    activity("⚠", err)
                    raw.append(str(err))

        elif agent == "gemini":
            msg = j.get("response") or j.get("text") or j.get("message") or ""
            if msg:
                text(str(msg) + "\n")
                final.append(str(msg))
finally:
    flush()
    os.close(fd)

answer = (
    "\n".join(x for x in final if x).strip()
    or "".join(streamed).strip()
    or "\n".join(x for x in raw if x).strip()
)
try:
    with open(outfile, "w", encoding="utf-8") as f:
        f.write(answer + "\n" if answer else "")
except OSError as exc:
    sys.stderr.write(f"knife-stream.py: cannot write {outfile!r}: {exc}\n")
    sys.exit(1)
