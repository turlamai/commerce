# Deploying Commerce

Commerce ships as a Racket package with one role-selectable entrypoint,
`examples/service.rkt`. For a controlled deployment, run two processes on
one SQLite store: `COMMERCE_ROLE=edge` handles webhooks and credential
claims without reading Permit signing keys; `COMMERCE_ROLE=issuer` projects
events and signs entitlements without starting an HTTP listener. The default
`COMMERCE_ROLE=all` preserves the earlier combined walkthrough in
`COMMERCE_ENVIRONMENT=test` only; **production startup rejects combined
mode**, even when it is the default. Explicitly select and provision both
split roles for production. See
[ADR-0020](../docs/decisions/0020-split-service-roles.md) for the remaining
shared-database trust risk. TLS termination, rate limiting, and log shipping
remain the reverse proxy/infrastructure's responsibility
(see `docs/runbook.md`).

## Configuration

Everything arrives through the environment; secrets are file paths read
once at startup (mode 0600, never committed).

| Variable | Meaning | Default |
| --- | --- | --- |
| `COMMERCE_ROLE` | `all` (test only), `edge` (HTTP only), `issuer` (signing/projector only) | `all` (refused in production) |
| `COMMERCE_DB_PATH` | Shared SQLite store path (writable by both roles) | required |
| `COMMERCE_PORT` / `COMMERCE_LISTEN_IP` | HTTP bind | 8080 / 127.0.0.1 |
| `COMMERCE_POLL_SECONDS` | Worker loop poll interval | 2 |
| `COMMERCE_ENVIRONMENT` | `test` or `production`; locks the keyring and merchant reads | `test` |
| `COMMERCE_ISSUER` | Permit issuer identity | required |
| `COMMERCE_WORKER_OWNER` | Outbox lease owner label | `commerce-service` |
| `PERMIT_KEY_ID` | Active trust-store key id | required |
| `PERMIT_PRIVATE_KEY_PATH` | Ed25519 signing key (PEM) | required |
| `PERMIT_TRUST_STORE_PATH` | Permit trust store (JSON) | required |
| `PANCAKE_MERCHANT_ID` | Pancake merchant id | required |
| `PANCAKE_MERCHANT_KEY_PATH` | Pancake merchant RSA key (PEM) | required |
| `PANCAKE_WEBHOOK_TEST_KEY_PATH` | Pancake test webhook public key (PEM) | required |
| `PANCAKE_WEBHOOK_PRODUCTION_KEY_PATH` | Pancake production webhook public key (PEM) | required |

The Offer/policy catalog is compiled into the service.
`examples/service.rkt` contains a **non-production Taskly fixture catalog**:
issuer startup fails in production even when `COMMERCE_ROLE=issuer`.
Replace the demo catalog and the explicit demo-only guard with an audited,
version-pinned product policy before any real payment/entitlement deployment
(per `docs/permit-integration.md`). Merely changing the environment variable
or adding live secrets is not a production launch procedure.

## systemd

For a split deployment, start from [edge.env.example](edge.env.example) and
[issuer.env.example](issuer.env.example); each contains only the configuration
and secret paths needed by that role. Never give the edge OS user read access
to the issuer secret directory, and do not use combined `commerce.env.example`
for production.

For a split deployment, use
[`commerce-edge.service`](commerce-edge.service) and
[`commerce-issuer.service`](commerce-issuer.service), not the original
combined `commerce.service`. Each process must run under a different
unprivileged OS user. The issuer's Permit private key file must be mode
0600 and owned by `commerce-issuer`, so `commerce-edge` cannot read it.
The edge's merchant credential must likewise be readable only by
`commerce-edge`. Both users require group-writable access to the same
SQLite database and WAL directory. Example provisioning (adjust names
and deployment policies before using):

