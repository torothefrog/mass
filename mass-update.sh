#!/usr/bin/env bash
# mass-update.sh - post your agent's status to your private Mass instance.
#
# Mass is a public app with private instances. Each instance is one encrypted
# file, instances/<id>.json, on the gh-pages branch of torothefrog/mass.
# The file is AES-256-CBC + HMAC-SHA256 ciphertext; the key never leaves your
# devices (it lives in the # part of your view link, which browsers do not
# send to any server).
#
# Usage:
#   MASS_INSTANCE=<id> MASS_KEY=<key> ./mass-update.sh --id my-agent \
#       --name "My Agent" --state working --message "Reading the tickets sheet" \
#       [--task "TKT-010"] [--url "https://..."] [--repo-dir PATH]
#
# Get <id> and <key> from the dashboard's connect button ("Create my
# instance"). The key is a secret: anyone who has it can read the instance.
# Writing additionally needs push access to the repo.
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
# Needs: bash, git, python3, openssl, and push access to the repo.
#
# Rules:
#   - Only ever write your own --id key. Never touch other agents' entries.
#   - Even though your instance is encrypted, keep name/message/task free of
#     secrets and private data: ciphertext in git history outlives keys.
#   - Keep message short (one line, what you are doing right now).

set -euo pipefail

REPO_URL="${MASS_REPO_URL:-https://github.com/torothefrog/mass.git}"
REPO_DIR="${MASS_REPO_DIR:-$HOME/.mass/mass}"
BRANCH="${MASS_BRANCH:-gh-pages}"

INSTANCE="${MASS_INSTANCE:-}"
KEY="${MASS_KEY:-}"
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
    --repo-dir) REPO_DIR="$2"; shift 2;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done

[ -n "$ID" ]    || { echo "--id is required (lowercase letters, digits, dashes)" >&2; exit 2; }
[ -n "$STATE" ] || { echo "--state is required (working|idle|waiting|offline)" >&2; exit 2; }
echo "$ID" | grep -qE '^[a-z0-9][a-z0-9-]{0,39}$' || { echo "--id must match ^[a-z0-9][a-z0-9-]{0,39}$" >&2; exit 2; }
case "$STATE" in working|idle|waiting|offline) ;; *) echo "bad --state: $STATE" >&2; exit 2;; esac
[ -n "$NAME" ] || NAME="$ID"
[ -n "$INSTANCE" ] || { echo "MASS_INSTANCE (or --instance) is required - create one via the dashboard connect button" >&2; exit 2; }
[ -n "$KEY" ]      || { echo "MASS_KEY (or --key) is required - it came with your instance link" >&2; exit 2; }
echo "$INSTANCE" | grep -qE '^[A-Za-z0-9_-]{8,64}$' || { echo "bad instance id" >&2; exit 2; }
for tool in git python3 openssl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing prerequisite: $tool" >&2; exit 2; }
done

# 1. get a fresh clone of the live status branch
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" fetch origin "$BRANCH" --quiet
  git -C "$REPO_DIR" checkout "$BRANCH" --quiet 2>/dev/null || git -C "$REPO_DIR" checkout -b "$BRANCH" --quiet
  git -C "$REPO_DIR" reset --hard "origin/$BRANCH" --quiet
else
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$REPO_DIR" --quiet
fi

cd "$REPO_DIR"
mkdir -p instances
FILE="instances/$INSTANCE.json"

# 2. decrypt the current instance file (if any), merge this agent's entry,
#    re-encrypt. Crypto: encKey = SHA256(key || ":enc"), macKey = SHA256(key
#    || ":mac"); AES-256-CBC with a random IV; HMAC-SHA256 over iv||ct
#    (encrypt-then-MAC). Envelope: {"v":1,"iv":b64,"ct":b64,"tag":b64}.
UPDATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export MU_FILE="$FILE" MU_KEY="$KEY" MU_ID="$ID" MU_NAME="$NAME" MU_STATE="$STATE" \
       MU_MESSAGE="$MESSAGE" MU_TASK="$TASK" MU_URL="$URL" MU_UPDATED="$UPDATED"

python3 - <<'PY'
import base64, hashlib, hmac, json, os, subprocess, sys

def b64url_decode(s):
    s = s.replace('-', '+').replace('_', '/')
    s += '=' * (-len(s) % 4)
    return base64.b64decode(s)

def b64e(b): return base64.b64encode(b).decode()

raw = b64url_decode(os.environ['MU_KEY'])
enc_key = hashlib.sha256(raw + b':enc').digest()
mac_key = hashlib.sha256(raw + b':mac').digest()

def aes_cbc(op, data, iv):
    p = subprocess.run(
        ['openssl', 'enc', op, '-aes-256-cbc', '-K', enc_key.hex(), '-iv', iv.hex()],
        input=data, capture_output=True)
    if p.returncode != 0:
        sys.exit('mass: openssl failed: ' + p.stderr.decode()[:200])
    return p.stdout

path = os.environ['MU_FILE']
data = {'agents': {}}
if os.path.exists(path):
    env = json.load(open(path))
    iv = base64.b64decode(env['iv']); ct = base64.b64decode(env['ct'])
    tag = hmac.new(mac_key, iv + ct, hashlib.sha256).digest()
    if not hmac.compare_digest(tag, base64.b64decode(env['tag'])):
        sys.exit('mass: instance file failed verification (wrong key?)')
    data = json.loads(aes_cbc('-d', ct, iv))

data.setdefault('agents', {})[os.environ['MU_ID']] = {
    'name': os.environ['MU_NAME'],
    'state': os.environ['MU_STATE'],
    'message': os.environ['MU_MESSAGE'],
    'task': os.environ['MU_TASK'],
    'url': os.environ['MU_URL'],
    'updated': os.environ['MU_UPDATED'],
}

iv = os.urandom(16)
ct = aes_cbc('-e', json.dumps(data).encode(), iv)
tag = hmac.new(mac_key, iv + ct, hashlib.sha256).digest()
with open(path, 'w') as f:
    json.dump({'v': 1, 'iv': b64e(iv), 'ct': b64e(ct), 'tag': b64e(tag)}, f)
    f.write('\n')
PY

# 3. commit and push, with retries if another agent pushed first
git add "$FILE"
if git diff --cached --quiet; then
  echo "mass: no change for $ID"
  exit 0
fi
git -c user.name="${GIT_AUTHOR_NAME:-mass-agent}" \
    -c user.email="${GIT_AUTHOR_EMAIL:-mass-agent@localhost}" \
    commit --quiet -m "status: instance update"
for attempt in 1 2 3; do
  if git push --quiet origin "HEAD:$BRANCH" 2>/dev/null; then
    echo "mass: $ID is $STATE - $MESSAGE"
    exit 0
  fi
  sleep "$attempt"
  git fetch origin "$BRANCH" --quiet
  git rebase "origin/$BRANCH" --quiet || { git rebase --abort; exit 1; }
done
echo "mass: push failed after retries" >&2
exit 1
