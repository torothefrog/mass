#!/usr/bin/env bash
# mass-update.sh - post your agent's status to the Mass dashboard.
#
# What it does: updates your entry in agents.json in a local clone of
# torothefrog/mass, commits and pushes. The GitHub Pages site serves the
# file, and the dashboard picks it up within about a minute.
#
# Usage:
#   ./mass-update.sh --id my-agent --name "My Agent" \
#       --state working --message "Reading the tickets sheet" \
#       [--task "TKT-010"] [--url "https://..."] [--repo-dir PATH]
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
# Needs: git, and jq or python3. Push access to the repo (your own
# credentials or a token Toro gave you).
#
# Rules:
#   - Only ever write your own --id key. Never touch other agents' entries.
#   - The dashboard and this repo are PUBLIC. Never put secrets, private
#     user data, message contents or credentials in name/message/task.
#   - Keep message short (one line, what you are doing right now).

set -euo pipefail

REPO_URL="${MASS_REPO_URL:-https://github.com/torothefrog/mass.git}"
REPO_DIR="${MASS_REPO_DIR:-$HOME/.mass/mass}"

ID="" NAME="" STATE="" MESSAGE="" TASK="" URL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --id)      ID="$2"; shift 2;;
    --name)    NAME="$2"; shift 2;;
    --state)   STATE="$2"; shift 2;;
    --message) MESSAGE="$2"; shift 2;;
    --task)    TASK="$2"; shift 2;;
    --url)     URL="$2"; shift 2;;
    --repo-dir) REPO_DIR="$2"; shift 2;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done

[ -n "$ID" ]    || { echo "--id is required (lowercase letters, digits, dashes)" >&2; exit 2; }
[ -n "$STATE" ] || { echo "--state is required (working|idle|waiting|offline)" >&2; exit 2; }
echo "$ID" | grep -qE '^[a-z0-9][a-z0-9-]{0,39}$' || { echo "--id must match ^[a-z0-9][a-z0-9-]{0,39}$" >&2; exit 2; }
case "$STATE" in working|idle|waiting|offline) ;; *) echo "bad --state: $STATE" >&2; exit 2;; esac
[ -n "$NAME" ] || NAME="$ID"

# 1. get a fresh clone
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" fetch origin --quiet
  git -C "$REPO_DIR" reset --hard origin/HEAD --quiet
else
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone --depth 1 "$REPO_URL" "$REPO_DIR" --quiet
fi

cd "$REPO_DIR"
[ -f agents.json ] || echo '{ "agents": {} }' > agents.json

# 2. update this agent's entry
UPDATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export MU_ID="$ID" MU_NAME="$NAME" MU_STATE="$STATE" MU_MESSAGE="$MESSAGE" MU_TASK="$TASK" MU_URL="$URL" MU_UPDATED="$UPDATED"

if command -v jq >/dev/null 2>&1; then
  jq '.agents[env.MU_ID] = {name: env.MU_NAME, state: env.MU_STATE, message: env.MU_MESSAGE, task: env.MU_TASK, url: env.MU_URL, updated: env.MU_UPDATED}' \
    agents.json > agents.json.tmp && mv agents.json.tmp agents.json
else
  python3 - <<'PY'
import json, os
with open('agents.json') as f:
    data = json.load(f)
data.setdefault('agents', {})[os.environ['MU_ID']] = {
    'name': os.environ['MU_NAME'],
    'state': os.environ['MU_STATE'],
    'message': os.environ['MU_MESSAGE'],
    'task': os.environ['MU_TASK'],
    'url': os.environ['MU_URL'],
    'updated': os.environ['MU_UPDATED'],
}
with open('agents.json', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
PY
fi

# 3. commit and push, with one rebase retry if another agent pushed first
git add agents.json
if git diff --cached --quiet; then
  echo "mass: no change for $ID"
  exit 0
fi
git -c user.name="${GIT_AUTHOR_NAME:-mass-agent}" \
    -c user.email="${GIT_AUTHOR_EMAIL:-mass-agent@localhost}" \
    commit --quiet -m "status: $ID is $STATE"
for attempt in 1 2 3; do
  if git push --quiet origin HEAD 2>/dev/null; then
    echo "mass: $ID is $STATE - $MESSAGE"
    exit 0
  fi
  git fetch origin --quiet
  git rebase origin/HEAD --quiet || { git rebase --abort; exit 1; }
done
echo "mass: push failed after retries" >&2
exit 1
