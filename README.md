# camouflare-stack

Deployment for [camouflare](https://github.com/mehmetcansahin/camouflare) 2.1.0 —
a FlareSolverr-compatible `/v1` service backed by Camoufox — plus the glue that
the reference setup does not cover.

Deployed by Coolify as a docker-compose resource. Push to `main` → Coolify
webhook → redeploy.

## Topology

```
                        ┌── Traefik (coolify net) ──► camouflare-auth:8191 ─┐
   https://camouflare…  ┘                                     (pass-through) │
                                                                             ├─► camouflare:8191
   Prowlarr ──► camouflare-shim:8192  (token injected, null proxy stripped) ─┘
                                  private `arr` network only
```

| Service | Why it exists |
|---|---|
| `camouflare` | The upstream image. Bearer token required; never on the public bridge. |
| `camouflare-auth` | nginx ingress. Forwards public traffic unchanged, so the app's own token stays the gate. |
| `camouflare-shim` | Prowlarr/Jackett cannot send an auth header and always send `proxy: {url: null}`, which camouflare rejects with 500. The shim fixes both. |
| `prowlarr` | Test client, Traefik basic auth in front. |

## Two things this stack exists to get right

1. **Do not put `camouflare` on the `coolify` bridge.** It fetches
   caller-supplied URLs and that bridge holds ~50 other containers; with a valid
   token it could read `http://coolify:8080`. Only the ingress hop joins both
   networks. `scripts/verify.sh` enforces this invariant.
2. **Prowlarr's payload is rejected by camouflare.** Prowlarr builds a `proxy`
   object with a null `url` when no proxy is configured; FlareSolverr ignores it,
   camouflare returns `500 INVALID_REQUEST`. The shim drops a proxy object that
   names no endpoint.

## Required environment variables

Set these in Coolify (never commit them):

| Variable | Purpose |
|---|---|
| `CAMOUFLARE_API_TOKEN` | Bearer token for `/v1`. Generate with `openssl rand -hex 32`. |
| `PROWLARR_BASIC_AUTH` | Traefik basic-auth users line, e.g. `admin:$apr1$…` (from `openssl passwd -apr1`). |

## Gate

```sh
./scripts/verify.sh    # python3 stdlib only; no network, no containers
```

Checks the shim's sanitize rules, the container hardening flags, absence of
secrets and published ports, and the network-isolation invariant.

## Operational notes

- `/data/prowlarr/config` holds Prowlarr's SQLite DB and API key; back it up.
- Camouflare keeps all state in-process: two browser slots, one session max by
  default (`POOL_RESERVED_TRANSIENT_CONTEXTS=1`). Expect `503 POOL_UNAVAILABLE`
  under burst load.
- `PROMETHEUS_ENABLED=true` exposes `/metrics` behind the token.
- Rollback: change the image tag, push, redeploy. No volumes to restore.
