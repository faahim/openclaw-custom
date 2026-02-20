# OpenClaw Custom Deployment (Coolify)

Custom Docker deployment for [OpenClaw](https://docs.openclaw.ai/) on [Coolify](https://coolify.io/), with PostgreSQL connectivity and additional system packages baked into the image.

## Why This Repo Exists

Coolify's Docker Compose build pack re-reads `docker-compose.yml` from the git repo on every deploy, overwriting any manual changes to the compose config in the database. The upstream OpenClaw repo's default compose and Dockerfile don't include:

- **`postgresql-client`** — needed to connect to an external PostgreSQL database
- **`openclaw` CLI wrapper** — the upstream image only has `node dist/index.js`, not an `openclaw` binary in PATH
- **Stable CLI container** — the upstream CLI service exits immediately (no persistent command), causing crash-loops under Coolify's `restart: unless-stopped`

This repo wraps the upstream build with these fixes baked in, so everything survives redeployments.

## Architecture

```
faahim/openclaw-custom (this repo)
├── Dockerfile          # Builds from source, adds postgresql-client + openclaw wrapper
└── docker-compose.yml  # Two services: gateway (runs the server) + cli (sleeps, for exec)

  ↓ Coolify clones this repo on each deploy

openclaw/openclaw (upstream, cloned at build time inside Dockerfile)
  └── Source code built via pnpm install && pnpm build && pnpm ui:build
```

**On each deploy, Coolify:**
1. Clones this repo
2. Reads `docker-compose.yml`
3. Builds the Docker image from `Dockerfile` (which clones upstream OpenClaw inside the build)
4. Starts both containers
5. Injects Coolify env vars, labels, networks, and Traefik routing

## Services

| Service | Purpose | Stays running? |
|---------|---------|----------------|
| `openclaw-gateway` | Runs the WebSocket gateway, Control UI, and agent runtime | Yes (`restart: unless-stopped`) |
| `openclaw-cli` | Idle container for running CLI commands via `docker exec` | Yes (`sleep infinity`) |

Both containers share the same image and volumes.

## Environment Variables

Set these in **Coolify > Resource > Environment Variables**:

| Variable | Required | Description |
|----------|----------|-------------|
| `OPENCLAW_GATEWAY_TOKEN` | Yes | Auth token for gateway connections. Generate with `openssl rand -hex 32` |
| `DATABASE_URL` | No | PostgreSQL connection string (e.g. `postgres://user:pass@host:5432/dbname`) |
| `CLAUDE_AI_SESSION_KEY` | No | Claude AI session key for the agent |
| `CLAUDE_WEB_SESSION_KEY` | No | Claude web session key |
| `CLAUDE_WEB_COOKIE` | No | Claude web cookie |

Coolify also auto-injects: `COOLIFY_*`, `SERVICE_*`, `COOLIFY_FQDN`, etc.

### Variables set in docker-compose.yml (not user-configurable):

| Variable | Value | Why |
|----------|-------|-----|
| `HOME` | `/home/node` | Container runs as `node` user |
| `TERM` | `xterm-256color` | Terminal colors for CLI output |
| `BROWSER` | `echo` (CLI only) | Prevents browser open attempts inside the container |

## Volumes

Coolify creates named volumes automatically:

| Compose variable | Coolify volume name | Container path | Contents |
|-----------------|--------------------|--------------------|----------|
| `OPENCLAW_CONFIG_DIR` | `<uuid>_openclaw-config-dir` | `/home/node/.openclaw` | `openclaw.json` config, credentials, sessions |
| `OPENCLAW_WORKSPACE_DIR` | `<uuid>_openclaw-workspace-dir` | `/home/node/.openclaw/workspace` | Agent workspace files |

These persist across redeployments.

## Initial Setup

### 1. Create the resource in Coolify

- Go to your project > environment > **Add New Resource**
- Choose **Docker Compose** as the build pack
- Set the git repository to `https://github.com/faahim/openclaw-custom`
- Set the branch to `production`
- Enable **Connect to predefined network** if you need to reach other Coolify services (e.g. a database)

### 2. Set environment variables

At minimum, set `OPENCLAW_GATEWAY_TOKEN`:

```bash
# Generate a token
openssl rand -hex 32
```

Add it in Coolify > Resource > Environment Variables.

If connecting to a PostgreSQL database on the same Coolify server, add `DATABASE_URL` with the **internal** Docker hostname (not localhost):

```
postgres://user:password@<container-name>:5432/dbname
```

The container name is visible in Coolify under the database resource's settings.

### 3. Deploy

Click **Deploy**. First build takes ~10-15 minutes on ARM64 (compiles from source). Subsequent builds are similar unless Docker layer cache helps.

### 4. Configure the gateway

After the first deploy, the gateway needs a config file. Exec into the gateway container:

```bash
# Find the gateway container name
docker ps --filter "name=openclaw-gateway" --format "{{.Names}}"

# Create initial config
docker exec <gateway-container> node -e "
const fs = require('fs');
const dir = '/home/node/.openclaw';
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(dir + '/openclaw.json', JSON.stringify({
  gateway: {
    mode: 'local',
    port: 18789,
    bind: 'loopback',
    auth: { mode: 'token', token: process.env.OPENCLAW_GATEWAY_TOKEN },
    controlUi: { enabled: true }
  },
  agents: {
    defaults: { workspace: '/home/node/.openclaw/workspace' }
  }
}, null, 2));
console.log('Config created');
"
```

> **Note:** Set `bind: 'loopback'` in the config even though the gateway listens on `0.0.0.0` (from the compose `--bind lan` flag). The config `bind` only affects how CLI commands resolve the gateway URL. Setting it to `loopback` avoids a security warning that blocks CLI operations. The actual listening address comes from the compose command args, and Docker + Traefik handle external routing.

### 5. Verify

```bash
# Check gateway health
docker exec -e OPENCLAW_GATEWAY_TOKEN=<your-token> <gateway-container> openclaw health

# Run doctor
docker exec -e OPENCLAW_GATEWAY_TOKEN=<your-token> <gateway-container> openclaw doctor

# Verify database connectivity (if DATABASE_URL is set)
docker exec <gateway-container> psql "$DATABASE_URL" -c "SELECT version();"
```

## Running CLI Commands

The CLI container exists so you can `docker exec` into it for interactive work, but you can also run commands against the gateway container directly.

```bash
# Via the gateway container (preferred — always running)
docker exec -e OPENCLAW_GATEWAY_TOKEN=<token> <gateway-container> openclaw <command>

# Via the CLI container
docker exec -e OPENCLAW_GATEWAY_TOKEN=<token> <cli-container> openclaw <command>

# Interactive shell
docker exec -it <gateway-container> bash
```

### Common commands

```bash
# Check version
openclaw --version

# Gateway health
openclaw health

# Run diagnostics
openclaw doctor

# List connected channels
openclaw channels list

# Interactive setup wizard
openclaw configure

# Onboarding wizard
openclaw onboard

# Check agent status
openclaw status
```

> **Important:** The `OPENCLAW_GATEWAY_TOKEN` env var must be passed with `-e` on `docker exec` because Coolify encrypts env vars and they may not be available in exec sessions. Alternatively, the gateway reads the token from `openclaw.json` for its own process, but CLI subcommands invoked via exec need it explicitly.

## Updating OpenClaw

### Update to latest (default behavior)

Simply **redeploy** in Coolify. The Dockerfile clones `main` branch of `openclaw/openclaw` at build time, so each redeploy picks up the latest version.

### Pin to a specific version

Edit `Dockerfile` and change the `OPENCLAW_VERSION` default:

```dockerfile
ARG OPENCLAW_VERSION=v2026.2.20
```

Commit and push. Then redeploy in Coolify.

### Check current version

```bash
docker exec <gateway-container> openclaw --version
```

## Database Connectivity

### How it works

- `DATABASE_URL` is set as a Coolify environment variable
- The compose injects it into both containers
- `postgresql-client` (including `psql`) is installed at image build time via the `OPENCLAW_DOCKER_APT_PACKAGES` build arg
- If both services are on the same Coolify server with **Connect to predefined network** enabled, they share the `coolify` Docker network and can reach each other by container name

### Testing the connection

```bash
docker exec <gateway-container> psql "$DATABASE_URL" -c "\dt"
```

### Adding other database packages

Edit `Dockerfile` and modify the `OPENCLAW_DOCKER_APT_PACKAGES` default:

```dockerfile
ARG OPENCLAW_DOCKER_APT_PACKAGES="postgresql-client mysql-client"
```

## Coolify-Specific Notes

### How Coolify handles Docker Compose

Coolify maintains two compose fields in its database:
- `docker_compose_raw` — re-read from the git repo's `docker-compose.yml` on every deploy
- `docker_compose` — the "parsed" version with Coolify labels, networks, Traefik config, container names, etc., regenerated from `docker_compose_raw` on every deploy

**Any manual edits to either field in the database will be overwritten on the next deploy.** This is why this custom repo exists — the only durable way to change the compose is to change what's in the git repo.

### What Coolify adds on deploy

Coolify automatically adds to the parsed compose:
- Container names with UUIDs
- `coolify.*` labels
- `traefik.*` labels for HTTPS routing
- Networks: the app-specific network + `coolify` predefined network
- Volume names prefixed with the resource UUID
- `COOLIFY_*` and `SERVICE_*` environment variables
- `restart: unless-stopped` to all services

### Domain / HTTPS

Configured in Coolify > Resource > Settings. Coolify sets up Traefik routing with Let's Encrypt automatically. The gateway's Control UI is accessible at `https://your-domain/openclaw/`.

### Predefined network

Enable **Connect to predefined network** in Coolify resource settings to allow containers to communicate with other Coolify-managed services (databases, other apps) on the same server via Docker container names.

## Troubleshooting

### "Permission denied" when running `openclaw`

The `openclaw` wrapper should be at `/usr/local/bin/openclaw` (baked into the image). If you get this error, the image may not have been built from this repo's Dockerfile. Verify:

```bash
docker exec <container> which openclaw
# Should output: /usr/local/bin/openclaw

docker exec <container> cat /usr/local/bin/openclaw
# Should output:
# #!/bin/sh
# exec node /app/dist/index.js "$@"
```

### CLI container crash-looping

The compose sets `command: ["sleep", "infinity"]` for the CLI container. If Coolify overwrites this (e.g. from a stale `docker_compose` field), the container will crash-loop because the default entrypoint prints help and exits. Fix: redeploy (Coolify re-reads from git).

### "The payload is invalid" 500 error on Coolify resource page

This happens when an environment variable's `value` column in Coolify's database doesn't match its `is_literal` flag. If `is_literal=false`, the value must be encrypted with Coolify's app key. If someone manually edited env vars in the DB with raw values and `is_literal=true`, and later changed `is_literal` without re-encrypting, Coolify's UI crashes.

Fix: use Coolify's artisan tinker to re-encrypt:
```bash
docker exec coolify php artisan tinker --execute="echo encrypt('your-value');"
```
Then update the DB row with the encrypted value and `is_literal=false`.

### Gateway "SECURITY ERROR: plaintext ws://"

The gateway's CLI commands refuse to connect over `ws://` to non-loopback addresses. Set `bind: "loopback"` in `openclaw.json` (config only — doesn't affect the actual listening address, which comes from the compose command `--bind lan`).

### Gateway "unauthorized: gateway token missing"

Pass the token via `-e` flag when using `docker exec`:
```bash
docker exec -e OPENCLAW_GATEWAY_TOKEN=<token> <container> openclaw health
```

### Build takes 10+ minutes

Normal for ARM64 servers. The build compiles OpenClaw from source (TypeScript + Vite). The `chown -R node:node /app` step near the end is particularly slow. Docker layer caching may help on subsequent builds if the base layers haven't changed.

## File Reference

| File | Purpose |
|------|---------|
| `Dockerfile` | Custom build: upstream OpenClaw + postgresql-client + openclaw CLI wrapper |
| `docker-compose.yml` | Two services (gateway + cli) with env vars, volumes, ports |
| `README.md` | This file |
