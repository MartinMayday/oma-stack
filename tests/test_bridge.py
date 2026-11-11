#!/usr/bin/env python3
"""Tests for the oma-stack agent bridge.

Run:  python3 -m unittest discover -s tests -v

No network, no root, no docker.  The only thing that runs is /bin/cat and a
two-line shell script written into a temporary directory.
"""

import json
import os
import shutil
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "components" / "agents"))

import bridge  # noqa: E402


# ---------------------------------------------------------------------------
class FrontmatterTest(unittest.TestCase):
    def test_plain_scalars(self):
        front, body = bridge.parse_frontmatter(
            "---\nid: WI-001-thing\ntitle: A thing\nstatus: open\n---\n\nthe body\n")
        self.assertEqual(front["id"], "WI-001-thing")
        self.assertEqual(front["title"], "A thing")
        self.assertEqual(front["status"], "open")
        self.assertIn("the body", body)
        self.assertNotIn("id:", body)

    def test_quoted_value_keeps_its_spaces(self):
        front, _ = bridge.parse_frontmatter('---\ntitle: "a: b c"\n---\n')
        self.assertEqual(front["title"], "a: b c")

    def test_inline_list(self):
        front, _ = bridge.parse_frontmatter("---\nsubjects: [one, two]\n---\n")
        self.assertEqual(front["subjects"], ["one", "two"])

    def test_block_list(self):
        front, _ = bridge.parse_frontmatter("---\nsubjects:\n  - one\n  - two\n---\n")
        self.assertEqual(front["subjects"], ["one", "two"])

    def test_no_frontmatter_is_all_body(self):
        front, body = bridge.parse_frontmatter("just text\n")
        self.assertEqual(front, {})
        self.assertIn("just text", body)

    def test_unterminated_frontmatter_is_all_body(self):
        text = "---\nid: x\nno end\n"
        front, body = bridge.parse_frontmatter(text)
        self.assertEqual(front, {})
        self.assertEqual(body, text)

    def test_render_round_trip(self):
        data = {"id": "X-1", "title": "T", "status": "done", "subjects": ["a"]}
        front, _ = bridge.parse_frontmatter(bridge.render_frontmatter(data))
        self.assertEqual(front["id"], "X-1")
        self.assertEqual(front["subjects"], ["a"])


# ---------------------------------------------------------------------------
class RegistryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.path = self.tmp / "agents.json"
        self.path.write_text(json.dumps({
            "default": "a",
            "agents": [
                {"name": "a", "command": ["/bin/cat"], "cwd": "/tmp"},
                {"name": "b", "command": []},
            ],
        }))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_load_and_default(self):
        reg = bridge.Registry.load(self.path)
        self.assertEqual(reg.default, "a")
        self.assertEqual(reg.names(), ["a", "b"])

    def test_get_by_name(self):
        reg = bridge.Registry.load(self.path)
        self.assertIsNotNone(reg.get("b"))
        self.assertIsNone(reg.get("nope"))

    def test_get_without_name_returns_the_default(self):
        reg = bridge.Registry.load(self.path)
        self.assertEqual(reg.get(None).name, "a")

    def test_missing_file_raises(self):
        with self.assertRaises(OSError):
            bridge.Registry.load(self.tmp / "nope.json")


# ---------------------------------------------------------------------------
class AgentTest(unittest.TestCase):
    def test_stdin_mode_leaves_the_command_alone(self):
        agent = bridge.Agent({"name": "x", "command": ["/bin/cat"], "prompt_mode": "stdin"})
        self.assertEqual(agent.argv("hello"), ["/bin/cat"])

    def test_arg_mode_appends_the_prompt(self):
        agent = bridge.Agent({"name": "x", "command": ["/bin/echo"], "prompt_mode": "arg"})
        self.assertEqual(agent.argv("hello"), ["/bin/echo", "hello"])

    def test_argv_mode_substitutes_the_placeholder(self):
        agent = bridge.Agent({"name": "x", "command": ["/bin/echo", "{prompt}"],
                              "prompt_mode": "argv"})
        self.assertEqual(agent.argv("hello"), ["/bin/echo", "hello"])


