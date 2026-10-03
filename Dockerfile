FROM node:22-alpine AS build
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY tsconfig.json tsconfig.prod.json ./
COPY src ./src
RUN pnpm build:prod

FROM node:22-alpine AS production-dependencies
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --prod --frozen-lockfile

FROM production-dependencies AS migrator
ENV NODE_ENV=production
COPY scripts/migrate-prod.mjs scripts/export-migrations.mjs ./scripts/
COPY supabase/migrations ./supabase/migrations
USER node
CMD ["node", "scripts/migrate-prod.mjs"]

FROM node:22-alpine AS runtime
ENV NODE_ENV=production HOST=0.0.0.0 PORT=5000 ACCOUNT_PORTRAIT_CACHE_DIR=/data/account-portraits
WORKDIR /app
RUN mkdir -p /data/account-portraits && chown -R node:node /data
COPY --chown=node:node package.json ./
COPY --from=production-dependencies --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
USER node
VOLUME ["/data/account-portraits"]
EXPOSE 5000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD node -e "const port = process.env.PORT || 5000; fetch('http://127.0.0.1:' + port + '/healthz').then(response => process.exit(response.ok ? 0 : 1)).catch(() => process.exit(1))"
CMD ["node", "dist/server.js"]
