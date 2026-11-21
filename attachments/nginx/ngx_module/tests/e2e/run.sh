#!/bin/bash
# run.sh IMAGE [SUITE...] — end-to-end checks against a live agent. Exit code 0 only if every check passes.
# Suites: functional uploads kong h2 (default: all). ASYNC=1 runs them in async mode (async builds only).
. "$(dirname "$0")/lib.sh"
IMG=${1:?usage: run.sh IMAGE [functional|uploads|kong|h2]...}; shift
SUITES=${*:-functional uploads kong h2}
W="$E2E_STATE/work"; mkdir -p "$W"
up() { "$E2E_DIR/up.sh" "$IMG" "$@" || { FAILS=$((FAILS+1)); echo "FAIL  up $*"; return 1; }; }
no_crash() {
  check "$1: no worker crash" 0 "$(nginx_log_count 'exited on signal')"
  local start handlers
  if start=$(cat "$E2E_STATE/suite_start") && handlers=$(agent_failopen since "$start"); then
    # A suite with no attack checks (uploads) may cause fail-open; its results stay valid.
    if [ "$2" = allow-failopen ]; then
      [ -n "$handlers" ] && echo "INFO  $1: agent fail-open during suite (handlers $handlers); no attack checks in this suite"
    else
      check "$1: agent fail-open during suite" "" "$handlers"
    fi
  else
    check "$1: agent fail-open during suite" "" "probe-error"
  fi
  # The next up.sh waits for fail-open to end, so an allowed suite skips the end check.
  [ "$2" = allow-failopen ] && return
  if handlers=$(agent_failopen state); then
    check "$1: agent fail-open at suite end" "" "$handlers"
  else
    check "$1: agent fail-open at suite end" "" "probe-error"
  fi
}

functional() {
  for bb in 1m 8k; do
    HTTP2=0 up "$bb" || continue
    check "[$bb] GET clean" 200 "$(code "$U/big.txt")"
    check "[$bb] GET attack" 403 "$(code "$U$ATTACK_QUERY")"
    for n in 4000 70000 140000 600000; do
      for p in none start end; do
        f="$W/b.$n.$p"; [ -f "$f" ] || mkjson "$n" "$p" "$f"
        want=403; [ "$p" = none ] && want=200
        check "[$bb] POST ${n}B JSON attack=$p" "$want" "$(post_json @"$f" "$U/upload")"
      done
    done
    check "[$bb] gzip response bytes" 300001 "$(curl -s --compressed "$U/big.txt" | wc -c)"
    code "$U/cached/big.txt" >/dev/null
    check "[$bb] cache hit" HIT "$(curl -s -D - -o /dev/null "$U/cached/big.txt" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache"{print $2}')"
    check "[$bb] Content-Type kept" text/x-marker-ct "$(curl -s -D - -o /dev/null "$U/ct" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print $2}')"
    no_crash "[$bb] functional"
  done
}

uploads() {
  HTTP2=0 up 1m || return
  for mb in 1 50 300; do
    f="$W/up.$mb"
    [ -f "$f" ] || python3 - "$mb" "$f" <<'PY'
import sys,random,json
mb=int(sys.argv[1]); random.seed(mb); n=0; i=0
with open(sys.argv[2],"w") as o:
    o.write('{"items":[')
    while n<mb*1048576:
        s=json.dumps({"id":i,"name":"item%d"%i,"qty":random.randint(1,9)}); o.write(("," if i else "")+s); n+=len(s)+1; i+=1
    o.write("]}")
PY
    want="$(stat -c %s "$f") $(sha256sum "$f" | cut -d' ' -f1)"
    check "upload ${mb}MB Content-Length intact" "$want" "$(curl -s -m 300 -H 'Content-Type: application/json' --data-binary @"$f" "$U/sink")"
    check "upload ${mb}MB chunked intact" "$want" "$(curl -s -m 300 -H 'Content-Type: application/json' -H 'Transfer-Encoding: chunked' --data-binary @"$f" "$U/sink")"
  done
  no_crash uploads allow-failopen
}

kong() { # issues found in the Kong attachment, replayed on NGINX
  HTTP2=0 up 8k || return
  check "chunked attack blocked" 403 "$(printf '%s' "$ATTACK_JSON" | post_json @- -H 'Transfer-Encoding: chunked' "$U/upload")"
  check "chunked clean passes" 200 "$(printf '%s' '{"a":1}' | post_json @- -H 'Transfer-Encoding: chunked' "$U/upload")"
  python3 -c "[print('X-H%d: v'%i) for i in range(990)]" > "$W/h990"
  check "990 headers clean" 200 "$(code -H @"$W/h990" "$U/ct")"
  check "990 headers + body attack" 403 "$(post_json "$ATTACK_JSON" -H @"$W/h990" "$U/upload")"
  check "garbage request" 400 "$(printf 'GARBAGE\r\n\r\n' | timeout 5 nc 127.0.0.1 "$E2E_PORT" | head -1 | awk '{print $2}')"
  check "20 KB URI" 414 "$(code "$U/$(head -c 20000 /dev/zero | tr '\0' a)")"
  check "bad HTTP version" 505 "$(printf 'GET / HTTP/9.9\r\nHost: x\r\n\r\n' | timeout 5 nc 127.0.0.1 "$E2E_PORT" | head -1 | awk '{print $2}')"
  check "attacks still blocked after bad requests" 403 "$(repeat 8 post_json "$ATTACK_JSON" "$U/upload")"
  no_crash kong
}

h2() {
  HTTP2=1 up 8k || return
  local H=--http2-prior-knowledge
  [ -f "$W/b.300000.end" ] || mkjson 300000 end "$W/b.300000.end"
  [ -f "$W/b.300000.none" ] || mkjson 300000 none "$W/b.300000.none"
  check "h2 protocol" 2 "$(curl -s $H -o /dev/null -w '%{http_version}' "$U/ct")"
  check "h2 small body attack x30" 403 "$(repeat 30 post_json "$ATTACK_JSON" $H "$U/upload")"
  check "h2 300KB attack-at-end x10" 403 "$(repeat 10 post_json @"$W/b.300000.end" $H "$U/upload")"
  check "h2 300KB clean x10" 200 "$(repeat 10 post_json @"$W/b.300000.none" $H "$U/upload")"
  check "h2 no double finalize (request count is zero)" 0 "$(nginx_log_count 'count is zero')"
  no_crash h2
}

for s in $SUITES; do echo "== $s (image=$IMG async=${ASYNC:-0})"; "$s"; done
summary
