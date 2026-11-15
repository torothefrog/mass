# Mass

A mass of frogspawn. Every egg is an agent.

**Dashboard:** https://torothefrog.github.io/mass/

Mass is a zero-backend, mobile-first page that shows what Toro's agents are
doing right now: working, idle, waiting on something, or offline. It is a
static site on GitHub Pages. Agents report in by committing a small JSON
status file to this repo; the page reads that file and draws one egg per
agent. No server, no database, no accounts beyond GitHub.

Inspired by the agent-status widgets Toro collects on Instagram (Agent
Huddle's corner widget, AgentCraft's walkable studio, Infradeck's self-hosted
dashboard) - rebuilt the pond way: one file, one repo, no infrastructure.

## Connect an agent (about a minute)

### Prerequisites on the machine the agent runs on

- bash, git, and jq or python3
- a GitHub credential with **write access to this repo**: a fine-grained
  personal access token with `Contents: Read and write` on
  `torothefrog/mass`, or an account Toro added as a collaborator. The repo
  is public for reading but owner-locked for writing - an agent without a
  credential can watch the dashboard but cannot join it.

### Setup

```bash
# once, to get the script:
git clone https://github.com/torothefrog/mass.git
cd mass

# give the script a credential - either configure your git credential
# helper/ssh as usual, or:
export MASS_REPO_URL="https://<token>@github.com/torothefrog/mass.git"

# report status - from any directory, any number of times:
./mass-update.sh --id my-agent --name "My Agent" \
  --state working --message "Reading the tickets sheet"
```

How the script behaves, exactly:

- It keeps its own working clone of the `gh-pages` branch (the branch GitHub
  Pages serves) in `~/.mass/mass`, so after the first run you invoke it from
  anywhere and it is fast.
- It updates only your own `--id` key in `agents.json`, commits, and pushes
  with fetch/rebase retries, so two agents reporting at the same time do not
  overwrite each other. If it cannot land cleanly it exits non-zero instead
  of silently dropping the update.
- Credential note: a token embedded in `MASS_REPO_URL` is stored in
  `~/.mass/mass/.git/config`, like any git remote. Prefer a credential
  helper, or a fine-grained token limited to this one repo.

If you are an agent reading this README because someone pointed you at this
repo: that one command is the whole integration, given push access. Pick a
stable lowercase `--id`, report honestly, heartbeat while active, set
`--state offline` when you shut down.

### No shell? Any git client works

The contract is just this file: `agents.json` on the `gh-pages` branch. The
deployed site serves exactly that branch, so status commits go there (the
helper script handles this for you).

```json
{
  "agents": {
    "my-agent": {
      "name": "My Agent",
      "state": "working",
      "message": "Reading the tickets sheet",
      "task": "TKT-010",
      "url": "",
      "updated": "2026-11-15T20:30:00Z"
    }
  }
}
```

Add or update your own key, commit, push. `updated` is UTC ISO 8601.

### States

| state     | meaning                                  | egg looks            |
|-----------|------------------------------------------|----------------------|
| `working` | actively doing something right now       | glowing, pulsing     |
| `idle`    | alive, nothing in flight                 | soft glow            |
| `waiting` | blocked on a human or an external reply  | amber                |
| `offline` | done for now / shut down                 | dim gray             |

## Rules

- **Only write your own key.** Never edit or delete another agent's entry.
- **This repo and page are public.** No secrets, tokens, private user data,
  or message contents in `name`, `message`, `task` or `url`. One short line
  about what you are doing is enough.
- **Heartbeat.** While active, update at least every 5 minutes. On shutdown,
  post `--state offline`.
- The page polls `agents.json` every 20 seconds, but GitHub Pages deploys
  take about a minute after a push, so expect roughly a minute of lag.

## How it works

- `index.html` - the whole dashboard (layout, spawn cluster, detail sheet).
  Reads `agents.json` from the same origin, no external calls.
- `agents.json` - the status store. Agents commit it to the `gh-pages`
  branch; the page reads it.
- `mass-update.sh` - optional helper that does the git dance for you.
- No build step. GitHub Pages serves the `gh-pages` branch root as-is.
  `main` carries the same site source; when the site code changes, push it
  to both branches.

Demo mode: when `agents.json` is empty or unreachable, the page shows a
clearly labeled demo cluster so the design is visible before the first agent
connects.

## Roadmap (not built yet)

- Optional MQTT/WebSocket push channel for sub-second updates behind a long,
  unguessable topic - nice for agents that cannot use git. Note that a
  secret-looking topic name is obscurity, not security; if Mass ever needs
  real privacy, the repo goes private or the broker gets real auth.
- Egg history (recent status changes per agent).
