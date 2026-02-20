FROM node:22-bookworm

# Install Bun (required for build scripts)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /app

# Install extra system packages (e.g. postgresql-client)
ARG OPENCLAW_DOCKER_APT_PACKAGES="postgresql-client"
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

# Clone upstream source at build time
ARG OPENCLAW_VERSION=main
RUN git clone --depth=1 --branch ${OPENCLAW_VERSION} https://github.com/openclaw/openclaw.git /tmp/openclaw-src && \
    cp -a /tmp/openclaw-src/. /app/ && \
    rm -rf /tmp/openclaw-src

RUN pnpm install --frozen-lockfile

# Optionally install Chromium and Xvfb for browser automation.
ARG OPENCLAW_INSTALL_BROWSER=""
RUN if [ -n "$OPENCLAW_INSTALL_BROWSER" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xvfb && \
      node /app/node_modules/playwright-core/cli.js install --with-deps chromium && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

ENV NODE_ENV=production

# Create the openclaw CLI wrapper so `openclaw <cmd>` works
RUN printf '#!/bin/sh\nexec node /app/dist/index.js "$@"\n' > /usr/local/bin/openclaw && \
    chmod +x /usr/local/bin/openclaw

# Allow non-root user to write temp files during runtime
# and install global npm packages (skills, etc.)
RUN chown -R node:node /app /usr/local/lib/node_modules /usr/local/bin /usr/local/share

USER node

CMD ["node", "dist/index.js", "gateway", "--allow-unconfigured"]
