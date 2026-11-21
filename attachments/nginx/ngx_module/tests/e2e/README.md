# NGINX attachment end-to-end tests

These tests run the NGINX attachment against a live open-appsec agent in Docker. Each check compares a result with an expected value. The script exits with 0 only when every check passes.

## Requirements

- Docker, curl (with HTTP/2), python3, nc, bash.
- An NGINX image that contains the attachment module under test, for example `ghcr.io/openappsec/nginx-attachment:<version>` or a local build.
- The agent image `ghcr.io/openappsec/agent:1.1.36` (override with `AGENT_IMG`).

## Run

```bash
./run.sh <nginx-image>                  # all suites
./run.sh <nginx-image> functional h2    # selected suites
ASYNC=1 ./run.sh <async-nginx-image>    # async mode (module built with NGINX_ASYNC_SUPPORTED)
```

| Suite | What it checks |
|---|---|
| functional | JSON bodies of 4 KB to 600 KB with an SQL injection at the start or the end, and clean bodies, at `client_body_buffer_size` 1m and 8k. Also gzip, cache hit and Content-Type responses. |
| uploads | 1, 50 and 300 MB uploads with Content-Length and chunked encoding. The backend must receive the same size and SHA-256. |
| kong | Issues first found in the Kong attachment: chunked bodies, many headers, and malformed requests. |
| h2 | HTTP/2 (h2c) body attacks and clean bodies. NGINX must not log "http request count is zero". |

Every suite also fails if an NGINX worker exits on a signal.

## Reference results

Agent 1.1.36, NGINX 1.30.4, policy `conf/local_policy.yaml`:

| Image | Result |
|---|---|
| `ghcr.io/openappsec/nginx-attachment:1.1.36` | 52 passed, 6 failed: clean 70 KB and 600 KB bodies blocked at 1m, Content-Length uploads blocked at 1m, 39 "request count is zero" alerts over HTTP/2 |
| Branch `fix/nginx-module` | 58 passed, 0 failed |

With a larger policy that also loads Snort rules, the 1.1.36 image also passed a 600 KB body with an SQL injection at the end (1m buffer). The minimal policy here does not reproduce that bypass.

## Notes

- The stack uses port 18081 (`E2E_PORT`) and state in `~/.cache/ngx-e2e` (`E2E_STATE`). Containers are named `e2e-*`.
- The agent passes body attacks for a short time after it starts. `up.sh` waits until the agent has run for 120 seconds (`AGENT_MIN_AGE`) and until 16 body attacks in a row are blocked.
- `up.sh` waits up to 300 seconds (`AGENT_FAILOPEN_WAIT`) for all handlers to leave CPU fail-open after readiness. Each suite rejects any ON transition since its agent-clock start time and checks the final state. Probe errors fail the check. `AGENT_PROBE_TIMEOUT` bounds standalone probes (default: 60 seconds); readiness probes use the remaining wait time.
- `ASYNC=1` writes the agent setting `agent.asyncMode.nginxModule` and restarts the agent when the mode changes.
- Run the load generator for performance tests on a different host from the system under test.
