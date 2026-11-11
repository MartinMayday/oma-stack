# AGENT-BRIDGE — OpenBot ↔ your local agents

The bridge is one process with two jobs.

```
OpenBot ──AG-UI/SSE──► bridge ──stdin──► qoder / glm / minimax
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
  "agents": [
    {
      "name": "qoder",
      "description": "Primary engineer agent.",
      "command": ["hermes", "run", "--agent", "qoder"],
      "cwd": "/home/martin/agent-library",
      "timeout": 1800,
      "prompt_mode": "stdin"
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
| `TEXT_MESSAGE_END` | the answer ends |
| `RUN_FINISHED` | the run ended (`result` holds the whole answer) |
| `RUN_ERROR` | the agent failed; `message` says why |

Try it without OpenBot:

```bash
curl -N -X POST http://127.0.0.1:8765/ag-ui/echo \
  -H 'Content-Type: application/json' \
  -d '{"threadId":"t1","runId":"r1","messages":[{"role":"user","content":"hello"}]}'
```

### Why the allowlist matters

OpenBot will only be pointed at an AG-UI agent whose host is on an exact-match
allowlist — no wildcards, no suffixes, and a URL is refused at startup. The
installer fills it in:

```
AGENT_ENDPOINT_ALLOWED_HOSTS=host.docker.internal:8765,172.17.0.1:8765
```

Both spellings are there on purpose: the name the container uses, and the
address that name resolves to. Add more by hand in
`/etc/oma-stack/openbot.env`, then:

```bash
sudo systemctl restart oma-openbot.service
```

The image runs in production mode, where `AGENT_COMPUTER_ALLOW_PRIVATE_HOSTS`
is refused. The allowlist is the supported way to name a private agent.

---

## 3. The handoff queue

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

## 4. Wiring a real agent

The bridge runs a program. It does not care which one, as long as it reads
the prompt and writes the answer to stdout.

For an agent that takes a prompt as an argument:

```json
{
  "name": "qoder",
  "command": ["/home/martin/.local/bin/qoder-cli", "chat"],
  "cwd": "/home/martin/agent-library",
  "timeout": 1800,
  "prompt_mode": "arg"
}
```

For one that reads stdin:

```json
{
  "name": "qoder",
  "command": ["hermes", "run", "--agent", "qoder"],
  "cwd": "/home/martin/agent-library",
  "timeout": 1800,
  "prompt_mode": "stdin"
}
```

The bridge runs as the operator's account, so the agent's own sessions and
credentials are the ones it expects.

---

## 5. Where the agents come from

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

## 6. The boundary

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
