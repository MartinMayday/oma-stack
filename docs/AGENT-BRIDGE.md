# AGENT-BRIDGE — OpenBot ↔ your local agents

The bridge is one process with two jobs.

```
OpenBot ──AG-UI/SSE──► bridge ──stdin/argv──► qoder → glm → minimax
                            │
                            └── watches the handoff inbox, writes answers
                                to the outbox, logs to audit.log
```

**It never merges, deploys, or changes a credential.** A case is run, the
answer is written down, and a human decides what happens next. That is the
rule the agent-library's own `AGENTS.md` sets for handoffs, and the bridge
follows it.

---

## 1. The registry

`/etc/oma-stack/agents.json`, mode 0600:

```json
{
  "default": "qoder",
  "chain": ["qoder", "glm", "minimax", "echo"],
  "agents": [
    {
      "name": "qoder",
      "description": "Primary engineer agent — the Qoder CLI.",
      "command": ["qoder", "-p", "--no-session-persistence", "{prompt}"],
      "cwd": "/home/martin/agent-library",
      "timeout": 1800,
      "prompt_mode": "argv"
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `name` | the name a case file addresses with `assignee:` |
| `command` | the program that runs the agent. `[]` means "listed but not runnable" |
| `cwd` | where it runs |
| `timeout` | seconds before the run is abandoned |
| `prompt_mode` | `stdin` (default), `arg`, or `argv` |
| `env` | extra environment for the agent |
| `chain` | the routing order — see §3 |
| `default` | the agent that answers first |

`prompt_mode`:

- **stdin** — the prompt is written to the agent's stdin, which is then
  closed. The agent reads the whole prompt.
- **arg** — the prompt is appended as the last argument.
- **argv** — `{prompt}` in any argument is replaced by the prompt.

Check the registry without starting anything:

```bash
python3 /opt/oma-stack/components/agents/bridge.py \
  --registry /etc/oma-stack/agents.json --check
```

After editing it:

```bash
sudo systemctl restart oma-agent-bridge.service
```

### The commands that are already proven

The three real agents are the ones this box already has, and their commands
come from the agent-library's own receipts rather than from guesswork:

| Agent | Command | Evidence in agent-library |
|---|---|---|
| `qoder` | `qoder -p --no-session-persistence "<prompt>"` | `catalogs/skills/canonical/qoder-bridge/SKILL.md:57` |
| `glm` | `claude -p "<prompt>"` (Claude Code on `zai/glm-5.3`) | `sessions/labs/staging/WI-006-smart-ai-router-angr8/Cases/angr8-003-lang-gate-router/ops/VERIFICATION.md:100` |
| `minimax` | `codex exec --skip-git-repo-check -m minimax-io/MiniMax-M3.1-Flash "<prompt>"` | `…/receipts/2026-11-07-upgrade-v250.md:32` |

The installer checks which of those binaries are on the PATH, **disables the
entries it cannot run** (the entry keeps its name and gains a
`disabled_reason`), and picks the first runnable agent as the default. An
agent that is not installed is a normal state, not an error.

One caveat worth keeping in view: `qoder -p` can exit 0 on an error, so the
exit code alone is not proof that the agent did the work.

---

## 2. The AG-UI endpoint

Each agent gets one URL:

```
http://host.docker.internal:8765/ag-ui/<name>
```

`host.docker.internal` is how the OpenBot **container** reaches the host.
From the host itself it is `http://127.0.0.1:8765/ag-ui/<name>`.

The endpoint speaks AG-UI over SSE:

| Event | When |
|---|---|
| `RUN_STARTED` | the run began |
| `TEXT_MESSAGE_START` | the answer begins |
| `TEXT_MESSAGE_CONTENT` | one chunk of the answer (`delta`) |
| `CUSTOM` (`name: heartbeat`) | the agent is working but has said nothing yet |
| `TEXT_MESSAGE_END` | the answer ends |
| `RUN_FINISHED` | the run ended (`result` holds the whole answer, `agent` names who answered) |
| `RUN_ERROR` | the agent failed; `message` says why |

