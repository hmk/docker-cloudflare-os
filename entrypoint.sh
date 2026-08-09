#!/bin/bash
# Entrypoint for the cloudflare-os container. linuxserver.io-style conventions:
#
#   /config          single volume holding all persistent state
#   PUID / PGID      uid/gid to run as (default 911:911); /config is chowned to match
#   FILE__<VAR>      read <VAR>'s value from the named file (docker secrets), e.g.
#                    FILE__ANTHROPIC_API_KEY=/run/secrets/anthropic_key
#   TZ               standard tz database name
set -euo pipefail

PUID=${PUID:-911}
PGID=${PGID:-911}

# ---------------------------------------------------------------------------
# FILE__ secret expansion (linuxserver.io convention).
# ---------------------------------------------------------------------------
while IFS='=' read -r -d '' name value; do
  if [[ "$name" == FILE__* ]]; then
    target=${name#FILE__}
    if [[ -f "$value" ]]; then
      export "$target"="$(< "$value")"
      echo "[cloudflare-os] set $target from $value"
    else
      echo "[cloudflare-os] WARNING: $name points to '$value' which does not exist" >&2
    fi
  fi
done < <(env -0)

# ---------------------------------------------------------------------------
# /config: all persistent state lives here.
#
# wrangler persists Durable Object / KV / R2 state under .wrangler/state (relative to the repo
# root). .wrangler also holds ephemeral generated build output (.wrangler/validate, .wrangler/tmp),
# so only the state subdirectory is redirected into the volume.
# ---------------------------------------------------------------------------
mkdir -p /config/state /app/.wrangler
if [[ ! -L /app/.wrangler/state ]]; then
  rm -rf /app/.wrangler/state
  ln -s /config/state /app/.wrangler/state
fi

# ---------------------------------------------------------------------------
# PUID/PGID: run as the requested uid/gid, chowning only what that user must write.
# ---------------------------------------------------------------------------
if [[ "$(id -u)" == "0" ]]; then
  groupmod -o -g "$PGID" abc
  usermod -o -u "$PUID" abc

  # Skip the recursive chowns when ownership already matches (they're slow on /app's
  # node_modules); a changed PUID/PGID re-triggers them. Checked before the single-node
  # chown below so a PUID change still re-owns existing state files.
  if [[ "$(stat -c '%u:%g' /config/state)" != "$PUID:$PGID" ]]; then
    chown -R abc:abc /config
  fi
  # The mkdir/symlink above ran as root; hand those (and the volume mount point) to abc —
  # single nodes, so this is cheap.
  chown abc:abc /config /config/state /app/.wrangler
  # The app writes generated config and build output into the checkout at startup
  # (wrangler.dev.jsonc files, packages/*/src/generated, .wrangler/tmp, node_modules/.cache).
  if [[ "$(stat -c '%u:%g' /app/package.json)" != "$PUID:$PGID" ]]; then
    chown -R abc:abc /app
  fi

  echo "[cloudflare-os] running as uid=$PUID gid=$PGID"
  exec gosu abc "$@"
else
  # Container was started with --user; just run.
  exec "$@"
fi
