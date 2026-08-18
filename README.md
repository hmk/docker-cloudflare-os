# docker-cloudflare-os

Self-hosted [Cloudflare OS](https://github.com/cloudflare/cloudflare-os) in a container: the full
stack (router, workshop backend, and all gatekeepers) running on `workerd` via `wrangler dev`,
pre-built at image build time so containers start straight into serving.

Images rebuild automatically within an hour of upstream commits, are smoke-tested before
publishing, and ship for `linux/amd64` + `linux/arm64`:

- Docker Hub: `heimark/cloudflare-os`
- GHCR: `ghcr.io/hmk/cloudflare-os`

Dockerfile, patches, issues, and PRs:
[github.com/hmk/docker-cloudflare-os](https://github.com/hmk/docker-cloudflare-os).

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

Or with compose ([`docker-compose.yml`](https://github.com/hmk/docker-cloudflare-os/blob/main/docker-compose.yml)):

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
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | | Google OAuth app credentials, for Gmail/Docs/Sheets/Calendar/BigQuery connections and Google sign-in. See [Connecting a gatekeeper](#connecting-a-gatekeeper-google-github-). |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | | Same, GitHub. |
| `SLACK_CLIENT_ID` / `SLACK_CLIENT_SECRET` | | Same, Slack. Also `NOTION_`, `SUPABASE_`, `CONFLUENCE_`, `ZOOMINFO_`, and `CLOUDFLARE_OAUTH_` pairs. |

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

## Connecting a gatekeeper (Google, GitHub, …)

Gatekeepers are how gadgets reach third-party services — Gmail, Docs, Sheets, Calendar and
BigQuery all come from the Google one. Each needs an OAuth app you register yourself.

**Upstream's per-gatekeeper READMEs tell you to create a `packages/gatekeeper-<name>/.env`
file.** That does not apply here: this image ships a pre-built tree with no checkout to edit.
Pass the credentials as ordinary container environment variables instead — `run-dev-server.js`
maps `<VENDOR>_CLIENT_ID` / `<VENDOR>_CLIENT_SECRET` onto each gatekeeper worker. Everything
else in those READMEs (which APIs to enable, consent screen, test users, scopes) applies as
written.

Using Google as the example:

1. In the [Cloud Console](https://console.cloud.google.com/), create a project.
2. **APIs & Services → Library**: enable Gmail, Google Docs, Google Drive, Google Sheets,
   Google Calendar, and BigQuery. (Drive is only used to search and display Doc/Sheet metadata
   in the resource pickers; reads go through Docs and Sheets.)
3. **OAuth consent screen** → External. Skip the Scopes page — scopes come from the OAuth
   request, not the console.
4. **Add yourself as a Test User.** While the app is in Testing mode only listed users can
   complete OAuth; skipping this gives `access_denied`.
5. **Credentials → Create OAuth client ID → Web application.** Authorized redirect URI:

   ```
   $PUBLIC_BASE_URL/gatekeeper/google/oauth
   ```

   Exactly — no trailing slash. A mismatch gives `redirect_uri_mismatch`. For local runs with
   no `PUBLIC_BASE_URL`, that is `http://localhost:8787/gatekeeper/google/oauth`.
6. Pass the credentials to the container:

   ```sh
   -e PUBLIC_BASE_URL=https://os.example.com \
   -e GOOGLE_CLIENT_ID=....apps.googleusercontent.com \
   -e GOOGLE_CLIENT_SECRET=... \
   -e AUTH_GATEKEEPERS=google        # optional: adds a "Continue with Google" sign-in button
   ```

   `FILE__GOOGLE_CLIENT_SECRET=/run/secrets/...` works here too.

Then in the app: open a gadget → **Connections** → **+ New Connection** → pick Gmail (or a Doc,
Sheet, Calendar, BigQuery table) → connect the account. During testing Google shows an
"unverified app" warning — **Advanced**, then the "Go to … (unsafe)" link.

`GOOGLE_CLIENT_ID` is unrelated to `GOOGLE_API_KEY` above: the former is the OAuth app for
Gmail/Docs/etc., the latter is a Gemini inference key.

**`PUBLIC_BASE_URL` must be set for any of this to work behind a proxy** — see patch 0002 in
[`patches/README.md`](https://github.com/hmk/docker-cloudflare-os/blob/main/patches/README.md). Stock upstream's dev-server path ignores it when
building gatekeeper redirect URIs and always sends `localhost:8787`, so consent succeeds and the
callback then lands on the user's own machine. This image patches that; it is worth knowing if
you compare against upstream's behavior.

## Image tags

| Tag | Meaning |
| --- | --- |
| `latest` | Most recent successful build of upstream `main`. |
| `main-<sha>` | Most recent build of that upstream commit. Moves if the packaging changes. |
| `main-<sha>-pkg-<sha>` | That upstream commit built with a specific revision of this repo's packaging — **immutable; pin this**. |
| `YYYYMMDD` | Daily pointer (last build of that day wins). |

Upstream publishes no tags or releases, so this image carries no version numbers of its own —
the upstream commit sha is the version. If upstream starts tagging releases, image tags will
mirror theirs.

An image is built from two inputs: upstream's code and this repo's Dockerfile and patches.
`main-<sha>` names only the first, so a packaging-only change republishes it with different
contents. The `-pkg-` tag names both and is the only one that never moves.

## What's changed vs upstream

Three small deltas, all documented in
[`patches/README.md`](https://github.com/hmk/docker-cloudflare-os/blob/main/patches/README.md):

1. **`dev.ip = 0.0.0.0`** in the generated wrangler config (build step in the Dockerfile) —
   upstream binds localhost, which is unreachable through Docker's port mapping.
2. **Env-configured deployment-wide models** (`patches/0001-…`) — upstream only supports
   per-user keys entered in the UI, or Cloudflare AI Gateway mode. This patch merges models from
   `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GOOGLE_API_KEY` into every user's model list,
   mirroring upstream's existing AI Gateway pattern.
3. **Gatekeeper `BASE_URL` from `PUBLIC_BASE_URL`** (`patches/0002-…`) — upstream's deploy path
   sets each gatekeeper's `BASE_URL` but its dev-server path (what this image runs) does not, so
   every OAuth redirect URI points at `localhost:8787` regardless of `PUBLIC_BASE_URL`. This
   patch applies the deploy path's own derivation, which is what makes OAuth gatekeepers usable
   behind a reverse proxy.

Everything else is stock upstream, cloned at build time and pinned to the exact commit named in
the image tag.

## Building locally

```sh
docker build -t cloudflare-os .                                   # upstream main
docker build --build-arg UPSTREAM_SHA=<sha> -t cloudflare-os .    # pinned commit
```

## License

This packaging (Dockerfile, entrypoint, workflow, patches) is
[MIT](https://github.com/hmk/docker-cloudflare-os/blob/main/LICENSE). Cloudflare OS
itself is licensed by upstream — see
[cloudflare/cloudflare-os](https://github.com/cloudflare/cloudflare-os/blob/main/LICENSE).
