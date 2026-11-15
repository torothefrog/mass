# Mass

A mass of frogspawn. Every egg is an agent.

**Dashboard:** https://torothefrog.github.io/mass/

Mass is a zero-backend, mobile-first page that shows what your agents are
doing right now: working, idle, waiting on something, or offline. It is a
static site on GitHub Pages - and a **public app with private instances**.
You create your own instance from the dashboard's connect button, pair only
your agents with it, and other people's instances stay theirs.

## Privacy model (read this before trusting it)

- Your instance link looks like
  `https://torothefrog.github.io/mass/?i=<instance id>#k=<key>`.
- Everything your agents post is stored **encrypted** at
  `instances/<id>.json` in this repo: AES-256-CBC with HMAC-SHA256
  (encrypt-then-MAC), keys derived from your key with SHA-256.
- The key lives only in the part of the link after `#`. Browsers never send
  the fragment to any server, so GitHub Pages (and anyone reading this
  public repo) ever sees only ciphertext, the random instance id, and
  update times.
- **Reading** an instance requires the full link with the key. Treat the
  link like a password: anyone who has it can read that instance.
- **Writing** requires a GitHub credential with push access to this repo,
  so strangers cannot post to your instance even if they guess its id.
- **Revocation:** to lock someone out, create a fresh instance (new id, new
  key) and stop updating the old one. Old ciphertext stays in git history
  but stays unreadable without its key - so still keep `name`/`message`/
  `task` free of secrets, since ciphertext outlives keys.
- What this does NOT hide: that your instance exists, how often it updates,
  and roughly how big the payload is. An instance id in a link you share is
  visible to anyone you share it with.

This is real encryption, not a secret-looking URL: the stored data is
ciphertext and the decryption key never reaches the server. If you need
stronger guarantees (hidden metadata, server-side access control, audit
logs), Mass would need a real backend, which it deliberately does not have.

## Connect an agent (about a minute)

### 1. Create your instance

Open the dashboard, tap **connect**, then **Create my instance**. The page
generates a random instance id and key locally in your browser - nothing is
sent anywhere - and shows you your view link and the agent command.

### 2. Prerequisites on the machine the agent runs on

- bash, git, python3, openssl
- a GitHub credential with **write access to this repo**: a fine-grained
  personal access token with `Contents: Read and write` on
  `torothefrog/mass`, or a collaborator account. The repo is public for
  reading but owner-locked for writing.

### 3. Report status

```bash
# once, to get the script:
git clone https://github.com/torothefrog/mass.git
cd mass

# give the script a credential - either configure your git credential
# helper/ssh as usual, or:
export MASS_REPO_URL="https://<token>@github.com/torothefrog/mass.git"

# report status - from any directory, any number of times:
MASS_INSTANCE=<your id> MASS_KEY=<your key> \
  ./mass-update.sh --id my-agent --name "My Agent" \
  --state working --message "Reading the tickets sheet"
```

How the script behaves, exactly:

- It keeps its own working clone of the `gh-pages` branch (the branch GitHub
  Pages serves) in `~/.mass/mass`, so after the first run you invoke it from
  anywhere and it is fast.
- It decrypts your instance file with your key, updates only your own
  `--id` entry, re-encrypts, commits, and pushes with fetch/rebase retries,
  so two agents reporting at the same time do not overwrite each other. If
  it cannot land cleanly it exits non-zero instead of silently dropping the
  update.
- `MASS_KEY` is a secret. It is used only locally, to encrypt and decrypt
  your instance file. Do not commit it, paste it in chat, or put it in a
  status message.
- Credential note: a token embedded in `MASS_REPO_URL` is stored in
  `~/.mass/mass/.git/config`, like any git remote. Prefer a credential
  helper, or a fine-grained token limited to this one repo.

### No shell? Any git client works

The contract is just the envelope: `instances/<id>.json` on the `gh-pages`
branch, holding JSON `{"v":1,"iv":...,"ct":...,"tag":...}` where `ct` is
AES-256-CBC ciphertext of the plaintext below, keyed as described above.
`updated` is UTC ISO 8601.

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

### States

| state     | meaning                                  | egg looks            |
|-----------|------------------------------------------|----------------------|
| `working` | actively doing something right now       | glowing, pulsing     |
| `idle`    | alive, nothing in flight                 | soft glow            |
| `waiting` | blocked on a human or an external reply  | amber                |
| `offline` | done for now / shut down                 | dim gray             |

## Rules

- **Only write your own key.** Never edit or delete another agent's entry.
- **Keep it non-private anyway.** No secrets, tokens, private user data, or
  message contents in `name`, `message`, `task` or `url`. Encryption
  reduces exposure; it is not a license to post secrets.
- **Heartbeat.** While active, update at least every 5 minutes. On shutdown,
  post `--state offline`.
- The page polls every 20 seconds, but GitHub Pages deploys take about a
  minute after a push, so expect roughly a minute of lag.

## How it works

- `index.html` - the whole dashboard (layout, spawn cluster, detail sheet,
  instance decryption with WebCrypto). Reads `instances/<id>.json` from the
  same origin, no external calls; the key never leaves the browser.
- `instances/` - per-instance encrypted status stores on the `gh-pages`
  branch.
- `mass-update.sh` - optional helper that does the encrypt-and-git dance.
- No build step. GitHub Pages serves the `gh-pages` branch root as-is.
  `main` carries the same site source; when the site code changes, push it
  to both branches.

Browse mode: opened without an instance link, the page shows a clearly
labeled demo cluster so the design is visible. An instance link without its
`#k=` key shows a locked page, never data.

## Roadmap (not built yet)

- Optional MQTT/WebSocket push channel for sub-second updates, with real
  broker auth per instance.
- Egg history (recent status changes per agent).
