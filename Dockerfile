FROM oven/bun:1-alpine AS base

ARG DOCKER_GID=999

RUN apk add --no-cache \
    bash \
    curl \
    docker-cli \
    dumb-init \
    git \
    openssh-client \
    tmux

# BUN_INSTALL=/usr/local so the global install (and its arch-specific
# platform packages) lands under a world-readable path. Default $HOME/.bun
# puts the real binary under /root/.bun which is mode 700 — the symlink in
# /usr/local/bin/claude resolves but the target isn't reachable by non-root.
#
# Bun's install also creates /usr/local/bin/claude pointing at the glibc
# variant (claude-code-linux-arm64/claude). Alpine is musl, so the glibc
# binary fails to exec ("required file not found"). Re-point at the musl
# variant after install.
RUN BUN_INSTALL=/usr/local bun install -g @anthropic-ai/claude-code && \
    MUSL_BIN="$(find /usr/local/install/global/node_modules/@anthropic-ai -name claude -path '*-musl/claude' | head -1)" && \
    if [ -n "$MUSL_BIN" ]; then ln -sf "$MUSL_BIN" /usr/local/bin/claude; fi

WORKDIR /app

COPY package.json bun.lock ./

RUN bun install --frozen-lockfile --production

COPY . .

# If the host's docker GID already exists in the image (e.g. on Mac
# Desktop the socket is gid 1 == bin), add botuser to that existing
# group instead of creating a new 'hostdocker' group.
#
# On Docker Desktop for macOS, the mounted socket can still present inside the
# container as root:root (gid 0) even when the host-side stat looks different.
# Keep botuser in group 0 as well or every `docker ...` call from the bot will
# fail with "permission denied while trying to connect to the Docker daemon".
RUN HOST_DOCKER_GROUP="$(getent group "${DOCKER_GID}" | cut -d: -f1)"; \
    if [ -z "$HOST_DOCKER_GROUP" ]; then \
      addgroup -g "${DOCKER_GID}" -S hostdocker; \
      HOST_DOCKER_GROUP=hostdocker; \
    fi && \
    addgroup -g 1001 -S botuser && \
    adduser -S -D -s /bin/bash -u 1001 -G botuser botuser && \
    addgroup botuser "$HOST_DOCKER_GROUP" && \
    addgroup botuser root && \
    mkdir -p /home/botuser /state/claude-config /state/inbox && \
    chown -R botuser:botuser /app /home/botuser /state /usr/local/bin

ENV CLAUDE_CONFIG_DIR=/state/claude-config
ENV HOME=/home/botuser
ENV NODE_ENV=production

USER botuser

# Healthcheck: bun server.ts is the channel MCP. If it's running, we're alive
# enough to receive Slack events. (retrodigio's server.ts doesn't expose a
# unix socket or HTTP endpoint, so process-presence is the simplest reliable
# signal.) Entrypoint also has its own liveness loop that exits on bun death
# so compose can restart us; this healthcheck makes docker label the state.
HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
  CMD pgrep -f "bun.*server.ts" >/dev/null || exit 1

ENTRYPOINT ["dumb-init", "--"]
CMD ["bash", "/app/scripts/entrypoint.sh"]
