# Formal model of the body-piece loop

`BodySplit.lean` models the loop that splits a request or response body buffer into pieces of at most 32 KiB before it sends them to the agent. Lean checks these properties for every buffer size and every start offset:

| Theorem | Property |
|---|---|
| `pieces_cover` | The pieces cover every byte from the start offset to the end exactly once, in order. |
| `pieces_le` | No piece is larger than the piece size. |
| `pieces_flags` | Only the final piece can carry the end-of-body flag, and it carries it only for the last buffer. |
| `pieces_ne_nil` | The loop sends at least one piece, so an empty last buffer still sends the end-of-body flag. |
| `piece_size_fits` | 32 KiB plus the header fits in the IPC message limit. |
| termination | Lean accepts the definition only because the loop always ends. |

The model covers the loop only. It does not cover the IPC transport, the agent, or the NGINX buffer chain.

## Check

Checked with Lean 4.36.0. Any image with Lean 4 works. To build one:

```dockerfile
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates git && rm -rf /var/lib/apt/lists/*
RUN curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain stable
ENV PATH=/root/.elan/bin:$PATH
```

```bash
docker build -t lean4-local .
docker run --rm -v "$PWD:/w" -w /w lean4-local lean BodySplit.lean
```

No output and exit code 0 means every proof checks. The file contains no `sorry`. `#print axioms` shows only the standard axioms (`propext`, `Quot.sound`, `Classical.choice`).
