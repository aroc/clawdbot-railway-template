# Build clawdbot from source to avoid npm packaging gaps (some dist files are not shipped).
FROM node:22-bookworm AS clawdbot-build
# Dependencies needed for clawdbot build
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*
# Install Bun (clawdbot build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"
RUN corepack enable
WORKDIR /clawdbot
# Pin to a known ref (tag/branch). Updated to OpenClaw v2026.2.14
ARG CLAWDBOT_GIT_REF=v2026.2.14
RUN git clone --depth 1 --branch "${CLAWDBOT_GIT_REF}" https://github.com/openclaw/openclaw.git .
# Patch: relax version requirements for packages that may reference unpublished versions.
# Scope this narrowly to avoid surprising dependency mutations.
RUN set -eux; \
  for f in \
    ./extensions/memory-core/package.json \
    ./extensions/googlechat/package.json \
  ; do \
    if [ -f "$f" ]; then \
      sed -i -E 's/"(clawdbot|openclaw)"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    fi; \
  done
RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV CLAWDBOT_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build

# Runtime image
FROM node:22-bookworm
ENV NODE_ENV=production
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
  && rm -rf /var/lib/apt/lists/*

# Install ngrok for tunneling
RUN curl -s https://ngrok-agent.s3.amazonaws.com/ngrok.asc | tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null \
  && echo "deb https://ngrok-agent.s3.amazonaws.com buster main" | tee /etc/apt/sources.list.d/ngrok.list \
  && apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ngrok \
  && rm -rf /var/lib/apt/lists/*

# Install Playwright with bundled Chromium for browser automation
RUN npm install -g playwright && npx playwright install --with-deps chromium

# Install Claude Code CLI for debugging and maintenance
RUN npm install -g @anthropic-ai/claude-code

# Install Bird CLI for Twitter/X integration (https://github.com/steipete/bird)
RUN npm install -g @steipete/bird

# Install gog CLI for Google services - Gmail, Calendar, Drive (https://github.com/steipete/gogcli)
RUN curl -sL https://github.com/steipete/gogcli/releases/download/v0.9.0/gogcli_0.9.0_linux_amd64.tar.gz | tar -xz -C /usr/local/bin gog

WORKDIR /app
# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force
# Copy built clawdbot
COPY --from=clawdbot-build /clawdbot /clawdbot
# Provide an openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /clawdbot/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw
COPY src ./src
ENV PORT=8080
EXPOSE 8080
CMD ["node", "src/server.js"]
