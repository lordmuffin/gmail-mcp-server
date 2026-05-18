# =============================================================================
# Stage 1 — builder
# Install all dependencies (including devDeps), compile TypeScript, then prune
# devDependencies so only production node_modules are carried forward.
# =============================================================================
FROM node:20-alpine AS builder

WORKDIR /app

# Copy manifests first — Docker can cache the npm ci layer independently of
# source changes when only package files change.
COPY package.json package-lock.json ./

# Install ALL dependencies (devDeps required for tsc)
RUN npm ci --ignore-scripts

# Copy build configuration and source
COPY tsconfig.json ./
COPY src/ ./src/

# Compile TypeScript → dist/
RUN npm run build

# Strip devDependencies in-place; only production deps remain in node_modules
RUN npm prune --omit=dev

# =============================================================================
# Stage 2 — runner
# Minimal runtime image: compiled output + production node_modules only.
# No build toolchain, no TypeScript source, no dev dependencies.
# =============================================================================
FROM node:20-alpine AS runner

# NODE_ENV informs Express and other libraries that check it
ENV NODE_ENV=production
# Default data directory for encrypted token storage
ENV DATA_DIR=/app/data
# Always disable local TLS in Docker — handle TLS at the reverse proxy / platform
# layer (nginx, Caddy, Traefik, Railway, Fly.io, etc.)
ENV DISABLE_TLS=1

WORKDIR /app

# Create the data directory and assign ownership before dropping privileges.
# The built-in node user (UID 1000) is present in all official Node.js images.
RUN mkdir -p /app/data && chown -R node:node /app/data

# Copy pruned production node_modules from builder
COPY --from=builder --chown=node:node /app/node_modules ./node_modules

# Copy compiled JavaScript output from builder
COPY --from=builder --chown=node:node /app/dist ./dist

# Copy package.json — required by Node.js ESM to resolve "type": "module"
COPY --chown=node:node package.json ./

# Drop to non-root for all subsequent layers and the running container
USER node

EXPOSE 3000

# Exec form (JSON array): node is PID 1, no shell wrapper.
# SIGTERM and SIGINT are delivered directly to the node process, enabling
# graceful shutdown without the default 10-second Docker stop timeout.
ENTRYPOINT ["node", "dist/index.js"]
