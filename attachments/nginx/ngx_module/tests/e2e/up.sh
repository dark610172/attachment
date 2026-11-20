#!/bin/bash
# up.sh IMAGE [BODYBUF] — start agent, backends and nginx (image under test) on port $E2E_PORT.
# Environment: HTTP2=1 enables "http2 on" (h2c); ASYNC=1 sets agent async mode and CP_ASYNC_MODE (async builds only).
set -e
. "$(dirname "$0")/lib.sh"
IMG=${1:?image}; BB=${2:-8k}; HTTP2=${HTTP2:-0}; ASYNC=${ASYNC:-0}
mkdir -p "$E2E_STATE"/{conf,data,logs,ext,html}
cp "$E2E_DIR/conf/local_policy.yaml" "$E2E_STATE/ext/local_policy.yaml"
[ -f "$E2E_STATE/html/big.txt" ] || python3 -c "print('A'*300000)" > "$E2E_STATE/html/big.txt"
docker network inspect e2enet >/dev/null 2>&1 || docker network create e2enet >/dev/null
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
if ! running e2e-agent; then
  docker rm -f e2e-agent >/dev/null 2>&1 || true
  docker run -d --name e2e-agent --network e2enet --ipc shareable -e registered_server=NGINX -e autoPolicyLoad=true \
    -v "$E2E_STATE/conf:/etc/cp/conf" -v "$E2E_STATE/data:/etc/cp/data" -v "$E2E_STATE/logs:/var/log/nano_agent" \
    -v "$E2E_STATE/ext:/ext/appsec" "$AGENT_IMG" /cp-nano-agent >/dev/null
fi
# Agent async setting must match ASYNC; restart the agent when it changes.
want='{"agentSettings": []}'
[ "$ASYNC" = 1 ] && want='{"agentSettings": [{"id": "asyncmode", "key": "agent.asyncMode.nginxModule", "value": "true"}]}'
for i in $(seq 60); do docker exec e2e-agent test -f /etc/cp/conf/settings.json && break; sleep 2; done
have=$(docker exec e2e-agent cat /etc/cp/conf/settings.json 2>/dev/null | tr -d ' \n')
if [ "$have" != "$(echo "$want" | tr -d ' \n')" ]; then
  docker exec e2e-agent sh -c "printf '%s\n' '$want' > /etc/cp/conf/settings.json"
  docker restart e2e-agent >/dev/null
fi
running e2e-backend || { docker rm -f e2e-backend >/dev/null 2>&1 || true; docker run -d --name e2e-backend --network e2enet --network-alias backend \
  -v "$E2E_STATE/html:/usr/share/nginx/html:ro" -v "$E2E_DIR/conf/backend.conf:/etc/nginx/conf.d/default.conf:ro" nginx:alpine >/dev/null; }
running e2e-echo || { docker rm -f e2e-echo >/dev/null 2>&1 || true; docker run -d --name e2e-echo --network e2enet --network-alias echo \
  -v "$E2E_DIR/conf/echo.py:/echo.py:ro" python:3-alpine python /echo.py >/dev/null; }
# Wait until the agent has run long enough.
started=$(date -d "$(docker inspect -f '{{.State.StartedAt}}' e2e-agent)" +%s)
age=$(( $(date +%s) - started ))
[ "$age" -lt "$AGENT_MIN_AGE" ] && { echo "waiting $((AGENT_MIN_AGE-age))s for agent warm-up"; sleep $((AGENT_MIN_AGE-age)); }
h2=""; [ "$HTTP2" = 1 ] && h2="http2 on;"
sed -e "s/\${BODYBUF}/$BB/" -e "s/\${HTTP2_DIRECTIVE}/$h2/" "$E2E_DIR/conf/nginx.conf.tmpl" > "$E2E_STATE/nginx.conf"
docker rm -f e2e-nginx >/dev/null 2>&1 || true
envs=""; [ "$ASYNC" = 1 ] && envs="-e CP_ASYNC_MODE=true"
docker run -d --name e2e-nginx $envs --network e2enet --ipc container:e2e-agent -p "$E2E_PORT:80" \
  -v "$E2E_STATE/nginx.conf:/etc/nginx/conf.d/default.conf:ro" "$IMG" >/dev/null
# Ready: every worker must block a body attack. 16 consecutive blocks on new connections, max 4 minutes.
ok=0
for i in $(seq 240); do
  if [ "$(post_json "$ATTACK_JSON" "$U/upload")" = 403 ]; then ok=$((ok+1)); else ok=0; sleep 1; fi
  [ "$ok" -ge 16 ] && break
done
[ "$ok" -ge 16 ] || { echo "nginx did not become ready (body attacks not blocked)"; exit 1; }
for i in $(seq 30); do code "$U/big.txt" >/dev/null; done
echo "up: image=$IMG bodybuf=$BB http2=$HTTP2 async=$ASYNC"
