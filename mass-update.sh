#!/usr/bin/env bash
# mass-update.sh - post your agent's status to your private Mass instance.
#
# Mass is a public app with private instances. An instance is a random id +
# key from the dashboard's connect button ("Create my instance"). This
# script publishes ONE retained MQTT message to mass/<id>/<your-agent-id>
# on the relay; the payload is encrypted with your key (AES-256-CBC +
# HMAC-SHA256, encrypt-then-MAC; the MAC also covers the instance id and
# your agent id; a per-agent monotonic seq lets readers drop replayed
# older statuses).
#
# Anyone with the key can read AND write every agent in the instance - the
# key is the only credential. Share it only with your own agents. To retire
# an instance, create a fresh one and stop using the old link; old messages
# stay readable to anyone who ever had the old key.
#
# Pairing (first run):
#   The script needs your dashboard link once. Run it with any status and
#   it will ask: "Paste your Mass dashboard link". Paste the WHOLE link
#   (the one with ?i=...#k=...) - the script extracts the id and key
#   itself. You may also paste just the key if this machine already knows
#   the instance id. The pairing is remembered in ~/.mass/pairing
#   (chmod 600), so later runs never ask again. Set MASS_NO_SAVE=1 to
#   skip remembering.
#
#   Non-interactive use: pass MASS_LINK='<full dashboard link>' or
#   MASS_INSTANCE + MASS_KEY. Prefer the prompt when a human is present:
#   secrets typed at a password-style prompt stay out of shell history,
#   argv and logs. Never paste your link or key into a chat message -
#   only into a secure prompt your agent shows you.
#
# Usage:
#   ./mass-update.sh --id my-agent --name "My Agent" --state working \
#       --message "Reading the tickets sheet" [--task "TKT-010"] [--url "https://..."]
#
# States: working | idle | waiting | offline
#   working - actively doing something right now
#   idle    - alive, nothing in flight
#   waiting - blocked on a human or an external reply
#   offline - done for now / shutting down
#
# Heartbeat: while you are active, re-run this at least every 5 minutes.
# Entries older than 10 minutes render as stale on the dashboard.
#
# Needs: bash, python3, openssl. No git, no repo access, no accounts.
# Relay: test.mosquitto.org over TLS by default (public test server, no
# SLA - see README). Override with MASS_BROKER=host:port for your own broker.
#
# Rules:
#   - Only ever write your own --id topic. Never touch other agents.
#   - Keep name/message/task free of secrets and private data even though
#     payloads are encrypted: ciphertext outlives keys, and keys leak.
#   - Keep message short (one line, what you are doing right now).

set -euo pipefail

BROKER="${MASS_BROKER:-test.mosquitto.org:8886}"
INSTANCE="${MASS_INSTANCE:-}"
KEY="${MASS_KEY:-}"
LINK="${MASS_LINK:-}"
ID="" NAME="" STATE="" MESSAGE="" TASK="" URL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --id)       ID="$2"; shift 2;;
    --name)     NAME="$2"; shift 2;;
    --state)    STATE="$2"; shift 2;;
    --message)  MESSAGE="$2"; shift 2;;
    --task)     TASK="$2"; shift 2;;
    --url)      URL="$2"; shift 2;;
    --instance) INSTANCE="$2"; shift 2;;
    --key)      KEY="$2"; shift 2;;
    --link)     LINK="$2"; shift 2;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done

[ -n "$ID" ]    || { echo "--id is required (lowercase letters, digits, dashes)" >&2; exit 2; }
[ -n "$STATE" ] || { echo "--state is required (working|idle|waiting|offline)" >&2; exit 2; }
echo "$ID" | grep -qE '^[a-z0-9][a-z0-9-]{0,39}$' || { echo "--id must match ^[a-z0-9][a-z0-9-]{0,39}$" >&2; exit 2; }
case "$STATE" in working|idle|waiting|offline) ;; *) echo "bad --state: $STATE" >&2; exit 2;; esac
[ -n "$NAME" ] || NAME="$ID"
for tool in python3 openssl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing prerequisite: $tool" >&2; exit 2; }
done

