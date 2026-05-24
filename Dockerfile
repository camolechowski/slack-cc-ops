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

RUN addgroup -g "${DOCKER_GID}" -S hostdocker && \
    addgroup -g 1001 -S botuser && \
    adduser -S -D -u 1001 -G botuser botuser && \
    addgroup botuser hostdocker && \
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
