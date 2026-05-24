FROM oven/bun:1-alpine AS base

ARG DOCKER_GID=999

RUN apk add --no-cache \
    bash \
    curl \
    docker-cli \
    dumb-init \
    git \
    openssh-client

RUN bun install -g @anthropic-ai/claude-code

WORKDIR /app

COPY package.json bun.lock ./

RUN bun install --frozen-lockfile --production

COPY . .

# If the host's docker GID already exists in the image (e.g. on Mac
# Desktop the socket is gid 1 == bin), add botuser to that existing
# group instead of creating a new 'hostdocker' group.
RUN HOST_DOCKER_GROUP="$(getent group "${DOCKER_GID}" | cut -d: -f1)"; \
    if [ -z "$HOST_DOCKER_GROUP" ]; then \
      addgroup -g "${DOCKER_GID}" -S hostdocker; \
      HOST_DOCKER_GROUP=hostdocker; \
    fi && \
    addgroup -g 1001 -S botuser && \
    adduser -S -D -u 1001 -G botuser botuser && \
    addgroup botuser "$HOST_DOCKER_GROUP" && \
    mkdir -p /home/botuser /state/claude-config /state/inbox && \
    chown -R botuser:botuser /app /home/botuser /state /usr/local/bin

ENV CLAUDE_CONFIG_DIR=/state/claude-config
ENV HOME=/home/botuser
ENV NODE_ENV=production

USER botuser

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD test -S /state/inbox/health.sock || exit 1

ENTRYPOINT ["dumb-init", "--"]
CMD ["bash", "/app/scripts/entrypoint.sh"]
