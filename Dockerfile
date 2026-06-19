# ---- Stage 1: build (install all deps + compile TypeScript) ----
    FROM node:18-alpine AS build
    WORKDIR /app
    # Copy manifests first to maximize Docker layer caching.
    COPY package*.json tsconfig.json ./
    # Install all dependencies (including devDependencies needed for tsc).
    RUN npm ci
    # Copy source and compile TypeScript to ./dist.
    COPY src ./src
    RUN npm run build
    # ---- Stage 2: production dependencies only ----
    FROM node:18-alpine AS deps
    WORKDIR /app
    COPY package*.json ./
    RUN npm ci --omit=dev
    # ---- Stage 3: runtime image ----
    FROM node:18-alpine AS runtime
    ENV NODE_ENV=production
    WORKDIR /app
    # Production node_modules from the deps stage.
    COPY --from=deps /app/node_modules ./node_modules
    # Compiled JavaScript from the build stage.
    COPY --from=build /app/dist ./dist
    COPY package*.json ./
    # Run as the built-in non-root user provided by the node image.
    USER node
    EXPOSE 8080
    CMD ["node", "dist/server.js"]