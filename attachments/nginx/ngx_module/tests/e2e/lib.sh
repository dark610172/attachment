#!/bin/bash
# Shared helpers for the NGINX attachment end-to-end tests. Source only.
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_STATE="${E2E_STATE:-$HOME/.cache/ngx-e2e}"
E2E_PORT="${E2E_PORT:-18081}"
U="http://127.0.0.1:$E2E_PORT"
AGENT_IMG="${AGENT_IMG:-ghcr.io/openappsec/agent:1.1.36}"
AGENT_MIN_AGE="${AGENT_MIN_AGE:-120}"   # seconds; body attacks can pass right after an agent restart
ATTACK_JSON='{"q":"1'"'"' UNION SELECT username,password FROM users WHERE '"'"'1'"'"'='"'"'1"}'
ATTACK_QUERY='/?id=1%27%20UNION%20SELECT%20username,password%20FROM%20users--'
FAILS=0; PASSES=0
check() { # check NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then PASSES=$((PASSES+1)); echo "PASS  $1"; else FAILS=$((FAILS+1)); echo "FAIL  $1: expected [$2] got [$3]"; fi
}
code() { curl -s -m "${CURL_TIMEOUT:-30}" -o /dev/null -w '%{http_code}' "$@"; }
post_json() { code -H 'Content-Type: application/json' --data-binary "$@"; }
repeat() { # repeat N CMD... -> distinct results, e.g. "403" or "200,403"
  local n=$1 out; shift; out=$(for i in $(seq "$n"); do "$@"; echo; done | sort -u | paste -sd, -); echo "$out"
}
mkjson() { # mkjson SIZE POS(none|start|end) FILE
  python3 - "$1" "$2" "$3" <<'PY'
import sys,json,random
n=int(sys.argv[1]); pos=sys.argv[2]; random.seed(n)
A="1' UNION SELECT username,password FROM users WHERE '1'='1"
items=[]; s=0; i=0
while s<n-200:
    it={"id":i,"name":"item%d"%i,"qty":random.randint(1,9)}; items.append(it); s+=len(json.dumps(it))+2; i+=1
d={}
if pos=="start": d["q"]=A
d["items"]=items
if pos=="end": d["z"]=A
open(sys.argv[3],"w").write(json.dumps(d))
PY
}
nginx_log_count() { docker logs e2e-nginx 2>&1 | grep -c -- "$1"; }
summary() { echo "----"; echo "passed=$PASSES failed=$FAILS"; [ "$FAILS" -eq 0 ]; }
