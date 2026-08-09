# Cloudflare OS — self-hosted container image.
#
# Clones cloudflare/cloudflare-os at build time (pinned to UPSTREAM_SHA), applies the patches in
# patches/, and bakes the build in so containers start straight into serving. Runs the whole
# stack (dev-router + workshop-backend + every gatekeeper) on workerd via `wrangler dev`, the
# same thing upstream's `pnpm run-local` does.
#
# Upstream is explicit that the wrangler/local path is not production-ready. This image is for
# self-hosting/evaluation, not for running a company on.
#
#   docker run -d --name cloudflare-os \
#     -p 8787:8787 \
#     -v ./data:/config \
#     -e PUID=1000 -e PGID=1000 \
#     -e ANTHROPIC_API_KEY=sk-ant-... \
#     -e PUBLIC_BASE_URL=https://os.example.com \
#     <image>
#
# Environment:
#   PUID / PGID          uid/gid to run as (default 911); /config is chowned to match
#   ANTHROPIC_API_KEY    deployment-wide Anthropic models for every user (no key entry in UI)
#   OPENAI_API_KEY       same, OpenAI
#   GOOGLE_API_KEY       same, Google
#   FILE__<VAR>          read <VAR> from a file (docker secrets), e.g. FILE__ANTHROPIC_API_KEY
#   PUBLIC_BASE_URL      public URL of the deployment (needed behind a reverse proxy / domain)
#   AUTH_GATEKEEPERS, DISABLE_PASSWORD_AUTH, CF_AI_GATEWAY*, ...   see upstream
#                        docs/public-server.md

# ---------------------------------------------------------------------------
# Stage 1: clone upstream, apply patches, install dependencies, build.
# ---------------------------------------------------------------------------
FROM node:22.23.1-bookworm-slim AS build

# Upstream commit to build. The CI workflow pins this to upstream's current HEAD so builds are
# reproducible and tagged by the exact source they contain; "main" works for local builds.
ARG UPSTREAM_REPO=https://github.com/cloudflare/cloudflare-os.git
ARG UPSTREAM_SHA=main

ENV PNPM_HOME=/pnpm \
    PATH=/pnpm:$PATH \
    CI=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && corepack enable

WORKDIR /app
RUN git clone --filter=blob:none "$UPSTREAM_REPO" . \
 && git checkout --detach "$UPSTREAM_SHA" \
 && git log -1 --format='upstream: %h %s'

# Apply our patches (see patches/README.md for what each one does). `git apply --3way` merges
# through context drift; if upstream changes conflict outright, the build fails here — regenerate
# the patch against new upstream rather than shipping a half-patched image.
#
# One patch per invocation, staging in between. --3way resolves against the index, so passing
# several patches to a single `git apply` makes each one after the first fail with "does not
# match index" once an earlier patch has touched the same file — 0001 and 0002 both edit
# run-dev-server.js. Staging after each makes the next patch's 3-way base the patched tree.
COPY patches/ /tmp/patches/
RUN for patch in /tmp/patches/*.patch; do \
      echo "applying: $(basename "$patch")" \
   && git apply --3way "$patch" \
   && git add -A \
   || exit 1; \
    done \
 && git log -1 --format='patched on: %h'

RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm install --frozen-lockfile

# `wrangler dev` binds to localhost by default, which is unreachable through Docker's port
# mapping. run-dev-server.js gives no way to pass `--ip`, but it copies every key from
# wrangler.jsonc into the generated wrangler.dev.jsonc, so set it in config instead. Done as a
# build step rather than a patch file because it survives any upstream edit to wrangler.jsonc.
RUN node -e "\
  const fs = require('node:fs'); \
  const { parse } = require('/app/node_modules/jsonc-parser'); \
  const config = parse(fs.readFileSync('wrangler.jsonc', 'utf8')); \
  config.dev = { ...config.dev, ip: '0.0.0.0', port: 8787 }; \
  fs.writeFileSync('wrangler.jsonc', JSON.stringify(config, null, 2) + '\n'); \
  console.log('patched wrangler.jsonc dev.ip=0.0.0.0'); \
"

# Same two builds upstream's scripts/run-local.mjs performs: the backend imports typed-storage
# from its built `dist`, and the backend serves the frontend bundle as static assets.
RUN pnpm --filter @gadgets/typed-storage build \
 && pnpm --filter @gadgets/workshop-frontend exec vite build

# Drop the git metadata; runtime doesn't need it (saves ~100MB in the final image).
RUN rm -rf /app/.git

# ---------------------------------------------------------------------------
# Stage 2: runtime.
# ---------------------------------------------------------------------------
FROM node:22.23.1-bookworm-slim AS runtime

# workerd needs libstdc++ (present in the slim base). ca-certificates is required for outbound
# HTTPS to model providers and gatekeeper APIs. `wrangler dev` shells out to `ps` to track the
# workerd children it spawns, and exits with `spawn ps ENOENT` without procps. gosu + tini
# support the PUID/PGID entrypoint.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates procps tini gosu \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g 911 abc \
 && useradd -u 911 -g 911 -d /app -s /bin/bash abc

ENV PNPM_HOME=/pnpm \
    PATH=/pnpm:$PATH \
    NODE_ENV=production \
    CI=1 \
    WRANGLER_SEND_METRICS=false
RUN corepack enable

WORKDIR /app
COPY --from=build /app /app
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && chown -R abc:abc /app

# All persistent state (Durable Object / KV / R2 data) lives in /config; the entrypoint links
# it into the path wrangler persists to.
VOLUME ["/config"]

EXPOSE 8787

# tini reaps the workerd/esbuild children run-dev-server.js spawns and forwards SIGTERM.
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["node", "run-dev-server.js", "--serve-frontend-assets"]