STATE_DIR="${MASS_HOME:-$HOME/.mass}"
PAIRING="$STATE_DIR/pairing"
mkdir -p "$STATE_DIR"

# Parse a dashboard link or bare key. Prints "instance<LF>key"; the
# instance line is empty when the input was only a key.
parse_link() {
  python3 - "$1" <<'PY'
import re, sys
s = sys.argv[1].strip()
inst = ''
m = re.search(r'[?&]i=([A-Za-z0-9_-]{8,64})', s)
if m:
    inst = m.group(1)
k = re.search(r'#k=([A-Za-z0-9_-]{20,64})', s)
if k:
    key = k.group(1)
elif re.fullmatch(r'[A-Za-z0-9_-]{20,64}', s):
    key = s  # bare key
else:
    sys.exit('mass: that does not look like a Mass dashboard link or key')
print(inst)
print(key)
PY
}

load_pairing() {
  [ -f "$PAIRING" ] || return 1
  local pi pk
  pi=$(sed -n 's/^instance=//p' "$PAIRING" | head -1)
  pk=$(sed -n 's/^key=//p' "$PAIRING" | head -1)
  [ -n "$pi" ] && [ -n "$pk" ] || return 1
  [ -n "$INSTANCE" ] || INSTANCE="$pi"
  [ -n "$KEY" ] || KEY="$pk"
}

# Resolve credentials: explicit --instance/--key or env > --link/MASS_LINK
# > saved pairing > interactive prompt.
if [ -z "$INSTANCE" ] || [ -z "$KEY" ]; then
  if [ -n "$LINK" ]; then
    parsed=$(parse_link "$LINK") || { echo "mass: could not read the link" >&2; exit 2; }
    li=$(printf '%s' "$parsed" | sed -n '1p')
    lk=$(printf '%s' "$parsed" | sed -n '2p')
    [ -n "$li" ] && INSTANCE="$li"
    KEY="$lk"
  else
    load_pairing || true
  fi
fi

if [ -z "$INSTANCE" ] || [ -z "$KEY" ]; then
  echo "mass: first run needs your Mass dashboard link." >&2
  echo "mass: get it from the dashboard (connect -> Create my instance)." >&2
  if [ -t 0 ]; then
    # interactive: password-style prompt, no echo, never hits history
    read -rs -p "Paste your Mass dashboard link (input hidden): " entered < /dev/tty || { echo >&2; exit 2; }
    echo >&2
  elif read -t 60 entered; then
    : # piped input
  else
    echo "mass: no terminal - pass MASS_LINK='<full dashboard link>' instead" >&2
    exit 2
  fi
  [ -n "${entered:-}" ] || { echo "mass: empty input" >&2; exit 2; }
  parsed=$(parse_link "$entered") || { echo "mass: could not read the link" >&2; exit 2; }
  entered=""
  li=$(printf '%s' "$parsed" | sed -n '1p')
  lk=$(printf '%s' "$parsed" | sed -n '2p')
  if [ -n "$li" ]; then
    INSTANCE="$li"
  elif [ -z "$INSTANCE" ]; then
    echo "mass: a key alone is not enough on first run - paste the full link once" >&2
    exit 2
  fi
  KEY="$lk"
fi

echo "$INSTANCE" | grep -qE '^[A-Za-z0-9_-]{8,64}$' || { echo "bad instance id" >&2; exit 2; }
echo "$KEY" | grep -qE '^[A-Za-z0-9_-]{20,64}$' || { echo "bad key" >&2; exit 2; }

# Remember the pairing so later runs (and the heartbeat) never ask again.
if [ "${MASS_NO_SAVE:-}" != "1" ]; then
  ( umask 077; printf 'instance=%s\nkey=%s\n' "$INSTANCE" "$KEY" > "$PAIRING.tmp" && mv "$PAIRING.tmp" "$PAIRING" )
fi

UPDATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export MU_BROKER="$BROKER" MU_KEY="$KEY" MU_INSTANCE="$INSTANCE" MU_ID="$ID" MU_NAME="$NAME" \
       MU_STATE="$STATE" MU_MESSAGE="$MESSAGE" MU_TASK="$TASK" MU_URL="$URL" MU_UPDATED="$UPDATED"

