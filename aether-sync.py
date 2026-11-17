#!/usr/bin/env python3
"""Register the running FreeLLMAPI and Ollama instances as Aether engineers.

Usage: ./llm status --json | python3 aether-sync.py --aether-dir DIR --run-dir DIR

Uses Aether's own config code (DIR/app.py), so it writes the same ~/.aether-lite files
the desktop and browser apps read. Engineers it manages have "managed": "llm":
  * one per running FreeLLMAPI agent  (model "auto" = FreeLLMAPI's router, the agent's
    unified API key stored in Aether's secrets.json)
  * one per running Ollama instance   (the largest model it has, unless you chose one)
Model, role and lead setting for new engineers come from RUN_DIR/agent-defaults.json, which the
panel's Model servers tab writes (defaults below when it is missing).
Managed engineers whose instance is no longer running are removed. Edits made in Aether
to a managed engineer (name, model, role, colour, avatar) are kept across syncs.
Engineers you added yourself are left as they are; when one already points at a running
instance (e.g. your own "Agent1" on http://127.0.0.1:3001/v1), no managed engineer is added
for that instance, and the agent's API key is filled in only if yours has none. New engineers
are switched on in every existing session; removed ones are switched off.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import types
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

COLORS = ["#35c9a0", "#5ab8f5", "#e8825f", "#a78bfa", "#f5a524", "#ef6f9a", "#7bd389", "#6fa8ff"]
KEEP = ("name", "model", "role", "color", "avatar", "caps", "args", "lead")
# Small local models make poor team leads (they plan the wrong thing), so Ollama engineers never lead by default.
DEFAULTS = {"freellm": {"model": "auto", "role": "Software Engineer", "lead": ""},
            "ollama": {"model": "", "role": "Assistant · local model", "lead": "never"}}


def load_defaults(run_dir: Path) -> dict:
    out = {k: dict(v) for k, v in DEFAULTS.items()}
    try:
        saved = json.loads((run_dir / "agent-defaults.json").read_text())
        for svc in out:
            out[svc].update({k: v for k, v in (saved.get(svc) or {}).items() if k in out[svc] and isinstance(v, str)})
    except (OSError, ValueError):
        pass
    return out


def biggest_ollama_model(port: int) -> str:
    """The largest model an Ollama instance has (bigger is usually more capable); "" if it cannot be asked."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/tags", timeout=5) as r:
            models = json.loads(r.read()).get("models") or []
        return max(models, key=lambda m: m.get("size") or 0)["name"] if models else ""
    except Exception:
        return ""


def load_aether(aether_dir: Path):
    try:
        import webview  # noqa: F401
    except ImportError:
        stub = types.ModuleType("webview")
        stub.FOLDER_DIALOG = 20
        sys.modules["webview"] = stub
    sys.path.insert(0, str(aether_dir))
    import app  # noqa: E402
    return app


def local_port(base_url: str) -> int | None:
    """Port of a base URL on this Mac (localhost, 127.0.0.1, ::1), else None."""
    try:
        u = urlparse(base_url or "")
        if u.hostname in ("localhost", "127.0.0.1", "::1"):
            return u.port
    except ValueError:
        pass
    return None


def unified_key(run_dir: Path, port: int) -> str | None:
    db = run_dir / f"agent-{port}" / "data" / "freellmapi.db"
    if not db.exists():
        return None
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
        row = con.execute("SELECT value FROM settings WHERE key = 'unified_api_key'").fetchone()
        con.close()
        return row[0] if row else None
    except sqlite3.Error:
        return None


