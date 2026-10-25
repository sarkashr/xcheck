#!/usr/bin/env python3
"""successor.py — start ONE successor Claude Code session for a handed-off xcheck loop and watch it.

Started fully detached by spawn-successor.sh. It runs the
extension's own headless shape (stream-json in and out, stdin held open, so background Codex rounds finish and
re-invoke the model), sends the kickoff once, and ends through one bounded finish() on: the successor's `.done`
signals — every loop the session closed, collected by gate(): the commit messages to the clipboard (several under
repo headings), an inbox file under <state>/inbox/, one persistent notification —, its marker turning handed-off
(claim read: acknowledged / hop-cap / nothing → "needs you"), child exit (drained, then the same gate), or quiet with
no codex descendant.
"""
import argparse, fcntl, json, os, re, select, shlex, shutil, signal, subprocess, sys, time, uuid

ap = argparse.ArgumentParser()
for k in ("claim", "sessions-dir", "loop-id", "handoff", "workspace", "log-file", "stage", "phase", "thread", "hop", "execpath", "spawn-dir"):
    ap.add_argument("--" + k, required=True)
ap.add_argument("--add-dir", action="append", default=[])
ap.add_argument("--model", default="")    # the parent session's current model and effort (spawn-successor.sh reads them
ap.add_argument("--effort", default="")   # from the parent's transcript); empty = not passed, the settings decide
ap.add_argument("--parent", default="")       # the session that ran the spawn, and the chain's first session: they go into
ap.add_argument("--chain-root", default="")   # the successor's name, its environment and the chain index
ap.add_argument("--session-home", default="")  # where the successor STARTS (its Claude project); empty = the loop's WORKSPACE
ap.add_argument("--tick", type=float, default=float(os.environ.get("SPAWN_TICK_S", "30")))   # SPAWN_TICK_S: the test suite runs in seconds
A = ap.parse_args()
QUIET_S = float(os.environ.get("SPAWN_QUIET_MIN", "10")) * 60
START_S = float(os.environ.get("SPAWN_START_S", "60"))
NOTIFY = os.environ.get("NOTIFY_CMD", "notify-send")
NOTIFY_TIMEOUT_S = float(os.environ.get("SPAWN_NOTIFY_TIMEOUT_S", "10"))
TITLE = "xcheck — waiting on you"   # every launcher notification means the developer must act
sid = str(uuid.uuid4())
t0 = time.time()
base = os.path.join(A.spawn_dir, sid)
marker = os.path.join(A.sessions_dir, f"{sid}.{A.loop_id}")
ev_log = open(base + ".jsonl", "a"); txt_log = open(base + ".log", "a")

def log(kind, obj):
    ev_log.write(json.dumps({"t": round(time.time() - t0, 3), "kind": kind, "ev": obj}) + "\n"); ev_log.flush()
def notify(title, body):   # persistent (critical urgency, no expiry); exactly one notify-rc — or one notify-failed when it cannot run
    log("notify", body)
    try:
        p = subprocess.run([NOTIFY, "-u", "critical", "-a", "xcheck", "-t", "0", title, body], timeout=NOTIFY_TIMEOUT_S, stdin=subprocess.DEVNULL, capture_output=True)
    except Exception as e: log("notify-failed", str(e)); return
    log("notify-rc", {"rc": p.returncode, "stderr": p.stderr.decode("utf-8", "replace")[-200:]})   # decoded first: the logger takes text only
def read_kv(path, before=None):   # line 1 = key=value pairs; lines 2 and 3 (optional) = raw paths that may contain whitespace
    try:                            # before = a wall time: a file written later than it is not yet eligible (it belongs to the next turn)
        with open(path, encoding="utf-8") as f:   # the mtime check and the parse use ONE open file: markers are replaced by rename, so a stat of the path could describe another file than the one read
            if before is not None:
                if os.fstat(f.fileno()).st_mtime > before: return None
                if os.environ.get("SPAWN_READ_PAUSE_S"): time.sleep(float(os.environ["SPAWN_READ_PAUSE_S"]))   # test hook (ir4): the file is replaced between check and parse
            kv = dict(p.split("=", 1) for p in f.readline().split() if "=" in p); kv["_line2"] = f.readline().rstrip("\n"); kv["_line3"] = f.readline().rstrip("\n"); return kv
    except OSError: return None
