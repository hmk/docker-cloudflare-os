# Patches

Applied on top of upstream [cloudflare/cloudflare-os](https://github.com/cloudflare/cloudflare-os)
at image build time with `git apply --3way` (see the Dockerfile). If upstream drifts far enough
that a patch no longer applies, the build fails loudly; regenerate the patch against new upstream.

| Patch | What it does |
| --- | --- |
| `0001-env-configured-deployment-wide-models.patch` | Adds `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GOOGLE_API_KEY` env support: every user gets that provider's suggested models with no key entry in the UI. New file `packages/workshop-backend/src/env-models.ts` plus small hooks in `user.ts`, `env.d.ts`, and `run-dev-server.js`, mirroring upstream's AI Gateway pattern. AI Gateway mode takes priority when both are configured. |
| `0002-gatekeeper-base-url-from-public-base-url.patch` | Derives each gatekeeper's `BASE_URL` from `PUBLIC_BASE_URL` in `run-dev-server.js`, so OAuth redirect URIs point at the deployment instead of `localhost:8787`. Without it every OAuth gatekeeper (Google, GitHub, Slack, Notion, …) is unusable behind a reverse proxy: consent succeeds, then the callback lands on the *user's own machine*. See below for why this is not simply a missing env var. |

Both patches touch `run-dev-server.js` but in different hunks (0001 in the backend's
`OPTIONAL_FEATURE_VARS`, 0002 in the gatekeeper loop above it), so they apply in either order.

(The `dev.ip = 0.0.0.0` fix lives as a build step in the Dockerfile, not a patch — it edits
generated config via the JSON parser, so it survives upstream edits to `wrangler.jsonc`.)

## Why 0002 exists

Upstream has two ways of standing the stack up, and they disagree about this one variable.

Each gatekeeper builds its OAuth `redirect_uri` from its own `BASE_URL` var
(`packages/gatekeeper-google/src/google.ts`):

```js
return stripTrailingSlashes(env.BASE_URL || "http://localhost:8787/gatekeeper/google");
```

The **deploy** path sets it — `scripts/release/manifest-lib.mjs` assigns
`BASE_URL = $PUBLIC_BASE_URL/gatekeeper/<shortName>` for every gatekeeper. The **dev-server**
path, which is what this image runs, does not: `run-dev-server.js` passes gatekeepers only
`CLIENT_ID`/`CLIENT_SECRET` plus a short passthrough list covering the two MCP gatekeepers.
`PUBLIC_BASE_URL` goes to the *backend* worker, not to the gatekeepers.

So a self-hosted instance has no supported way to set it, and every gatekeeper falls back to
`localhost:8787` no matter what `PUBLIC_BASE_URL` says. Worth noting the in-app configurator
advertises the redirect URI as `{PUBLIC_BASE_URL}/gatekeeper/google/oauth`
(`packages/gatekeeper-google/deploy-inputs.json`) — the UI describes the deploy path's behavior
while the running code does something else, which is what makes this look like a setup mistake.

The patch mirrors the deploy path's derivation rather than inventing a new variable, so the two
paths agree. It only acts when `PUBLIC_BASE_URL` is set (unset means local dev, where the
`localhost` fallback is correct), and it never overrides a `BASE_URL` already in a gatekeeper's
`wrangler.jsonc` — the same precedence `CLIENT_ID`/`CLIENT_SECRET` already use.

This is a candidate to send upstream. If it lands there, drop the patch.

## Regenerating a patch

In a checkout of upstream with the change applied to the working tree:

```sh
git add -N packages/workshop-backend/src/env-models.ts   # -N any new files
git diff -- run-dev-server.js \
    packages/workshop-backend/src/env.d.ts \
    packages/workshop-backend/src/user.ts \
    packages/workshop-backend/src/env-models.ts \
    > patches/0001-env-configured-deployment-wide-models.patch
```

Regenerate 0002 from a **clean** upstream checkout (no other patches applied), so the diff
carries only its own hunk:

```sh
git diff -- run-dev-server.js \
    > patches/0002-gatekeeper-base-url-from-public-base-url.patch
```