python3 - <<'PY'
import base64, hashlib, hmac, json, os, socket, ssl, struct, subprocess, sys, time

# --- crypto (openssl CLI for AES, stdlib for the rest) --------------------
def b64url_decode(s):
    s = s.replace('-', '+').replace('_', '/')
    s += '=' * (-len(s) % 4)
    return base64.b64decode(s)

def b64e(b): return base64.b64encode(b).decode()

raw = b64url_decode(os.environ['MU_KEY'])
enc_key = hashlib.sha256(raw + b':enc').digest()
mac_key = hashlib.sha256(raw + b':mac').digest()
ctx = (os.environ['MU_INSTANCE'] + '/' + os.environ['MU_ID']).encode()

def aes_cbc_encrypt(data, iv):
    p = subprocess.run(
        ['openssl', 'enc', '-e', '-aes-256-cbc', '-K', enc_key.hex(), '-iv', iv.hex()],
        input=data, capture_output=True)
    if p.returncode != 0:
        sys.exit('mass: openssl failed: ' + p.stderr.decode()[:200])
    return p.stdout

# per-agent monotonic seq, kept in a local state file so replays are detectable
state_dir = os.environ.get('MASS_HOME') or os.path.join(os.path.expanduser('~'), '.mass')
os.makedirs(state_dir, exist_ok=True)
state_path = os.path.join(state_dir, 'seq-' + os.environ['MU_INSTANCE'] + '-' + os.environ['MU_ID'])
prev = 0
try:
    prev = int(open(state_path).read().strip())
except Exception:
    pass
seq = max(int(time.time()), prev + 1)

payload = {'seq': seq, 'agent': {
    'id': os.environ['MU_ID'],
    'name': os.environ['MU_NAME'],
    'state': os.environ['MU_STATE'],
    'message': os.environ['MU_MESSAGE'],
    'task': os.environ['MU_TASK'],
    'url': os.environ['MU_URL'],
    'updated': os.environ['MU_UPDATED'],
}}

iv = os.urandom(16)
ct = aes_cbc_encrypt(json.dumps(payload).encode(), iv)
tag = hmac.new(mac_key, ctx + iv + ct, hashlib.sha256).digest()
envelope = json.dumps({'v': 3, 'iv': b64e(iv), 'ct': b64e(ct), 'tag': b64e(tag)}).encode()

# --- minimal MQTT 3.1.1 publish (QoS 0, retained), stdlib only -------------
def enc_varint(n):
    out = b''
    while True:
        d = n % 128; n //= 128
        if n: d |= 128
        out += bytes([d])
        if not n: return out

def enc_str(s):
    b = s.encode()
    return struct.pack('!H', len(b)) + b

host, _, port_s = os.environ['MU_BROKER'].partition(':')
port = int(port_s or '8883')
client_id = 'mass-' + os.environ['MU_ID'] + '-' + str(os.getpid())

connect = enc_str('MQTT') + bytes([4, 0x02]) + struct.pack('!H', 60) + enc_str(client_id)
connect = bytes([0x10]) + enc_varint(len(connect)) + connect

topic = 'mass/' + os.environ['MU_INSTANCE'] + '/' + os.environ['MU_ID']
publish = enc_str(topic) + envelope
publish = bytes([0x31]) + enc_varint(len(publish)) + publish  # QoS 0, retained

ctx_tls = ssl.create_default_context()
with socket.create_connection((host, port), timeout=15) as sock:
    with ctx_tls.wrap_socket(sock, server_hostname=host) as tls:
        tls.sendall(connect)
        ack = tls.recv(4)
        if len(ack) < 4 or ack[0] != 0x20 or ack[3] != 0:
            sys.exit('mass: broker refused the connection')
        tls.sendall(publish)
        tls.sendall(b'\xe0\x00')  # DISCONNECT

with open(state_path, 'w') as f:
    f.write(str(seq))
PY

echo "mass: $ID is $STATE - $MESSAGE"
