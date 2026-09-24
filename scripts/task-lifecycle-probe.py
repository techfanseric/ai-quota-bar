#!/usr/bin/env python3
"""Timestamped watcher for AIQuotaBar task-lifecycle data sources.
Logs only statuses, ids, counts and mtimes — never message content."""
import json, glob, os, sqlite3, time, collections, sys

HOME = os.path.expanduser("~")
LOG = "/tmp/aqb-probe/observations.log"
POLL = 1.0
ZDB = f"file:{HOME}/.zcode/cli/db/db.sqlite?mode=ro"
KIMI_AGENT = f"{HOME}/Library/Application Support/kimi-desktop/kimi-agent"
CODEX_SESSIONS = f"{HOME}/.codex/sessions"
MM_SESSIONS = f"{HOME}/.minimax/v2/sessions"
MM_BG = f"{HOME}/.minimax/background-tasks"

def newest(path_glob):
    files = glob.glob(path_glob)
    return max(files, key=os.path.getmtime) if files else None

def zcode():
    try:
        db = sqlite3.connect(ZDB, uri=True)
        rows = db.execute(
            "SELECT status, started_at FROM turn_usage ORDER BY started_at DESC LIMIT 3"
        ).fetchall()
        running = db.execute(
            "SELECT COUNT(*) FROM turn_usage WHERE status='running'"
        ).fetchone()[0]
        db.close()
        return {"turns": [f"{s}@{t}" for s, t in rows], "running": running}
    except Exception:
        return {"turns": [], "running": 0}

def kimi():
    out = {}
    try:
        d = json.load(open(f"{KIMI_AGENT}/conversation-statuses.json"))
        out["statuses"] = dict(collections.Counter(d.values()))
    except Exception:
        out["statuses"] = None
    try:
        d = json.load(open(f"{KIMI_AGENT}/conversation-context-usage.json"))
        ages = []
        for v in d.values():
            if isinstance(v, dict) and "updatedAt" in v:
                try:
                    from datetime import datetime
                    t = datetime.fromisoformat(v["updatedAt"].replace("Z", "+00:00"))
                    ages.append(int(time.time() - t.timestamp()))
                except Exception:
                    pass
        out["usage_fresh_sec"] = min(ages) if ages else None
    except Exception:
        out["usage_fresh_sec"] = None
    try:
        out["stopped_blocks"] = len(json.load(open(f"{KIMI_AGENT}/stopped-turn-blocks.json")))
    except Exception:
        out["stopped_blocks"] = 0
    return out

def codex():
    f = newest(f"{CODEX_SESSIONS}/*/*/*/*.jsonl")
    if not f:
        return {}
    try:
        with open(f, "rb") as fh:
            fh.seek(0, 2)
            size = fh.tell()
            fh.seek(max(0, size - 8192))
            tail = fh.read().split(b"\n")
        types = []
        for line in tail:
            if not line.strip():
                continue
            try:
                r = json.loads(line)
                t = r.get("type", "?")
                if t == "event_msg":
                    t += ":" + str(r.get("payload", {}).get("type", "?"))
                types.append(t)
            except Exception:
                pass
        return {"file": f"…{f[-12:]}", "size": size, "tail_types": types[-4:]}
    except Exception:
        return {}

def minimax():
    out = {}
    f = newest(f"{MM_SESSIONS}/*/*/*/*session_*")
    if f:
        try:
            cat = json.load(open(f"{f}/history-catalog.json"))
            out["cli_activeGeneration"] = cat.get("activeGeneration")
        except Exception:
            out["cli_activeGeneration"] = None
    d = newest(f"{MM_BG}/bg_*")
    if d:
        try:
            ages = [time.time() - os.path.getmtime(p)
                    for p in [d, f"{d}/output.log", f"{d}/summary.txt"] if os.path.exists(p)]
            out["bg_newest_age_sec"] = int(min(ages))
        except Exception:
            pass
    return out

def snapshot():
    return {"t": time.strftime("%H:%M:%S"),
            "zcode": zcode(), "kimi": kimi(), "codex": codex(), "minimax": minimax()}

prev = None
deadline = time.time() + float(sys.argv[1] if len(sys.argv) > 1 else 1800)
with open(LOG, "a") as log:
    while time.time() < deadline:
        s = snapshot()
        body = {k: v for k, v in s.items() if k != "t"}
        if body != prev:
            log.write(json.dumps(s, ensure_ascii=False) + "\n")
            log.flush()
            prev = body
            print(json.dumps(s, ensure_ascii=False))
        time.sleep(POLL)
