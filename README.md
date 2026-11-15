# Mass

A mass of frogspawn. Every egg is an agent.

**Dashboard:** https://torothefrog.github.io/mass/

Mass is a mobile-first page that shows what your agents are doing right
now: working, idle, waiting on something, or offline. It is a **public app
with private instances**: anyone can open the dashboard, create their own
instance, pair only their own agents, and nobody else can read it. No
accounts, no server of your own, no git access needed.

## How it works

1. Open the dashboard, tap **connect**, then **Create my instance**. The
   page generates a random instance id and key locally in your browser.
   Nothing is sent anywhere.
2. You get a view link: `.../mass/?i=<id>#k=<key>`, and one command for
   your agents. Give any agent the command plus this README's URL - the
   agent runs it whenever its status changes.
3. Agents publish small encrypted status messages
   (`working` / `idle` / `waiting` / `offline`, one line of text) through a
   public MQTT relay to `mass/<id>/<agent-id>`. The page subscribes to your
   instance's topics and draws one egg per agent. Each agent has its own
   topic, so agents reporting at the same time never overwrite each other.

It is a status board, not a data channel: "needs your attention" and a
short line, not task contents.

## Privacy model (read this before trusting it)

- Messages are encrypted **before** they leave the agent: AES-256-CBC with
  HMAC-SHA256 (encrypt-then-MAC; separate encryption and MAC keys derived
  from your key with SHA-256; fresh random IV per message; the MAC also
  covers the instance id so ciphertext cannot be transplanted between
  instances; a per-agent monotonic sequence number lets readers drop
  replayed older messages). We use this standard composition rather than
  AES-GCM because the openssl command line that agents already have
  provides no AEAD mode; the construction is reviewed in the code, but we
  make no formal security-audit claim.
- The key lives only in the part of your link after `#`, which browsers
  never send to any server, and in the agents you paired. The relay, the
  repo host, and anyone else see only ciphertext, topic names (which
  contain the random instance id), and timing.
- **The key is the only credential.** Anyone who has the full link can
  read the instance AND can publish valid messages as any agent in it.
  There is no per-agent identity or per-agent revocation: to retire a
  compromised instance, create a fresh one and stop using the old link.
  Old messages stay readable to anyone who ever had the old key.
- What this does NOT hide: that your instance exists, how many agents it
  has, when they post, and message sizes.
- The page loads its MQTT client from a file vendored in this repo
  (`mqtt.min.js`), never a CDN, so no third-party script can read the key
  from your link. The page also sends no referrer.

## The relay (and its limits)

Default relay: the Eclipse Foundation's public test broker
`test.mosquitto.org` (MQTT over TLS). Its own terms
(<https://test.mosquitto.org/>): free to use for any application, but
**"do not abuse or rely upon it for anything of importance"**; it warns
that availability and TLS/WebSocket support can be interrupted, that
anyone can publish or subscribe to any topic (your payloads stay
ciphertext, forged ones fail verification), and not to publish anything
sensitive. Treat Mass as a prototype dashboard, not critical monitoring.

The relay is replaceable: point agents at your own broker with
`MASS_BROKER=host:port` and change `BROKER_URL` in `index.html`
(Mosquitto is open source and runs anywhere). If you outgrow the public
relay, that is the upgrade path.

## Connect an agent (about a minute)

```bash
# once, to get the script (or just read it - it is one file):
git clone https://github.com/torothefrog/mass.git
cd mass

# report status - from any directory, any number of times:
MASS_INSTANCE=<your id> MASS_KEY=<your key> \
  ./mass-update.sh --id my-agent --name "My Agent" \
  --state working --message "Reading the tickets sheet"
```

Prerequisites on the agent's machine: bash, python3, openssl. No git, no
GitHub account, no repo access.

- Heartbeat: while active, re-run at least every 5 minutes; entries older
  than 10 minutes render as stale. On shutdown, post `--state offline`.
- Only ever write your own `--id` topic. Keep `name`/`message`/`task`
  short and free of secrets even though payloads are encrypted:
  ciphertext outlives keys, and keys leak.
- `MASS_KEY` is a secret. Never commit it, paste it in chat, or put it in
  a status message.

### States

| state     | meaning                                  | egg looks            |
|-----------|------------------------------------------|----------------------|
| `working` | actively doing something right now       | glowing, pulsing     |
| `idle`    | alive, nothing in flight                 | soft glow            |
| `waiting` | blocked on a human or an external reply  | amber                |
| `offline` | done for now / shut down                 | dim gray             |

## Repo layout

- `index.html` - the whole dashboard (layout, spawn cluster, detail sheet,
  MQTT subscription, WebCrypto decryption).
- `mqtt.min.js` - vendored MQTT.js client (v5.10.1), self-hosted so no
  third-party script can read your key.
- `mass-update.sh` - the agent-side status publisher (stdlib-only MQTT
  over TLS + openssl encryption).
- No build step. GitHub Pages serves the `gh-pages` branch; `main`
  carries the same source.

Browse mode: opened without an instance link, the page shows a clearly
labeled demo cluster with fictional agents. An instance link without its
`#k=` key shows a locked page, never data. Switching links wipes the
previous instance's data from the page.
