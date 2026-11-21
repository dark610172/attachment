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
agent_now() {
  # Existing agent lines start [2026-11-21T06:36:40.956338: ...;
  # compare that ISO seconds prefix with the agent UTC clock. The prefix
  # has no zone marker; live logger-zone verification requires the running agent.
  timeout "${AGENT_PROBE_TIMEOUT:-60}" docker exec e2e-agent date -u +%Y-%m-%dT%H:%M:%S
}
agent_failopen() { # agent_failopen state | since AGENT_UTC_TIMESTAMP
  timeout "${AGENT_PROBE_TIMEOUT:-60}" docker exec e2e-agent sh -c '
    mode=$1; since=${2:-}
    case "$mode" in
      state) ;;
      since)
        case "$since" in
          ????-??-??T??:??:??) ;;
          *) echo "invalid suite timestamp" >&2; exit 1 ;;
        esac
        cutoff=$(TZ=UTC0 date -d "${since%T*} ${since#*T}" +%s) || exit 1
        ;;
      *) exit 1 ;;
    esac
    cd /var/log/nano_agent || exit 1
    ids=" "
    for f in cp-nano-http-transaction-handler.dbg*; do
      [ -f "$f" ] || continue
      id=${f##*.dbg}; id=${id%%.*}
      case "$id" in ""|*[!0-9]*) continue ;; esac
      case "$ids" in *" $id "*) ;; *) ids="$ids$id " ;; esac
    done
    [ "$ids" != " " ] || { echo "no handler logs" >&2; exit 1; }
    scan() {
      case "$1" in
        *.gz) data=$(zcat "$1") || return 1 ;;
        *) data=$(cat "$1") || return 1 ;;
      esac
      # Read the whole input: a late decompression/read error must fail the probe.
      awk -v mode="$mode" -v since="$since" "
        index(\$0, \"Failopen mode is \") {
          if (mode == \"state\") latest = \$0
          else if (index(\$0, \"Failopen mode is ON,\") && substr(\$0, 2, 19) >= since) found = 1
        }
        END { if (mode == \"state\") print latest; else if (found) print \"ON\" }
      " <<EOF
$data
EOF
    }
    for id in $ids; do
      current=cp-nano-http-transaction-handler.dbg$id
      # The current log is required; missing logs are unknown, never healthy.
      result=$(scan "$current") || exit 1
      if [ "$mode" = state ] && [ -n "$result" ]; then
        case "$result" in
          *"Failopen mode is ON,"*) printf "%s\n" "$id" ;;
          *"Failopen mode is OFF,"*) ;;
          *) exit 1 ;;
        esac
        continue
      fi
      hit=$result
      set -- "$current".*.gz
      if [ -f "$1" ]; then
        rotations=$(ls -t -- "$@") || exit 1
        for f in $rotations; do
          if [ "$mode" = since ]; then
            modified=$(stat -c %Y "$f") || exit 1
            [ "$modified" -ge "$cutoff" ] || continue
          fi
          result=$(scan "$f") || exit 1
          if [ -n "$result" ]; then
            hit=$result
            [ "$mode" = state ] && break
          fi
        done
      fi
      if [ "$mode" = state ]; then
        case "$hit" in
          *"Failopen mode is ON,"*) printf "%s\n" "$id" ;;
          # No transition in any kept log: the handler never entered fail-open.
          *"Failopen mode is OFF,"*|"") ;;
          *) echo "bad fail-open state for handler $id" >&2; exit 1 ;;
        esac
      elif [ -n "$hit" ]; then
        printf "%s\n" "$id"
      fi
    done
  ' sh "$@"
}
summary() { echo "----"; echo "passed=$PASSES failed=$FAILS"; [ "$FAILS" -eq 0 ]; }
