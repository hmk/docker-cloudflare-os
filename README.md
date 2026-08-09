# docker-cloudflare-os

Self-hosted [Cloudflare OS](https://github.com/cloudflare/cloudflare-os) in a container: the full
stack (router, workshop backend, and all gatekeepers) running on `workerd` via `wrangler dev`,
pre-built at image build time so containers start straight into serving.

Images rebuild automatically within an hour of upstream commits, are smoke-tested before
publishing, and ship for `linux/amd64` + `linux/arm64`:

- Docker Hub: `heimark/cloudflare-os`
- GHCR: `ghcr.io/hmk/cloudflare-os`

> **Status:** upstream calls the wrangler/local path "not meant for production use". This image
> is for self-hosters and beta testers, not for running a company on. Unofficial,
> community-maintained; not affiliated with or endorsed by Cloudflare.

This image follows [linuxserver.io](https://docs.linuxserver.io/) conventions: a single
`/config` volume, `PUID`/`PGID`, `TZ`, and `FILE__`-prefixed secrets.

## Quick start

```sh
docker run -d --name cloudflare-os \
  -p 8787:8787 \
  -v ./data:/config \
  -e PUID=1000 -e PGID=1000 \
  -e ANTHROPIC_API_KEY=sk-ant-... \
  heimark/cloudflare-os:latest
```

Open http://localhost:8787, create an account (the first account named `admin` gets admin
features), and start building. With `ANTHROPIC_API_KEY` set, Claude models are available to
every user immediately — no key entry in the UI.

Or with compose ([`docker-compose.yml`](docker-compose.yml)):

```sh
docker compose up -d
```

## Environment

| Variable | Default | Description |
| --- | --- | --- |
| `PUID` / `PGID` | `911` | uid/gid the app runs as; `/config` is chowned to match. |
| `TZ` | | Standard tz database name. |
| `ANTHROPIC_API_KEY` | | Deployment-wide Anthropic key: every user gets the suggested Claude models with no key entry in the UI. |
| `OPENAI_API_KEY` | | Same, OpenAI (GPT models). |
| `GOOGLE_API_KEY` | | Same, Google (Gemini models). |
| `FILE__<VAR>` | | Read `<VAR>` from a file, e.g. `FILE__ANTHROPIC_API_KEY=/run/secrets/anthropic_key`. |
| `PUBLIC_BASE_URL` | | Public URL of the deployment (e.g. `https://os.example.com`). Required for OAuth gatekeeper redirects behind a reverse proxy / custom domain. |
| `AUTH_GATEKEEPERS` | | Comma list of sign-in providers (`google,github,cloudflare`); see upstream [docs/public-server.md](https://github.com/cloudflare/cloudflare-os/blob/main/docs/public-server.md). |
| `DISABLE_PASSWORD_AUTH` | | `"true"` to hide username/password sign-in (needs `AUTH_GATEKEEPERS`). |
| `CF_AI_GATEWAY*` | | Cloudflare AI Gateway mode (server-managed keys + billing); see upstream docs. Takes priority over the `*_API_KEY` vars for providers it covers. |

Deployment-wide keys mean *your key pays for every user's inference* — only set them on
deployments where you trust all accounts. Users can still add their own models/keys in the UI
either way.

## Volumes

| Path | Description |
| --- | --- |
| `/config` | All persistent state: Durable Object, KV, and R2 data for every user, gadget, and blueprint. Back this up. |

## Custom domain / reverse proxy

Put any reverse proxy (Caddy, nginx, Traefik, a Cloudflare Tunnel) in front of port 8787 and set
`PUBLIC_BASE_URL` to the public URL. The app itself is host-agnostic; `PUBLIC_BASE_URL` is what
OAuth gatekeepers use to build their redirect URIs (`$PUBLIC_BASE_URL/gatekeeper/<vendor>/oauth`).

WebSockets are used heavily (Cap'n Web RPC) — make sure the proxy forwards upgrade headers.
Example Caddyfile:

```
os.example.com {
    reverse_proxy localhost:8787
}
```

## Image tags

| Tag | Meaning |
| --- | --- |
| `latest` | Most recent successful build of upstream `main`. |
| `main-<sha>` | Exact upstream commit the image was built from — pin this for reproducibility. |
| `YYYYMMDD` | Daily pointer. |
| `v<version>` | Upstream `package.json` version (static at `1.0.0` until upstream starts versioning). |

## What's changed vs upstream

Two small deltas, both documented in [`patches/README.md`](patches/README.md):

1. **`dev.ip = 0.0.0.0`** in the generated wrangler config (build step in the Dockerfile) —
   upstream binds localhost, which is unreachable through Docker's port mapping.
2. **Env-configured deployment-wide models** (`patches/0001-…`) — upstream only supports
   per-user keys entered in the UI, or Cloudflare AI Gateway mode. This patch merges models from
   `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GOOGLE_API_KEY` into every user's model list,
   mirroring upstream's existing AI Gateway pattern.

Everything else is stock upstream, cloned at build time and pinned to the exact commit named in
the image tag.

## Building locally

```sh
docker build -t cloudflare-os .                                   # upstream main
docker build --build-arg UPSTREAM_SHA=<sha> -t cloudflare-os .    # pinned commit
```

## License

This packaging (Dockerfile, entrypoint, workflow, patches) is [MIT](LICENSE). Cloudflare OS
itself is licensed by upstream — see
[cloudflare/cloudflare-os](https://github.com/cloudflare/cloudflare-os/blob/main/LICENSE).
