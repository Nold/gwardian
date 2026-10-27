# =============================================================================
# ASH Backend - Multi-stage Dockerfile
# =============================================================================
#
# Optimized for:
# - Minimal final image size (~25MB)
# - Security (non-root user, minimal attack surface)
# - Docker layer caching for dependencies
#
# Build: docker build -t ash-backend .
# Run:   docker run -p 8080:8080 ash-backend
#
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Builder - Build the application
# -----------------------------------------------------------------------------
FROM rust:1.99-slim-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy manifests first for better caching
# Remove dev-dependencies that have path references outside the build context
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && \
    echo "fn main() {}" > src/main.rs && \
    echo "" > src/lib.rs && \
    sed -i '/^\[dev-dependencies\]/,/^\[/{ /ash-core/d }' Cargo.toml && \
    cargo build --release && \
    rm -rf src

# Copy source and build - remove cached ash-backend artifacts to force rebuild
COPY src ./src
RUN rm -rf target/release/.fingerprint/ash-backend-* \
           target/release/deps/ash_backend* \
           target/release/deps/libash_backend* \
           target/release/incremental/ash_backend* \
    && cargo build --release --bin ash-backend

# Verify binary exists and strip it (extra strip for good measure)
RUN strip /app/target/release/ash-backend

# -----------------------------------------------------------------------------
# Stage 4: Runtime - Minimal production image
# -----------------------------------------------------------------------------
FROM gcr.io/distroless/cc-debian12:nonroot AS runtime

# Labels for container metadata
LABEL org.opencontainers.image.title="ASH Backend"
LABEL org.opencontainers.image.description="Minimal untrusted message relay for ephemeral encrypted messaging"
LABEL org.opencontainers.image.source="https://github.com/monadial/ash"
LABEL org.opencontainers.image.licenses="MIT"

# Copy the compiled binary
COPY --from=builder --chown=nonroot:nonroot /app/target/release/ash-backend /ash-backend

# Expose the default port
EXPOSE 8080

# Set default environment variables
ENV BIND_ADDR=0.0.0.0
ENV PORT=8080
ENV RUST_LOG=ash_backend=info,tower_http=info

# Run as non-root user (distroless:nonroot UID=65532)
USER nonroot:nonroot

# Health check endpoint
# Note: distroless doesn't have curl, so we rely on orchestrator health checks
# For Kubernetes: use livenessProbe with httpGet to /health

# Run the binary
ENTRYPOINT ["/ash-backend"]