# ---------------------------------------------------------------------------
class RunAgentTest(unittest.TestCase):
    def test_stdout_is_returned_and_streamed(self):
        chunks = []
        agent = bridge.Agent({"name": "cat", "command": ["/bin/cat"], "cwd": "/tmp"})
        out = bridge.run_agent(agent, "hello world", chunks.append)
        self.assertEqual(out, "hello world")
        self.assertEqual("".join(chunks), "hello world")

    def test_arg_mode_receives_the_prompt(self):
        agent = bridge.Agent({"name": "echo", "command": ["/bin/echo"], "prompt_mode": "arg",
                              "cwd": "/tmp"})
        self.assertEqual(bridge.run_agent(agent, "hi", lambda _: None).strip(), "hi")

    def test_a_failing_command_raises(self):
        agent = bridge.Agent({"name": "false", "command": ["/bin/false"], "cwd": "/tmp"})
        with self.assertRaises(bridge.AgentError):
            bridge.run_agent(agent, "x", lambda _: None)

    def test_a_missing_command_raises(self):
        agent = bridge.Agent({"name": "ghost", "command": ["/nonexistent/binary"]})
        with self.assertRaises(bridge.AgentError):
            bridge.run_agent(agent, "x", lambda _: None)

    def test_an_agent_without_a_command_raises(self):
        agent = bridge.Agent({"name": "empty", "command": []})
        with self.assertRaises(bridge.AgentError):
            bridge.run_agent(agent, "x", lambda _: None)


# ---------------------------------------------------------------------------
class LastUserMessageTest(unittest.TestCase):
    def test_the_last_user_message_wins(self):
        messages = [
            {"role": "user", "content": "first"},
            {"role": "assistant", "content": "answer"},
            {"role": "user", "content": "second"},
        ]
        self.assertEqual(bridge.last_user_message(messages), "second")

    def test_a_list_content_is_joined(self):
        messages = [{"role": "user", "content": [{"text": "a"}, {"text": "b"}]}]
        self.assertEqual(bridge.last_user_message(messages), "a\nb")

    def test_no_user_message_is_empty(self):
        self.assertEqual(bridge.last_user_message([]), "")
        self.assertEqual(bridge.last_user_message([{"role": "assistant", "content": "x"}]), "")


