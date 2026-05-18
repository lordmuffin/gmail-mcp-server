# Docker Usage — Gmail MCP Server

This guide covers building and running the Gmail MCP server as a Docker container.

---

## Prerequisites

- Docker 20.10 or later
- A Google Cloud project with the **Gmail API** enabled
- **OAuth 2.0 credentials** (Client ID + Client Secret) created as a **Web application**
  type in Google Cloud Console
- The redirect URI `https://<YOUR_SERVER_URL>/oauth/callback` added to the OAuth client's
  authorized redirect URIs

---

## Build the Image

Run from the repository root (the directory that contains the `Dockerfile`):

```bash
docker build -t gmail-mcp-server:latest .
```

To tag with a specific version at the same time:

```bash
docker build -t gmail-mcp-server:1.0.0 -t gmail-mcp-server:latest .
```

The build uses a two-stage process: the first stage compiles TypeScript; the second stage
produces a minimal Alpine image containing only the compiled output and production
dependencies (~200 MB). No build toolchain or source files are present in the final image.

---

## Run the Container

All required secrets are supplied at runtime via `-e` flags. They are **never** baked
into the image.

The server listens on plain HTTP (TLS is disabled inside the container by default and
should be handled by a reverse proxy in front of it — see [TLS Notes](#tls--reverse-proxy-notes)).

### Option A — Persistent token storage via volume mount

Use this when running on a server or VM with local disk. OAuth tokens survive container
restarts as long as the volume is preserved.

```bash
# Create the named volume once
docker volume create gmail-mcp-data

docker run -d \
  --name gmail-mcp \
  --restart unless-stopped \
  -p 3000:3000 \
  -v gmail-mcp-data:/app/data \
  -e GOOGLE_CLIENT_ID="your-client-id.apps.googleusercontent.com" \
  -e GOOGLE_CLIENT_SECRET="your-client-secret" \
  -e ENCRYPTION_KEY="replace-with-a-random-string-of-32-or-more-characters" \
  -e ADMIN_PASSWORD="replace-with-a-strong-admin-password" \
  -e SERVER_URL="https://your-app.example.com" \
  gmail-mcp-server:latest
```

### Option B — Stateless deployment via TOKENS_DATA environment variable

Use this for PaaS / cloud deployments (Railway, Fly.io, Render, Cloud Run, etc.) where
the container filesystem is ephemeral. The encrypted token store is loaded from and
exported to the `TOKENS_DATA` environment variable as a Base64-encoded JSON blob.

```bash
docker run -d \
  --name gmail-mcp \
  --restart unless-stopped \
  -p 3000:3000 \
  -e GOOGLE_CLIENT_ID="your-client-id.apps.googleusercontent.com" \
  -e GOOGLE_CLIENT_SECRET="your-client-secret" \
  -e ENCRYPTION_KEY="replace-with-a-random-string-of-32-or-more-characters" \
  -e ADMIN_PASSWORD="replace-with-a-strong-admin-password" \
  -e SERVER_URL="https://your-app.example.com" \
  -e TOKENS_DATA="<base64-blob-copied-from-the-setup-page>" \
  gmail-mcp-server:latest
```

After connecting Gmail accounts via the `/setup` page, copy the `TOKENS_DATA` value
shown on that page and set it as an environment variable in your deployment platform.
The server will seed its token store from that value on the next restart.

---

## Environment Variables Reference

### Required

| Variable               | Description                                                                |
|------------------------|----------------------------------------------------------------------------|
| `GOOGLE_CLIENT_ID`     | OAuth 2.0 Client ID from Google Cloud Console                              |
| `GOOGLE_CLIENT_SECRET` | OAuth 2.0 Client Secret                                                    |
| `ENCRYPTION_KEY`       | Random string ≥32 characters; used for AES-256-GCM refresh token encryption |
| `ADMIN_PASSWORD`       | Password protecting the `/setup` admin page                                |
| `SERVER_URL`           | Public HTTPS URL of this server (e.g. `https://your-app.example.com`); must match the OAuth redirect URI registered in Google Cloud |

### Optional

| Variable       | Default     | Description                                                                           |
|----------------|-------------|---------------------------------------------------------------------------------------|
| `PORT`         | `3000`      | HTTP port the server binds to                                                         |
| `DATA_DIR`     | `/app/data` | Directory for the `accounts.json` encrypted token file                                |
| `DISABLE_TLS`  | `1`         | Set to `1` when behind a TLS-terminating proxy. **Already set to `1` in the image** — do not override to `0` unless you mount real TLS certificates |
| `TOKENS_DATA`  | _(unset)_   | Base64-encoded JSON blob; alternative to a volume for stateless deployments           |
| `LOG_LEVEL`    | _(unset)_   | Set to `debug` for verbose request/response logging to stderr                         |
| `NODE_ENV`     | `production`| Already set in the image; do not override                                             |

---

## Setting Up Google OAuth

1. Open [Google Cloud Console](https://console.cloud.google.com/) and select or create a
   project.
2. Navigate to **APIs & Services > Library** and enable the **Gmail API**.
3. Navigate to **APIs & Services > Credentials** and click **Create Credentials >
   OAuth 2.0 Client ID**.
4. Choose **Web application** as the application type.
5. Under **Authorized redirect URIs**, add:
   ```
   https://your-app.example.com/oauth/callback
   ```
   Replace the domain with the value you will set for `SERVER_URL`.
6. Copy the generated **Client ID** and **Client Secret** into the `GOOGLE_CLIENT_ID` and
   `GOOGLE_CLIENT_SECRET` environment variables.

---

## Connecting Gmail Accounts

Navigate to the admin setup page and authenticate with the `ADMIN_PASSWORD`:

```
https://your-app.example.com/setup
```

Click **+ Add Gmail Account** and complete the Google OAuth consent flow. After
authorization you are redirected back to the setup page, which lists the newly connected
account.

For stateless deployments (Option B): copy the `TOKENS_DATA` value displayed on the setup
page and update the `TOKENS_DATA` environment variable in your platform's dashboard before
the next container restart.

---

## MCP Client Configuration

This server uses the **StreamableHTTP / SSE transport** — MCP clients connect over HTTP,
not stdio. Point your MCP client at:

```
https://your-app.example.com/mcp
```

Example Claude Desktop configuration (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "gmail": {
      "type": "http",
      "url": "https://your-app.example.com/mcp"
    }
  }
}
```

---

## Useful Endpoints

| Endpoint        | Method | Description                                                       |
|-----------------|--------|-------------------------------------------------------------------|
| `/health`       | GET    | Health check; returns `{"status":"ok","accounts":<n>}`            |
| `/setup`        | GET    | Admin page for connecting and removing Gmail accounts             |
| `/mcp`          | POST   | MCP JSON-RPC endpoint (StreamableHTTP transport)                  |
| `/mcp`          | GET    | MCP SSE stream endpoint                                           |
| `/oauth/start`  | GET    | Initiates the Google OAuth flow (called from `/setup`)            |
| `/oauth/callback` | GET  | OAuth redirect target; registered in Google Cloud Console         |

Health check example:

```bash
curl https://your-app.example.com/health
```

---

## TLS / Reverse Proxy Notes

The container sets `DISABLE_TLS=1` by default. The application listens on **plain HTTP**
on port 3000 and expects TLS termination to be handled externally — by a reverse proxy
(nginx, Caddy, Traefik) or by the platform (Railway, Fly.io, Render, Cloud Run).

Do **not** expose port 3000 directly to the internet without TLS in front of it. The
OAuth callback and the admin password travel over this connection.

---

## Data Persistence Summary

| Approach           | How tokens survive restarts                                  | Best for                           |
|--------------------|--------------------------------------------------------------|------------------------------------|
| Volume mount       | `accounts.json` on a named Docker volume at `/app/data`      | VPS / self-hosted servers          |
| `TOKENS_DATA` var  | Base64-encoded blob set as an environment variable           | PaaS / cloud (Railway, Fly, Render)|

Both approaches encrypt refresh tokens at rest with AES-256-GCM using the `ENCRYPTION_KEY`
you provide.

---

## Generating a Strong ENCRYPTION_KEY

```bash
# Linux / macOS
openssl rand -base64 32

# Or with Python
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

Use the output as the value for `ENCRYPTION_KEY`.
