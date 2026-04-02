FROM node:20-slim

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

COPY tsconfig.json ./
COPY src/ ./src/
RUN npx tsc

# Create data directory for token storage
RUN mkdir -p /app/data

ENV NODE_ENV=production
ENV DATA_DIR=/app/data

EXPOSE 3000

CMD ["node", "dist/index.js"]