```bash
sudo groupadd --system commerce-shared
sudo useradd --system --gid commerce-shared --shell /usr/sbin/nologin commerce-edge
sudo useradd --system --gid commerce-shared --shell /usr/sbin/nologin commerce-issuer
sudo install -d -o commerce-edge -g commerce-shared -m 2770 /var/lib/commerce
sudo install -d -o root -g root -m 0755 /etc/commerce
sudo cp deploy/commerce-edge.service deploy/commerce-issuer.service /etc/systemd/system/
# Create /etc/commerce/edge.env with COMMERCE_ENVIRONMENT, PANCAKE_MERCHANT_ID,
# PANCAKE_MERCHANT_KEY_PATH and both PANCAKE_WEBHOOK_*_KEY_PATH values.
# Create /etc/commerce/issuer.env with COMMERCE_ENVIRONMENT, COMMERCE_ISSUER,
# PERMIT_KEY_ID, PERMIT_PRIVATE_KEY_PATH and PERMIT_TRUST_STORE_PATH.
# Store each secret outside the repo; lock its owner and mode to 0600.
sudo systemctl daemon-reload
sudo systemctl enable --now commerce-issuer commerce-edge
```

The separate OS users prevent the edge process from reading the issuer key,
**not** from writing to the shared SQLite database. A compromised HTTP edge
with database write access may still forge workflow rows that the issuer
trusts. Until a separately authenticated signing-intent channel or strict
database writer boundary is implemented and tested, this is only partial
key isolation, not full production issuance authorization security.

The original combined unit remains available for a single-process local
walkthrough only:

```bash
sudo useradd -r -s /usr/sbin/nologin commerce
sudo mkdir -p /opt/commerce /var/lib/commerce /etc/commerce
sudo cp -r . /opt/commerce
sudo cp deploy/commerce.service /etc/systemd/system/
# install racket 9.3 at /usr/bin/racket (or adjust ExecStart)
# provision /etc/commerce/* secrets (mode 0600, owner commerce)
sudo systemctl daemon-reload
sudo systemctl enable --now commerce
curl -s http://127.0.0.1:8080/readyz | jq
```

`SIGTERM` from `systemctl stop` terminates the process; the store is
crash-safe by design (WAL, full sync, lease reclaim on restart), so no
signal handler is required for correctness.

## Docker

The Dockerfile pins Permit to `61211f7bf320520c0d3627c4d715e7de7fee52b2`, the same revision as CI.
The default Racket base image is a mutable tag suitable only for development.
For a release, select and independently verify an image digest, then pass
`--build-arg RACKET_IMAGE=racket/racket@sha256:<verified-digest>`.
Record Commerce SHA, Permit SHA, Racket base image digest, produced image digest,
and a tested rollback image in the deployment manifest. A missing base digest
is still an explicit production release gate; it must not be guessed.

```bash
docker build -t commerce-service -f deploy/Dockerfile .
docker run -d --name commerce \
  -p 127.0.0.1:8080:8080 \
  -v commerce-data:/data \
  --env-file deploy/commerce.env \
  commerce-service
curl -s http://127.0.0.1:8080/readyz
```

Provide the secret paths inside `deploy/commerce.env` as paths that
exist inside the container (mount them read-only, e.g.
`-v $PWD/secrets:/run/secrets:ro`).

## Endpoints

- `POST /webhooks/pancake` — provider webhook ingress (exact-byte
  authentication, active order verification, idempotent journaling).
- `POST /claims` — one-time claim fulfillment (token in, signed Permit
  envelope out; 404/409/410 for unknown, reused, expired).
- `GET /readyz` — readiness snapshot; 503 with typed warnings when
  stuck work needs an operator.

## Before production

1. Replace the placeholder catalog with your reviewed policies.
2. Rehearse backup/restore (`docs/runbook.md`) with the live store.
3. Point TLS termination at the service and rate-limit `/claims` and
   `/webhooks/pancake`.
4. Rehearse key rotation (`docs/runbook.md`).
5. Ship the `commerce` log topic as JSON lines.
