# Patches

Applied on top of upstream [cloudflare/cloudflare-os](https://github.com/cloudflare/cloudflare-os)
at image build time with `git apply --3way` (see the Dockerfile). If upstream drifts far enough
that a patch no longer applies, the build fails loudly; regenerate the patch against new upstream.

| Patch | What it does |
| --- | --- |
| `0001-env-configured-deployment-wide-models.patch` | Adds `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `GOOGLE_API_KEY` env support: every user gets that provider's suggested models with no key entry in the UI. New file `packages/workshop-backend/src/env-models.ts` plus small hooks in `user.ts`, `env.d.ts`, and `run-dev-server.js`, mirroring upstream's AI Gateway pattern. AI Gateway mode takes priority when both are configured. |

(The `dev.ip = 0.0.0.0` fix lives as a build step in the Dockerfile, not a patch — it edits
generated config via the JSON parser, so it survives upstream edits to `wrangler.jsonc`.)

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