# ---------------------------------------------------------------------------
class HttpTest(unittest.TestCase):
    """The AG-UI endpoint, over a real socket."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp())
        for name in ("inbox", "outbox"):
            (cls.tmp / name).mkdir(parents=True, exist_ok=True)
        registry = bridge.Registry([
            bridge.Agent({"name": "echo", "command": ["/bin/cat"], "cwd": "/tmp",
                          "timeout": 30}),
            bridge.Agent({"name": "empty", "command": [], "cwd": "/tmp"}),
        ], "echo")
        bridge.BridgeHandler.registry = registry
        bridge.BridgeHandler.inbox = cls.tmp / "inbox"
        bridge.BridgeHandler.outbox = cls.tmp / "outbox"
        bridge.BridgeHandler.audit_log = cls.tmp / "audit.log"
        bridge.BridgeHandler.logger = staticmethod(lambda msg: None)
        cls.server = bridge.ThreadingHTTPServer(("127.0.0.1", 0), bridge.BridgeHandler)
        cls.server.daemon_threads = True
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def url(self, path):
        return f"http://127.0.0.1:{self.port}{path}"

    def post(self, path, payload):
        request = urllib.request.Request(
            self.url(path),
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status, response.read().decode()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read().decode()

    def get(self, path):
        try:
            with urllib.request.urlopen(self.url(path), timeout=10) as response:
                return response.status, response.read().decode()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read().decode()

    def test_health_lists_the_agents(self):
        status, body = self.get("/health")
        self.assertEqual(status, 200)
        self.assertIn("echo", json.loads(body)["agents"])

    def test_agents_endpoint(self):
        status, body = self.get("/agents")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["agents"][0]["name"], "echo")

    def test_an_unknown_path_is_404(self):
        status, _ = self.get("/nope")
        self.assertEqual(status, 404)

    def test_a_run_streams_the_ag_ui_events(self):
        status, body = self.post("/ag-ui/echo", {
            "threadId": "t1",
            "runId": "r1",
            "messages": [{"id": "m1", "role": "user", "content": "hello there"}],
        })
        self.assertEqual(status, 200)
        for event in ("RUN_STARTED", "TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT",
                      "TEXT_MESSAGE_END", "RUN_FINISHED"):
            self.assertIn(f"event: {event}", body, f"{event} missing from the stream")
        self.assertIn('"delta": "hello there"', body)
        self.assertIn('"threadId": "t1"', body)

    def test_the_default_agent_is_used_when_no_name_is_given(self):
        status, body = self.post("/ag-ui", {
            "messages": [{"role": "user", "content": "ping"}],
        })
        self.assertEqual(status, 200)
        self.assertIn("RUN_FINISHED", body)

    def test_an_unknown_agent_is_404(self):
        status, _ = self.get("/ag-ui/nope")
        self.assertEqual(status, 404)

    def test_an_agent_without_a_command_reports_a_run_error(self):
        status, body = self.post("/ag-ui/empty", {
            "messages": [{"role": "user", "content": "x"}],
        })
        self.assertEqual(status, 200)
        self.assertIn("event: RUN_ERROR", body)

    def test_a_request_without_a_user_message_is_400(self):
        status, _ = self.post("/ag-ui/echo", {"messages": []})
        self.assertEqual(status, 400)

    def test_handoff_queues_a_case(self):
        status, body = self.post("/handoff", {
            "assignee": "echo", "id": "X-1", "title": "T", "body": "do it",
        })
        self.assertEqual(status, 202)
        self.assertEqual(json.loads(body)["queued"], "X-1")
        self.assertTrue((self.tmp / "inbox" / "X-1.md").exists())


# ---------------------------------------------------------------------------
class HandoffWorkerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.inbox = self.tmp / "inbox"
        self.outbox = self.tmp / "outbox"
        self.done = self.tmp / "done"
        self.failed = self.tmp / "failed"
        self.audit = self.tmp / "audit.log"
        for directory in (self.inbox, self.outbox, self.done, self.failed):
            directory.mkdir(parents=True, exist_ok=True)
        self.registry = bridge.Registry([
            bridge.Agent({"name": "echo", "command": ["/bin/cat"], "cwd": "/tmp",
                          "timeout": 30}),
        ], "echo")
        self.worker = bridge.HandoffWorker(
            self.registry, self.inbox, self.outbox, self.done, self.failed, self.audit)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_case(self, name, front, body="the request"):
        path = self.inbox / name
        path.write_text(bridge.render_frontmatter(front) + "\n" + body + "\n")
        return path

    def test_an_assigned_case_is_run_and_written_to_the_outbox(self):
        self.write_case("X-1.md", {"id": "X-1", "title": "T", "status": "open",
                                   "assignee": "echo", "priority": "normal"})
        self.assertEqual(self.worker.drain(), 1)

        result = self.outbox / "X-1.result.md"
        self.assertTrue(result.exists(), "no result file")
        text = result.read_text()
        self.assertIn("status: done", text)
        self.assertIn("the request", text)

        self.assertIn("X-1", self.audit.read_text())
        self.assertTrue((self.done / "X-1.md").exists(), "the case was not filed under done")
        self.assertFalse((self.inbox / "X-1.md").exists())

    def test_a_case_without_an_assignee_is_left_alone(self):
        path = self.write_case("X-2.md", {"id": "X-2", "title": "T", "status": "open"})
        self.assertEqual(self.worker.drain(), 0)
        self.assertTrue(path.exists(), "an unassigned case was taken")

    def test_a_case_that_is_already_done_is_filed_and_not_run(self):
        path = self.write_case("X-3.md", {"id": "X-3", "status": "done", "assignee": "echo"})
        self.assertEqual(self.worker.drain(), 0)
        self.assertFalse(path.exists())
        self.assertTrue((self.done / "X-3.md").exists())

    def test_an_unknown_assignee_fails_the_case(self):
        self.write_case("X-4.md", {"id": "X-4", "status": "open", "assignee": "ghost"})
        self.assertEqual(self.worker.drain(), 1)
        self.assertTrue((self.failed / "X-4.md").exists(), "the case was not filed under failed")
        self.assertIn("error", self.audit.read_text())

    def test_the_prompt_carries_the_case(self):
        front = {"id": "X-5", "title": "T", "assignee": "echo", "priority": "high"}
        prompt = bridge.build_prompt(front, "the request")
        self.assertIn("X-5", prompt)
        self.assertIn("the request", prompt)
        self.assertIn("echo", prompt)
        self.assertIn("without a human saying so first", prompt)


if __name__ == "__main__":
    unittest.main()
