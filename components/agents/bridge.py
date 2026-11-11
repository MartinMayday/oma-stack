#!/usr/bin/env python3
"""oma-stack agent bridge.

Exposes the local agents (Qoder, GLM, MiniMax, whatever is in the registry)
to OpenBot over AG-UI, and works the handoff queue on disk.

Two jobs, one process:

1. AG-UI endpoint.  POST /ag-ui/<name> runs the named agent and streams the
   answer back as AG-UI text message events over SSE.  OpenBot registers
   these URLs the way it registers any other AG-UI agent.

2. Handoff worker.  Watches HANDOFF_WATCH_DIR for case files (the
   agent-library work-item boxes).  A case that names an assignee is run and
   its answer is written to the outbox, with an audit line.  Nothing is
   merged, deployed or credentialed from here: the answer is a record for a
   human to approve.

Standard library only.  This runs on a minimal Arch box where adding a
Python dependency is a decision, not a detail.

Usage:
    bridge.py --registry /etc/oma-stack/agents.json --port 8765 \\
              --bind 0.0.0.0 --inbox /var/lib/oma-stack/handoff/inbox
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

__version__ = "1.0.0"

# ---------------------------------------------------------------------------
# AG-UI event names
# ---------------------------------------------------------------------------
RUN_STARTED = "RUN_STARTED"
RUN_FINISHED = "RUN_FINISHED"
RUN_ERROR = "RUN_ERROR"
TEXT_MESSAGE_START = "TEXT_MESSAGE_START"
TEXT_MESSAGE_CONTENT = "TEXT_MESSAGE_CONTENT"
TEXT_MESSAGE_END = "TEXT_MESSAGE_END"


# ---------------------------------------------------------------------------
# Frontmatter — the small YAML subset the case files use
# ---------------------------------------------------------------------------
def parse_frontmatter(text: str) -> Tuple[Dict[str, Any], str]:
    """Split `---` frontmatter from the body.

    Handles the shape the agent-library case files use: `key: value` scalars,
    quoted scalars, and inline or block lists.  Anything more exotic is left
    as a string rather than guessed at.
    """
    if not text.startswith("---"):
        return {}, text
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}, text
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        return {}, text

    data: Dict[str, Any] = {}
    key: Optional[str] = None
    for line in lines[1:end]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        stripped = line.strip()
        if stripped.startswith("- ") and key:
            data.setdefault(key, [])
            if isinstance(data[key], list):
                data[key].append(_scalar(stripped[2:].strip()))
            continue
        if ":" not in stripped:
            continue
        key, _, raw = stripped.partition(":")
        key = key.strip()
        raw = raw.strip()
        if raw == "":
            data[key] = []
        elif raw.startswith("[") and raw.endswith("]"):
            inner = raw[1:-1].strip()
            data[key] = [_scalar(p.strip()) for p in inner.split(",") if p.strip()] if inner else []
        else:
            data[key] = _scalar(raw)
    body = "\n".join(lines[end + 1:])
    return data, body


def _scalar(raw: str) -> Any:
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
        return raw[1:-1]
    if raw in ("true", "True"):
        return True
    if raw in ("false", "False"):
        return False
    if re.fullmatch(r"-?\d+", raw):
        return int(raw)
    return raw


def render_frontmatter(data: Dict[str, Any]) -> str:
    out = ["---"]
    for key, value in data.items():
        if isinstance(value, list):
            out.append(f"{key}: [{', '.join(str(v) for v in value)}]")
        else:
            out.append(f"{key}: {value}")
    out.append("---")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------
class Agent:
    def __init__(self, spec: Dict[str, Any]):
        self.name: str = spec.get("name") or "agent"
        self.description: str = spec.get("description") or ""
        self.command: List[str] = list(spec.get("command") or [])
        self.cwd: str = spec.get("cwd") or os.getcwd()
        self.timeout: int = int(spec.get("timeout") or 900)
        self.prompt_mode: str = spec.get("prompt_mode") or "stdin"
        self.env: Dict[str, str] = dict(spec.get("env") or {})

    def argv(self, prompt: str) -> List[str]:
        if self.prompt_mode == "arg":
            return self.command + [prompt]
        if self.prompt_mode == "argv":
            return [part.replace("{prompt}", prompt) for part in self.command]
        return list(self.command)

    def public(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "timeout": self.timeout,
            "prompt_mode": self.prompt_mode,
        }


class Registry:
    def __init__(self, agents: List[Agent], default: Optional[str]):
        self.agents = agents
        self.default = default or (agents[0].name if agents else None)

    @classmethod
    def load(cls, path: Path) -> "Registry":
        raw = json.loads(path.read_text())
        agents = [Agent(spec) for spec in raw.get("agents", [])]
        default = raw.get("default")
        return cls(agents, default)

    def get(self, name: Optional[str]) -> Optional[Agent]:
        if not name:
            name = self.default
        for agent in self.agents:
            if agent.name == name:
                return agent
        return None

    def names(self) -> List[str]:
        return [a.name for a in self.agents]


# ---------------------------------------------------------------------------
# Running an agent
# ---------------------------------------------------------------------------
class AgentError(Exception):
    pass


def run_agent(agent: Agent, prompt: str, on_chunk) -> str:
    """Run the agent, streaming its output through `on_chunk`.

    Returns the whole answer.  Raises AgentError when the agent fails or
    runs past its timeout.
    """
    argv = agent.argv(prompt)
    if not argv:
        raise AgentError(f"agent '{agent.name}' has no command")

    env = os.environ.copy()
    env.update(agent.env)
    env.setdefault("PYTHONUNBUFFERED", "1")

    try:
        proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=agent.cwd if os.path.isdir(agent.cwd) else None,
            env=env,
            text=True,
            bufsize=1,
        )
    except FileNotFoundError:
        raise AgentError(f"agent '{agent.name}': command not found: {argv[0]}")
    except OSError as exc:
        raise AgentError(f"agent '{agent.name}': {exc}")

    # The prompt goes in on stdin, and stdin is always closed: an agent that
    # reads stdin must see the end of it rather than wait forever.
    if agent.prompt_mode == "stdin":
        try:
            proc.stdin.write(prompt)
        except (BrokenPipeError, OSError):
            pass
    try:
        proc.stdin.close()
    except (BrokenPipeError, OSError):
        pass

    collected: List[str] = []
    stderr_chunks: List[str] = []

    def drain_stderr() -> None:
        try:
            for line in proc.stderr:
                stderr_chunks.append(line)
        except (OSError, ValueError):
            pass

    err_thread = threading.Thread(target=drain_stderr, daemon=True)
    err_thread.start()

    deadline = time.monotonic() + agent.timeout
    timed_out = False
    try:
        for line in proc.stdout:
            if time.monotonic() > deadline:
                timed_out = True
                break
            collected.append(line)
            on_chunk(line)
    except (OSError, ValueError):
        pass
    finally:
        if timed_out:
            proc.kill()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        for pipe in (proc.stdout, proc.stderr):
            try:
                pipe.close()
            except (OSError, ValueError):
                pass

    stderr_text = "".join(stderr_chunks).strip()
    if timed_out:
        raise AgentError(f"agent '{agent.name}' timed out after {agent.timeout}s")
    rc = proc.returncode
    if rc != 0:
        detail = stderr_text or f"exit code {rc}"
        raise AgentError(f"agent '{agent.name}' failed: {detail}")
    return "".join(collected)


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------
class BridgeHandler(BaseHTTPRequestHandler):
    server_version = f"oma-agent-bridge/{__version__}"
    protocol_version = "HTTP/1.1"

    # injected by the server
    registry: Registry
    inbox: Path
    outbox: Path
    audit_log: Path
    logger = staticmethod(lambda msg: None)

    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: D102
        self.logger(f"{self.address_string()} {fmt % args}")

    # -- helpers ---------------------------------------------------------
    def _json(self, code: int, payload: Any) -> None:
        body = json.dumps(payload, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> Dict[str, Any]:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode() or "{}")
        except (ValueError, UnicodeDecodeError):
            return {}

    def _sse_start(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

    def _sse_event(self, event_type: str, data: Dict[str, Any]) -> None:
        payload = json.dumps({"type": event_type, **data})
        chunk = f"event: {event_type}\ndata: {payload}\n\n".encode()
        self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
        self.wfile.flush()

    def _sse_end(self) -> None:
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    # -- routes ----------------------------------------------------------
    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?")[0].rstrip("/") or "/"
        if path in ("/", "/health"):
            self._json(200, {
                "status": "ok",
                "version": __version__,
                "default_agent": self.registry.default,
                "agents": self.registry.names(),
            })
        elif path == "/agents":
            self._json(200, {"agents": [a.public() for a in self.registry.agents]})
        else:
            self._json(404, {"error": "not found", "path": path})

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?")[0].rstrip("/") or "/"
        if path == "/handoff":
            self._handle_handoff()
            return
        if path == "/ag-ui" or path.startswith("/ag-ui/"):
            name = path[len("/ag-ui/"):] if path.startswith("/ag-ui/") else None
            self._handle_ag_ui(name)
            return
        self._json(404, {"error": "not found", "path": path})

    # -- AG-UI run -------------------------------------------------------
    def _handle_ag_ui(self, name: Optional[str]) -> None:
        payload = self._read_json()
        thread_id = payload.get("threadId") or str(uuid.uuid4())
        run_id = payload.get("runId") or str(uuid.uuid4())
        prompt = last_user_message(payload.get("messages") or [])

        agent = self.registry.get(name)
        if agent is None:
            self._json(404, {"error": "unknown agent", "agent": name,
                             "known": self.registry.names()})
            return
        if not prompt:
            self._json(400, {"error": "no user message in the request"})
            return

        message_id = f"msg_{uuid.uuid4().hex[:12]}"
        self._sse_start()
        self._sse_event(RUN_STARTED, {"threadId": thread_id, "runId": run_id})
        self._sse_event(TEXT_MESSAGE_START, {"messageId": message_id, "role": "assistant"})

        answer_parts: List[str] = []

        def on_chunk(text: str) -> None:
            answer_parts.append(text)
            self._sse_event(TEXT_MESSAGE_CONTENT, {"messageId": message_id, "delta": text})

        try:
            answer = run_agent(agent, prompt, on_chunk)
            self._sse_event(TEXT_MESSAGE_END, {"messageId": message_id})
            self._sse_event(RUN_FINISHED, {
                "threadId": thread_id, "runId": run_id, "result": answer,
            })
        except AgentError as exc:
            self._sse_event(RUN_ERROR, {"message": str(exc), "code": "AGENT_FAILED"})
        except Exception as exc:  # noqa: BLE001 - never kill the stream
            self._sse_event(RUN_ERROR, {"message": str(exc), "code": "BRIDGE_ERROR"})
        finally:
            self._sse_end()

    # -- handoff ---------------------------------------------------------
    def _handle_handoff(self) -> None:
        payload = self._read_json()
        assignee = (payload.get("assignee") or "").strip()
        if not assignee:
            self._json(400, {"error": "assignee is required"})
            return
        case_id = (payload.get("id") or f"case-{uuid.uuid4().hex[:8]}")
        title = payload.get("title") or case_id
        body = payload.get("body") or ""
        try:
            path = self.inbox / f"{case_id}.md"
            front = {
                "id": case_id,
                "parent": payload.get("parent") or "",
                "title": title,
                "status": "open",
                "priority": payload.get("priority") or "normal",
                "assignee": assignee,
                "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "due": payload.get("due") or "",
                "completed": "",
            }
            path.write_text(render_frontmatter(front) + "\n" + body + "\n")
        except OSError as exc:
            self._json(500, {"error": str(exc)})
            return
        self._json(202, {"queued": case_id, "path": str(path)})


def last_user_message(messages: Iterable[Dict[str, Any]]) -> str:
    text = ""
    for message in messages:
        if message.get("role") == "user":
            content = message.get("content")
            if isinstance(content, str):
                text = content
            elif isinstance(content, list):
                parts = [p.get("text", "") for p in content if isinstance(p, dict)]
                text = "\n".join(p for p in parts if p)
    return text.strip()


# ---------------------------------------------------------------------------
# Handoff worker
# ---------------------------------------------------------------------------
class HandoffWorker(threading.Thread):
    """Runs the cases that land in the inbox.

    A case is a markdown file with the agent-library frontmatter.  It is run
    when it names an assignee that the registry knows, and the answer is
    written to the outbox.  A case with no assignee, or one that is already
    done, is left alone.
    """

    daemon = True

    def __init__(self, registry: Registry, inbox: Path, outbox: Path,
                 done: Path, failed: Path, audit: Path, poll: int = 10,
                 logger=None):
        super().__init__(name="handoff-worker")
        self.registry = registry
        self.inbox = inbox
        self.outbox = outbox
        self.done = done
        self.failed = failed
        self.audit = audit
        self.poll = poll
        self.logger = logger or (lambda msg: None)
        self._stop = threading.Event()

    def stop(self) -> None:
        self._stop.set()

    def run(self) -> None:  # noqa: D102
        while not self._stop.is_set():
            try:
                self.drain()
            except Exception as exc:  # noqa: BLE001 - the worker must not die
                self.logger(f"handoff worker error: {exc}")
            self._stop.wait(self.poll)

    def drain(self) -> int:
        if not self.inbox.is_dir():
            return 0
        processed = 0
        for path in sorted(self.inbox.glob("*.md")):
            if self._stop.is_set():
                break
            if self.process(path):
                processed += 1
        return processed

    def process(self, path: Path) -> bool:
        try:
            raw = path.read_text()
        except OSError:
            return False
        front, body = parse_frontmatter(raw)
        assignee = str(front.get("assignee") or "").strip()
        status = str(front.get("status") or "").strip().lower()
        case_id = str(front.get("id") or path.stem)

        if not assignee:
            return False
        if status in ("done", "closed", "cancelled", "canceled"):
            self._move(path, self.done)
            return False

        agent = self.registry.get(assignee)
        if agent is None:
            self._record(case_id, assignee, "error", f"unknown agent '{assignee}'")
            self._write_result(case_id, front, body, f"error: unknown agent '{assignee}'")
            self._move(path, self.failed)
            return True

        self._move(path, self.done, name=f"{path.stem}.working.md")   # claim it
        working = self.done / f"{path.stem}.working.md"
        prompt = build_prompt(front, body)
        collected: List[str] = []
        try:
            answer = run_agent(agent, prompt, collected.append)
            self._write_result(case_id, front, body, answer)
            self._record(case_id, assignee, "ok", f"{len(answer)} chars")
            working.replace(self.done / path.name)
        except AgentError as exc:
            self._write_result(case_id, front, body, f"error: {exc}")
            self._record(case_id, assignee, "error", str(exc))
            working.replace(self.failed / path.name)
        return True

    def _write_result(self, case_id: str, front: Dict[str, Any], body: str,
                      answer: str) -> None:
        result_front = dict(front)
        result_front["status"] = "done"
        result_front["completed"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        result_front["result_of"] = case_id
        self.outbox.mkdir(parents=True, exist_ok=True)
        text = render_frontmatter(result_front)
        text += "\n## Answer\n\n" + answer.rstrip() + "\n"
        (self.outbox / f"{case_id}.result.md").write_text(text)

    def _record(self, case_id: str, assignee: str, status: str, detail: str) -> None:
        self.audit.parent.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
        with self.audit.open("a") as fh:
            fh.write(f"{stamp}\t{assignee}\t{case_id}\t{status}\t{detail}\n")

    def _move(self, path: Path, target: Path, name: Optional[str] = None) -> None:
        target.mkdir(parents=True, exist_ok=True)
        destination = target / (name or path.name)
        try:
            path.replace(destination)
        except OSError:
            pass


def build_prompt(front: Dict[str, Any], body: str) -> str:
    """The prompt handed to the agent for a case.

    The case is the whole prompt: what was asked, who it is for, and what
    matters about it.
    """
    lines = [
        f"# Work item {front.get('id', '')}",
        "",
        f"Title:     {front.get('title', '')}",
        f"Assignee:  {front.get('assignee', '')}",
        f"Priority:  {front.get('priority', '')}",
        f"Subjects:  {front.get('subjects', '')}",
        f"Due:       {front.get('due', '')}",
        "",
        "## Request",
        "",
        body.strip(),
        "",
        "## What is expected",
        "",
        "Answer the request above. Do not merge, deploy, or change any",
        "credential without a human saying so first. Your answer is written",
        "to the outbox as a record for a human to approve.",
    ]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="oma-stack agent bridge")
    parser.add_argument("--registry", default="/etc/oma-stack/agents.json")
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--inbox", default="/var/lib/oma-stack/handoff/inbox")
    parser.add_argument("--handoff-root", default="/var/lib/oma-stack/handoff")
    parser.add_argument("--poll", type=int, default=10, help="handoff poll seconds")
    parser.add_argument("--no-handoff", action="store_true")
    parser.add_argument("--check", action="store_true",
                        help="validate the registry and exit")
    args = parser.parse_args(argv)

    registry_path = Path(args.registry)
    if not registry_path.is_file():
        print(f"[fail] no agent registry at {registry_path}", file=sys.stderr)
        return 1
    try:
        registry = Registry.load(registry_path)
    except (OSError, ValueError) as exc:
        print(f"[fail] cannot read {registry_path}: {exc}", file=sys.stderr)
        return 1

    if args.check:
        print(f"registry ok: {len(registry.agents)} agent(s), default={registry.default}")
        for agent in registry.agents:
            missing = [c for c in agent.command[:1] if shutil_which(c) is None]
            flag = " (command not on PATH)" if missing else ""
            print(f"  - {agent.name}: {' '.join(agent.command)}{flag}")
        return 0

    handoff_root = Path(args.handoff_root)
    inbox = Path(args.inbox)
    outbox = handoff_root / "outbox"
    done = handoff_root / "done"
    failed = handoff_root / "failed"
    audit = handoff_root / "audit.log"
    for directory in (inbox, outbox, done, failed):
        directory.mkdir(parents=True, exist_ok=True)

    def logger(message: str) -> None:
        print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] {message}", flush=True)

    BridgeHandler.registry = registry
    BridgeHandler.inbox = inbox
    BridgeHandler.outbox = outbox
    BridgeHandler.audit_log = audit
    BridgeHandler.logger = staticmethod(logger)

    worker = None
    if not args.no_handoff:
        worker = HandoffWorker(registry, inbox, outbox, done, failed, audit,
                               poll=args.poll, logger=logger)
        worker.start()

    server = ThreadingHTTPServer((args.bind, args.port), BridgeHandler)
    server.daemon_threads = True

    def shutdown(signum, frame):  # noqa: ANN001
        logger(f"shutting down (signal {signum})")
        if worker:
            worker.stop()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    logger(f"bridge listening on {args.bind}:{args.port}")
    logger(f"agents: {', '.join(registry.names()) or '(none)'}")
    logger(f"default agent: {registry.default or '(none)'}")
    logger(f"handoff inbox: {inbox}")
    try:
        server.serve_forever()
    finally:
        server.server_close()
    return 0


def shutil_which(name: str) -> Optional[str]:
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(directory) / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


if __name__ == "__main__":
    sys.exit(main())
