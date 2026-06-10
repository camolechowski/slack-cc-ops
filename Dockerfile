FROM oven/bun:1.3.0-alpine AS base

ARG DOCKER_GID=999

# docker-cli-compose ships the Compose v2 plugin at
# /usr/libexec/docker/cli-plugins/docker-compose so `docker compose ...`
# works in-container. The image is musl/alpine, so the apt
# `docker-compose-plugin` (glibc) is not applicable here.
RUN apk add --no-cache \
    bash \
    curl \
    docker-cli \
    docker-cli-compose \
    dumb-init \
    git \
    github-cli \
    libgcc \
    libstdc++ \
    nodejs \
    npm \
    openssh-client \
    ripgrep \
    tmux

# Install claude-code via npm (matches win monorepo idiom). The npm global
# install lands under /usr/local/lib/node_modules and places the binary at
# /usr/local/bin/claude — world-readable on Alpine and picks the correct
# musl-compatible native binary automatically (no manual symlink dance needed).
ARG CLAUDE_CODE_VERSION=2.1.150
RUN npm install -g --omit=dev @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
 && claude --version

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

HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
  CMD bash /app/scripts/container-healthcheck.sh

ENTRYPOINT ["dumb-init", "--"]
CMD ["bash", "/app/scripts/entrypoint.sh"]