The heartbeat matters more than it looks. OpenBot ends a turn when the
stream says nothing for `AGENT_STALL_TIMEOUT_MS` (the kit raises it to five
minutes; upstream's default is one). A CLI agent is silent for the whole
model latency, so the bridge sends a `CUSTOM` event every 15 seconds while
it waits. Turn it off with `AGENT_BRIDGE_HEARTBEAT_SECONDS=0`.

Try it without OpenBot:

```bash
curl -N -X POST http://127.0.0.1:8765/ag-ui/echo \
  -H 'Content-Type: application/json' \
  -d '{"threadId":"t1","runId":"r1","messages":[{"role":"user","content":"hello"}]}'
```

### Who may call the bridge

The bridge binds `0.0.0.0`, because the OpenBot container reaches it
through the Docker bridge gateway. That also puts it on the LAN, so every
request is checked: the **peer address of the socket** — never a
forwarded header, which anybody can write — has to be on the allowlist.

```
127.0.0.1/32    your own tools
::1/128        the same over IPv6
172.16.0.0/12  docker networks (the OpenBot container)
100.64.0.0/10  the tailnet (only if you publish the bridge over it)
```

Anything else gets `403 {"error":"forbidden"}`. The LAN is deliberately
absent, so a device on the wifi cannot run your agents. Change the list in
`/etc/oma-stack/host.env` (`AGENT_BRIDGE_ALLOWED_IPS`) and restart the
bridge.

### Why the allowlist in OpenBot matters

`AGENT_ENDPOINT_ALLOWED_HOSTS` lists the **private addresses an agent may
be registered at**. It is not a restriction on public addresses. The format
is `host` or `host:port`, comma separated, with no scheme, no path and no
wildcards — a URL or a `*` there stops OpenBot from starting, naming the
entry. The match is exact against the hostname of the registered URL.

The installer fills it in:

```
AGENT_ENDPOINT_ALLOWED_HOSTS=host.docker.internal:8765,172.17.0.1:8765
```

Both spellings are there on purpose: the name the container uses, and the
address that name resolves to. Add more by hand in
`/etc/oma-stack/openbot.env`, then:

```bash
sudo systemctl restart oma-openbot.service
```

The agent URL you register in OpenBot has to use one of those names:

```
http://host.docker.internal:8765/ag-ui/qoder
```

Inside the container `127.0.0.1` is the container, not this machine, so a
loopback URL can never reach the bridge.

The image runs in production mode, where `AGENT_COMPUTER_ALLOW_PRIVATE_HOSTS`
is refused. The allowlist is the supported way to name a private agent.

---

## 3. The routing chain

The registry carries a `chain`. The default agent answers first; when it
fails, the next one takes over, and so on. The order is
`qoder → glm → minimax → echo` — `echo` is `/bin/cat`, and it is the proof
that the bridge works at all.

The chain is **serial**, not a fan-out: this box has two cores and 8 GB of
RAM, and two model calls at once starve each other.

Every answer says who produced it:

```json
{"type":"RUN_FINISHED","threadId":"t1","runId":"r1","result":"…","agent":"glm"}
```

`agent` is the agent that actually answered, which may not be the one that
was asked for. When an agent fails, the handoff audit line records the
fallback as well:

```
2026-11-11T19:04:12Z case=WI-014-rotate-the-token agent=qoder ok=false
  (answered by 'glm' after 'qoder' failed)
```

A request for an agent the registry does not know is refused with `404`
and the list of names that do exist. A request for an agent that is known
but not runnable falls through the chain instead of failing.

---

## 4. The handoff queue

```
/var/lib/oma-stack/handoff/
├── inbox/      a case lands here
├── outbox/     the answer lands here
├── done/       the case, after it ran
├── failed/     the case, after it failed
└── audit.log   one line per run
```

Drop a case in the inbox:

```markdown
---
id: WI-014-rotate-the-token
parent: WI-009-audit
title: Rotate the deploy token
status: open
priority: high
assignee: qoder
subjects: [security]
created: 2026-11-11T18:00:00
due: 2026-11-18
completed:
---

The deploy token in Vault is 90 days old. Write the rotation steps.
```

The worker picks it up, runs the agent named in `assignee`, and writes:

- `/var/lib/oma-stack/handoff/outbox/WI-014-rotate-the-token.result.md` —
  the same frontmatter with `status: done` and a `completed` stamp, plus the
  answer under `## Answer`.
- `/var/lib/oma-stack/handoff/done/WI-014-rotate-the-token.md` — the case
  itself, filed.
- one line in `audit.log`: timestamp, agent, case id, ok/error, detail.

A case with no `assignee` is left alone. A case that is already `done` is
filed under `done/` without being run. A case naming an agent the registry
does not know is filed under `failed/` with the reason.

The same thing over HTTP:

```bash
curl -X POST http://127.0.0.1:8765/handoff \
  -H 'Content-Type: application/json' \
  -d '{"assignee":"qoder","id":"WI-015-x","title":"t","body":"b"}'
```

---

## 5. Wiring a real agent

The bridge runs a program. It does not care which one, as long as it reads
the prompt and writes the answer to stdout.

For an agent that takes a prompt as an argument:

```json
{
  "name": "glm",
  "command": ["claude", "-p", "{prompt}"],
  "cwd": "/home/martin/agent-library",
  "timeout": 1800,
  "prompt_mode": "argv"
}
```

For one that reads stdin:

```json
{
  "name": "echo",
  "command": ["/bin/cat"],
  "cwd": "/tmp",
  "timeout": 60,
  "prompt_mode": "stdin"
}
```

The bridge runs as the operator's account, so the agent's own sessions and
credentials are the ones it expects.

---

## 6. Where the agents come from

`agent-library` carries ~200 Hermes personas under
`catalogs/agents/bot-persona/{team,specialist,dark-factory}`. To install
them:

```bash
hermes profile install \
  /home/martin/agent-library/catalogs/agents/bot-persona/dark-factory/<name> \
  --name <name>
```

To have the kit do it for you, point the config at the catalog:

```bash
# /etc/oma-stack/host.env
HERMES_PERSONA_SOURCE="/home/martin/agent-library/catalogs/agents/bot-persona"
```

and re-run `sudo /opt/oma-stack/components/tooling/install-tooling.sh`.

---

## 7. The boundary

| The bridge does | The bridge does not |
|---|---|
| run an agent and stream the answer | merge anything |
| write the answer to the outbox | open a pull request |
| write an audit line | deploy anything |
| accept a case into the inbox | read or write a credential |
| answer OpenBot's calls | decide what a Bot is allowed to do |

OpenBot owns the policy, the audit trail and the tool grants. The bridge is
a transport. Keeping that line sharp is what makes the arrangement safe to
run unattended on a laptop.
