# ── Stage 1: Build ────────────────────────────────────────────────────────────
# Build context must be the repo root so the ../shared path dep is reachable.
# docker build -f web_dashboard/Dockerfile -t kryz-dashboard .
FROM dart:stable AS builder

WORKDIR /app

# Copy the shared package (path dep referenced as ../shared from web_dashboard)
COPY shared/ /shared/

# Fetch dependencies first for better layer caching
COPY web_dashboard/pubspec.yaml web_dashboard/pubspec.lock ./
RUN dart pub get

# Copy source and compile to a self-contained native executable
COPY web_dashboard/ ./
RUN dart compile exe bin/server.dart -o bin/server

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/bin/server ./server

EXPOSE 8080

# atSign keys are mounted at runtime via a volume.
# Override CMD to supply the atSign, e.g.:
#   docker run -v ~/.atsign/keys:/root/.atsign/keys:ro kryz-dashboard -a @yoursign
ENTRYPOINT ["/app/server"]
CMD ["--help"]