def kickoff():
    lines = open(A.handoff, encoding="utf-8", errors="replace").read().split("\n")
    i = 0
    while i < len(lines) and not lines[i].startswith("## Kickoff prompt"): i += 1
    while i < len(lines) and not (lines[i].startswith("```") or lines[i].startswith("~~~")): i += 1
    if i >= len(lines): raise ValueError("no kickoff block in the handoff file")
    fence = lines[i][0] * (len(lines[i]) - len(lines[i].lstrip(lines[i][0]))); body = []
    for line in lines[i + 1:]:
        if line.startswith(fence) and line.strip() == line.strip()[0] * len(line.strip()): break
        body.append(line)
    return "\n".join(body).strip("\n")
def clipboard(data):   # data = bytes, passed through unchanged; the same policy as lib.sh's xl__clipboard; always returns a message
    mode = os.environ.get("HANDOFF_CLIPBOARD", "auto")
    if mode == "off": return "not copied (HANDOFF_CLIPBOARD=off)"
    cands = [[mode]] if mode.startswith("/") else [["xclip", "-selection", "clipboard"], ["wl-copy"], ["pbcopy"]]
    for c in cands:
        if not (os.access(c[0], os.X_OK) if c[0].startswith("/") else shutil.which(c[0])): continue
        try:
            subprocess.run(c, input=data, timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
            return f"copied to the clipboard ({os.path.basename(c[0])})"
        except Exception: continue
    return "NOT copied — no working clipboard tool; copy it by hand"
def codex_descendant(root):   # a `codex` process anywhere below the child (the skill launches bash → timeout → codex)
    kids = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit(): continue
        try:
            with open(f"/proc/{pid}/stat") as f: st = f.read()
            comm = st[st.index("(") + 1:st.rindex(")")]; ppid = int(st[st.rindex(")") + 2:].split()[1])
        except (OSError, ValueError): continue
        kids.setdefault(ppid, []).append((int(pid), comm))
    stack = [root]
    while stack:
        for pid, comm in kids.get(stack.pop(), []):
            if comm == "codex": return True
            stack.append(pid)
    return False

deny = [f"Bash(git {v}*)" for v in ("commit", "push", "merge", "rebase", "reset")] + [f"Bash(git * {v}*)" for v in ("commit", "push", "merge", "rebase", "reset")]
cmd = [A.execpath, "-p", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json",
       "--permission-mode", "auto", "--permission-prompts", "none", "--setting-sources=user,project,local",
       "--session-id", sid, "--settings", json.dumps({"permissions": {"deny": deny}})]
for d in A.add_dir: cmd += ["--add-dir", d]
if A.model: cmd += ["--model", A.model]
if A.effort: cmd += ["--effort", A.effort]
env = dict(os.environ); env["XCHECK_HOP"] = A.hop
env["XCHECK_SESSION_HOME"] = A.session_home or A.workspace   # the chain's home: the next hop's spawn starts its successor there too…
env["XCHECK_SESSION_HOME_FOR"] = sid                            # …but only from THIS child session (any other session ignores the value)
for k in ("CLAUDE_CODE_SESSION_ID", "CLAUDE_PID", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN"): env.pop(k, None)
for k in ("SPAWN_MODEL", "SPAWN_EFFORT"): env.pop(k, None)   # (ir9 #1) a manual launch's choice is spent on THIS launch: the successor's own hop reads its transcript
root = A.chain_root or A.parent; name = ""
if A.parent:   # the lineage: a display name for the /resume picker, and the environment the next hop reads its chain root from
    name = f"xcheck hop {A.hop} · {os.path.splitext(os.path.basename(A.log_file))[0]} · parent {A.parent[:8]} · chain {root[:8]}"
    cmd += ["--name", name]; env["XCHECK_PARENT_SESSION"] = A.parent; env["XCHECK_CHAIN_ROOT"] = root
def chain_index():   # one row per STARTED session in <spawn-dir>/chain-<root>.tsv; the first writer adds the header and row 0 (the root)
    p = os.path.join(A.spawn_dir, f"chain-{root}.tsv")
    try:   # every writer appends under ONE exclusive lock, so the header of an empty file and each row never interleave
        with os.fdopen(os.open(p, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600), "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            empty = os.fstat(f.fileno()).st_size == 0
            if os.environ.get("SPAWN_INDEX_PAUSE_S"): time.sleep(float(os.environ["SPAWN_INDEX_PAUSE_S"]))   # test hook (ir7 #2): widens check → write
            if empty:
                f.write("hop\tsession\tparent\tstarted_utc\tmodel\teffort\tloop\tthread\tlog\n" + f"0\t{root}\t-\t-\t-\t-\t{A.loop_id}\t{A.thread}\t-\n")
            f.write(f"{A.hop}\t{sid}\t{A.parent}\t{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\t{A.model or '-'}\t{A.effort or '-'}\t{A.loop_id}\t{A.thread}\t{base}.log\n")
    except OSError as e: log("chain-index-failed", str(e))
home = A.session_home or A.workspace
prefix = "Load the claudex-loop skill first (xcheck-handoff successor). You never run git commit, push, merge, rebase or reset in any spelling — the developer commits. Then:\n"
if home != A.workspace:   # started in the session home (so the developer's editor lists this session); the loop still runs in its WORKSPACE
    prefix += f"This session starts in {home}; the loop's WORKSPACE is {A.workspace} — begin every Bash call of the loop with `cd {shlex.quote(A.workspace)} &&` (the loop's helpers and codex run there).\n"
try: msg = json.dumps({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": prefix + kickoff()}]}}) + "\n"
except (OSError, ValueError) as e:   # read BEFORE the child starts and the claim is acknowledged: the claim stays a reservation, so no watcher counts this hop as started
    log("kickoff-unreadable", str(e)); notify(TITLE, f"successor not started — cannot read the kickoff from {A.handoff} ({e})"); sys.exit(1)
log("start", {"cmd": cmd, "hop": A.hop, "thread": A.thread, "workspace": A.workspace, "session_home": home, "marker": marker, "parent": A.parent, "chain_root": root, "name": name})
try:
    child = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(base + ".stderr", "wb"), env=env, cwd=home)
except Exception as e:
    log("spawn-failed", str(e)); notify(TITLE, f"successor could not start ({e}); see {base}.jsonl"); sys.exit(1)
tmp = A.claim + ".tmp"   # the acknowledgement: same directory, atomic replace — a reader sees the reservation or this, never a mix
with open(tmp, "w") as f: f.write(f"successor={sid} child={child.pid} launcher={os.getpid()} started={int(time.time())} hop={A.hop}\n")
if os.environ.get("SPAWN_ACK_PAUSE_S"): time.sleep(float(os.environ["SPAWN_ACK_PAUSE_S"]))   # test hook (a5): a reader polls during the pause
os.replace(tmp, A.claim)
if A.parent: chain_index()
if os.environ.get("SPAWN_KICKOFF_DELAY_S"): time.sleep(float(os.environ["SPAWN_KICKOFF_DELAY_S"]))   # test hook (k5): the child dies first

last_event = time.time(); fd = child.stdout.fileno(); buf = b""; eof = False; last_kind = ""; result_at = None   # last_kind == "result": the turn ended and no new turn began; result_at = when that result was consumed
def handle(chunk):   # one read of the child's stdout: every complete stream-json line goes to the logs; an empty chunk is EOF
    global buf, eof, last_event, last_kind, result_at
    if not chunk: eof = True; log("eof", {})
    buf += chunk
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        if not line.strip(): continue
        last_event = time.time()
        try: ev = json.loads(line)
        except Exception: log("badjson", line[:200].decode("utf-8", "replace")); continue
        log("event", ev); last_kind = ev.get("type", "")   # any event after a result means a new turn is active
        if last_kind == "result": result_at = time.time()
        if ev.get("type") == "assistant":
            for c in (ev.get("message") or {}).get("content") or []:
                if c.get("type") == "text": txt_log.write(c["text"] + "\n\n"); txt_log.flush()
        if ev.get("type") == "user":
            for c in (ev.get("message") or {}).get("content") or []:
                if isinstance(c, dict) and c.get("type") == "tool_result" and c.get("is_error"): log("tool-denied-or-failed", c)
def drain(limit_s=10):   # what the child still has buffered (bounded) goes through handle(), so its last words reach the logs
    end = time.time() + limit_s
    while not eof and time.time() < end and select.select([fd], [], [], 0.5)[0]:
        handle(os.read(fd, 65536))
def finish(why):
    log("finish", why)
    drain()
    try: child.stdin.close()
    except Exception: pass
    waits = [float(w) for w in os.environ.get("SPAWN_FINISH_WAITS", "60,15,15").split(",")]   # close-wait, TERM-wait, KILL-wait (tests shorten them)
    for sig, wait in ((None, waits[0]), (signal.SIGTERM, waits[1]), (signal.SIGKILL, waits[2])):
        if sig:
            try: child.send_signal(sig)
            except Exception: pass
        try: child.wait(timeout=wait); break
        except subprocess.TimeoutExpired: continue
    rc = child.poll(); log("exit", {"rc": rc}); sys.exit(0 if rc is not None else 2)
GATE_RE = re.compile(r"^" + re.escape(sid) + r"\.([0-9a-f]{16})\.done$")   # this session's loops only: the sid is fresh per successor, a loop id is 16 hex
def gate(before):   # every loop this session closed: each <sid>.<loop>.done eligible under the marker's `before` rule; one `gate` event per run
    try: names = sorted(n for n in os.listdir(A.sessions_dir) if GATE_RE.match(n))
    except OSError: names = []
    entries = []
    for n in names:
        kv = read_kv(os.path.join(A.sessions_dir, n), before)
        if not kv: continue
        loop = GATE_RE.match(n).group(1)
        entries.append({"loop": loop, "outcome": kv.get("outcome", "?"), "kv": kv, "label": os.path.basename(kv["_line3"].rstrip("/")) or loop})   # line 3 = WORKSPACE; an older 1–2-line record → the loop id
    log("gate", {"candidates": len(names), "eligible": len(entries), "before": before})
    return entries
resume_hint = f"resume: /resume in the Claude Code panel of {home} → " + (f'"{name}" (session {sid})' if name else f"session {sid}")   # the editor's picker lists the session (started in `home`, under `name`); never a bare `claude`, which would resolve the terminal CLI from PATH
def deliver(entries):   # the human gate: clipboard, inbox (always, and first, so the popup can name it), ONE notification, finish
    lines, msgs = [], []
    for e in entries:
        tag = f"{e['label']} ({e['loop']})"
        if e["outcome"] == "commit":
            path = e["kv"]["_line2"] or e["kv"].get("payload", "")
            try:
                with open(path, "rb") as f: msgs.append((e["label"], f.read()))   # the exact bytes of the message file
                lines.append(f"- {tag}: commit message ready")
            except OSError as x: lines.append(f"- {tag}: commit message ready — payload unreadable ({x})")
        else: lines.append(f"- {tag}: plan approved — your sign-off is needed")
    nl = lambda b: b if b.endswith(b"\n") else b + b"\n"
    if not msgs: clip = "unchanged (no commit message)"
    elif len(msgs) == 1: clip = clipboard(msgs[0][1])   # one message: byte-exact, as before
    else: clip = clipboard(b"".join(f"=== {l} ===\n".encode() + nl(b) + b"\n" for l, b in msgs))
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    inbox_dir = os.path.join(os.path.dirname(A.sessions_dir), "inbox"); ipath = os.path.join(inbox_dir, f"{stamp}-{sid[:8]}.md")
    head = [f"# {TITLE}", "", f"session: {sid}" + (f" ({name})" if name else ""), f"time: {stamp}", ""] + lines + ["", f"clipboard: {clip}", f"log: {base}.log", resume_hint]
    try:
        os.makedirs(inbox_dir, mode=0o700, exist_ok=True)
        with os.fdopen(os.open(ipath, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as f:
            f.write(("\n".join(head) + "\n").encode())
            for l, b in msgs: f.write(f"\n## {l}\n\n".encode() + nl(b))
        inbox = ipath; log("inbox", ipath)
    except OSError as x: log("inbox-failed", str(x)); inbox = f"NOT written ({x})"
    notify(TITLE, "\n".join(lines + [f"clipboard: {clip}", f"inbox: {inbox}", resume_hint]))
    finish("done:" + "+".join(e["outcome"] for e in entries))
def decide(before=None):   # after a turn's result (before = its consumption time: only earlier signals count) or the quiet timeout (before=None: everything counts)
    entries = gate(before)
    if entries: deliver(entries)
    mk = read_kv(marker, before)
    if mk and mk.get("state") == "handed-off":
        deadline = time.time() + START_S
        while True:
            claim = read_kv(marker + ".spawn/claim")
            if claim and ("successor" in claim or "refused" in claim): finish("handed-off:" + ("next hop " + claim.get("successor", "") if "successor" in claim else claim["refused"]))
            if time.time() >= deadline: break
            time.sleep(min(A.tick, 2.0))
        notify(TITLE, f"session {sid} handed off but no successor started — needs you"); finish("handed-off:no-successor")
try:
    child.stdin.write(msg.encode()); child.stdin.flush(); log("sent", {"bytes": len(msg)})
except (BrokenPipeError, OSError) as e:   # the child died before it could read the kickoff (a rejected flag, a crash)
    log("kickoff-failed", str(e)); notify(TITLE, f"successor {sid} could not receive the kickoff ({e}); see {base}.stderr"); finish("kickoff-failed")
if os.environ.get("SPAWN_LOOP_PAUSE_S"): time.sleep(float(os.environ["SPAWN_LOOP_PAUSE_S"]))   # test hook (k6): the child gates and exits before the first poll

while True:
    if child.poll() is not None:   # drain first: a child that wrote its gate, emitted its result and exited must still reach the developer
        drain(); entries = gate(None)
        if entries: deliver(entries)
        notify(TITLE, f"session {sid} ended (exit {child.returncode}); see {base}.stderr"); finish("child-exit")
    if eof: time.sleep(min(A.tick, 1.0)); r = []
    else: r = select.select([fd], [], [], 0.5 if last_kind == "result" else A.tick)[0]
    if r: handle(os.read(fd, 65536)); continue
    if last_kind == "result":   # quiet for a moment and the LAST event was a result: no turn is active, everything is logged → act on the signals that predate it
        last_kind = ""; decide(result_at)
        continue
    if time.time() - last_event < QUIET_S: continue
    if codex_descendant(child.pid): log("quiet", "codex running"); last_event = time.time(); continue   # bounded by the skill's own timeout
    decide()                                                                                   # a signal without a result → act at the timeout
    notify(TITLE, f"session {sid} needs you — quiet for {int(QUIET_S)} s with no Codex round running"); finish("quiet")
