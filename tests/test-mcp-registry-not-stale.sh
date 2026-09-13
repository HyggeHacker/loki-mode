#!/usr/bin/env bash
# The PUBLISHED MCP registry entry must not fall behind what we ship.
#
# WHY THIS EXISTS. tests/test-server-json-current.sh already guards that
# server.json tracks VERSION, and it passes. Both of those values are LOCAL, so
# they agree with each other while saying nothing about what the registry
# actually serves to users.
#
# Measured 2026-09-13, with both files green:
#
#   server.json                      9.49.4
#   VERSION                          9.49.4
#   registry.modelcontextprotocol.io 7.34.1   <- 40+ releases behind
#
# A user discovering the server through the registry gets an npm pin of 7.34.1.
# Nothing in the repository could detect that, because nothing compared a local
# value to a remote one.
#
# NETWORK-DEPENDENT BY NATURE, so this does NOT belong in the fast tier: a
# pre-push gate that reaches the internet fails on a plane, in CI without egress,
# and whenever the registry has an outage, and none of those are defects in this
# repository. It is written for a scheduled workflow and for manual use.
#
# EXIT CODES, so a caller can distinguish the three outcomes:
#   0  in sync, or the registry is unreachable (UNKNOWN is not a failure)
#   1  drift confirmed: the registry serves an older version than VERSION
#   2  a local precondition is broken (missing VERSION, unparseable server.json)
#
# Unreachable exits 0 deliberately. A guard that reddens on someone else's
# outage trains readers to ignore it, and this one is advisory: it reports a
# publishing gap that only a human with registry credentials can close.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$REPO_ROOT" || exit 2

REGISTRY_URL="${LOKI_MCP_REGISTRY_URL:-https://registry.modelcontextprotocol.io/v0/servers?search=loki-mode}"
SERVER_NAME="${LOKI_MCP_SERVER_NAME:-io.github.asklokesh/loki-mode}"
TIMEOUT="${LOKI_MCP_REGISTRY_TIMEOUT:-20}"

PASS=0
FAIL=0
ok()   { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
note() { printf 'NOTE: %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Local preconditions. These are assertions about this repository, so a failure
# here is a real defect and exits 2 rather than being reported as drift.
# ---------------------------------------------------------------------------
[ -f VERSION ] || { bad "VERSION is missing"; exit 2; }
[ -f server.json ] || { bad "server.json is missing"; exit 2; }

LOCAL_VERSION="$(tr -d ' \n' < VERSION)"
case "$LOCAL_VERSION" in
    ''|*[!0-9.]*) bad "VERSION is not a plain version string: '$LOCAL_VERSION'"; exit 2 ;;
esac

SERVER_JSON_VERSION="$(python3 -c '
import json, sys
try:
    print(json.load(open("server.json")).get("version", ""))
except Exception as exc:
    print("", file=sys.stderr)
    raise SystemExit(2)
' 2>/dev/null)"
[ -n "$SERVER_JSON_VERSION" ] || { bad "server.json has no parseable version"; exit 2; }

if [ "$SERVER_JSON_VERSION" = "$LOCAL_VERSION" ]; then
    ok "server.json ($SERVER_JSON_VERSION) matches VERSION"
else
    # test-server-json-current.sh owns this assertion; duplicate it only as a
    # precondition so a confusing drift report cannot be produced from an
    # already-inconsistent tree.
    bad "server.json is $SERVER_JSON_VERSION but VERSION is $LOCAL_VERSION; fix that first"
    exit 2
fi

# ---------------------------------------------------------------------------
# The remote comparison. Everything below treats an unreachable registry as
# UNKNOWN, never as a pass and never as a failure.
# ---------------------------------------------------------------------------
# Retry once before concluding UNKNOWN. A single transient failure is
# indistinguishable from a registry that is genuinely down, and both take the
# silent exit-0 path below, so a blip would quietly turn this guard into a
# no-op. Observed live: one run reported unreachable while the identical URL
# fetched 935 bytes from the same host seconds later.
RESPONSE=""
for _attempt in 1 2; do
    RESPONSE="$(curl -sS --max-time "$TIMEOUT" "$REGISTRY_URL" 2>/dev/null)" || RESPONSE=""
    [ -n "$RESPONSE" ] && break
    [ "$_attempt" = "1" ] && sleep 2
done

if [ -z "$RESPONSE" ]; then
    note "registry unreachable or empty response; cannot compare (not a failure)"
    printf '\nTotal: %d  Passed: %d  Failed: %d  (registry UNKNOWN)\n' \
        "$((PASS + FAIL))" "$PASS" "$FAIL"
    exit 0
fi

PUBLISHED="$(LOKI_MCP_RESPONSE="$RESPONSE" LOKI_MCP_NAME="$SERVER_NAME" python3 -c '
import json, os, sys

# The response shape is {"servers": [{"server": {...}, "_meta": {...}}]}. An
# earlier probe of mine guessed servers[].version directly and printed None,
# which measured nothing; read the nested object explicitly.
try:
    doc = json.loads(os.environ["LOKI_MCP_RESPONSE"])
except Exception:
    raise SystemExit(0)

want = os.environ["LOKI_MCP_NAME"]
for entry in doc.get("servers") or []:
    server = entry.get("server") if isinstance(entry, dict) else None
    if not isinstance(server, dict):
        continue
    if server.get("name") == want:
        print(server.get("version") or "")
        break
' 2>/dev/null)"

if [ -z "$PUBLISHED" ]; then
    note "no registry entry found for $SERVER_NAME; cannot compare (not a failure)"
    printf '\nTotal: %d  Passed: %d  Failed: %d  (registry UNKNOWN)\n' \
        "$((PASS + FAIL))" "$PASS" "$FAIL"
    exit 0
fi

note "registry serves $SERVER_NAME at $PUBLISHED; we ship $LOCAL_VERSION"

if [ "$PUBLISHED" = "$LOCAL_VERSION" ]; then
    ok "the registry entry is current ($PUBLISHED)"
    printf '\nTotal: %d  Passed: %d  Failed: %d\n' "$((PASS + FAIL))" "$PASS" "$FAIL"
    exit 0
fi

# Drift. Report the direction, because a registry AHEAD of local is a different
# and more alarming problem than one behind it.
NEWER="$(LOKI_A="$PUBLISHED" LOKI_B="$LOCAL_VERSION" python3 -c '
import os

def parts(v):
    out = []
    for chunk in v.split("."):
        digits = "".join(c for c in chunk if c.isdigit())
        out.append(int(digits) if digits else 0)
    return out

a, b = parts(os.environ["LOKI_A"]), parts(os.environ["LOKI_B"])
width = max(len(a), len(b))
a += [0] * (width - len(a))
b += [0] * (width - len(b))
print("registry" if a > b else "local")
' 2>/dev/null)"

if [ "$NEWER" = "registry" ]; then
    bad "the registry serves $PUBLISHED, NEWER than VERSION $LOCAL_VERSION -- someone published from a different tree"
else
    bad "the registry serves $PUBLISHED but we ship $LOCAL_VERSION -- users discovering the server get a stale pin"
fi

printf '\nTotal: %d  Passed: %d  Failed: %d\n' "$((PASS + FAIL))" "$PASS" "$FAIL"
exit 1