def wanted(status: dict, run_dir: Path) -> list[tuple[dict, str | None]]:
    """(engineer, api key) for every running instance."""
    out: list[tuple[dict, str | None]] = []
    defaults = load_defaults(run_dir)
    services = {s["name"]: s for s in status.get("services", [])}
    for name, label, avatar in (("freellm", "FreeLLM", "⚡"), ("ollama", "Ollama", "🦙")):
        d = defaults[name]
        svc = services.get(name)
        if not svc:
            continue
        for inst in svc.get("instances", []):
            if inst.get("state") == "stopped":
                continue
            port = inst["port"]
            n = port - svc["basePort"] + 1
            eng = {
                "id": f"llm-{name}-{port}", "name": f"{label} {n}", "provider": "openai_api",
                "base_url": f"http://127.0.0.1:{port}/v1",
                "model": d["model"] or (biggest_ollama_model(port) if name == "ollama" else "auto"),
                "role": d["role"], "color": COLORS[(n - 1) % len(COLORS)], "avatar": avatar, "args": "",
                "lead": d["lead"], "managed": "llm",
            }
            out.append((eng, unified_key(run_dir, port) if name == "freellm" else None))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--aether-dir", required=True, type=Path)
    ap.add_argument("--run-dir", required=True, type=Path)
    args = ap.parse_args()
    status = json.load(sys.stdin)
    app = load_aether(args.aether_dir)

    cfg = app.load_cfg()
    sec = app.load_secrets()
    current = {e["id"]: e for e in cfg["engineers"]}
    # Instances already covered by an engineer you set up yourself.
    own: dict[int, dict] = {}
    for e in cfg["engineers"]:
        port = local_port(e.get("base_url", "")) if e.get("provider") == "openai_api" else None
        if port and e.get("managed") != "llm":
            own.setdefault(port, e)
    want, reused = [], []
    for eng, key in wanted(status, args.run_dir):
        mine = own.get(local_port(eng["base_url"]))
        if mine:
            if key and not sec.get(mine["id"]):
                sec[mine["id"]] = key
            reused.append((eng, mine))
        else:
            want.append((eng, key))
    want_ids = {e["id"] for e, _ in want}

    removed = [e["id"] for e in cfg["engineers"] if e.get("managed") == "llm" and e["id"] not in want_ids]
    added: list[str] = []
    engineers = [e for e in cfg["engineers"] if e["id"] not in removed]
    for eng, key in want:
        old = current.get(eng["id"])
        if old:
            merged = {**eng, **{k: old[k] for k in KEEP if k in old and (old[k] or k != "model")}}   # blank model: use the default
            engineers = [merged if e["id"] == eng["id"] else e for e in engineers]
        else:
            engineers.append(eng)
            added.append(eng["id"])
        if key:
            sec[eng["id"]] = key
        else:
            sec.pop(eng["id"], None)
    for eid in removed:
        sec.pop(eid, None)

    cfg["engineers"] = engineers
    app.save_cfg(cfg)
    app.save_secrets(sec)

    # Switch new engineers on (and removed ones off) in every existing session.
    if added or removed:
        app.init_db()
        with app.db() as c:
            for row in c.execute("SELECT id, settings FROM sessions").fetchall():
                try:
                    st = json.loads(row["settings"] or "{}")
                except ValueError:
                    continue
                active = [i for i in st.get("active", []) if i not in removed]
                active += [i for i in added if i not in active]
                if active != st.get("active"):
                    st["active"] = active
                    c.execute("UPDATE sessions SET settings=? WHERE id=?", (json.dumps(st), row["id"]))

    names = {e["id"]: e["name"] for e in engineers}
    print(f"Aether engineers synced: {len(want) + len(reused)} from running instances"
          + (f"; added {', '.join(names[i] for i in added)}" if added else "")
          + (f"; removed {', '.join(removed)}" if removed else ""))
    for eng, key in want:
        e = next(x for x in engineers if x["id"] == eng["id"])
        note = "" if key or not eng["id"].startswith("llm-freellm") else "  (no API key found: open this agent's dashboard once)"
        print(f"  {e['avatar']} {e['name']:<10} {eng['base_url']}  model={e.get('model') or '(first listed)'}{note}")
    for eng, mine in reused:
        print(f"  {mine.get('avatar') or '◆'} {mine['name']:<10} {mine['base_url']}  (your engineer; used as is)")
    print("Reload the chat page to see the changes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
