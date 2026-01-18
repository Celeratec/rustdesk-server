# eRemote Server Dockerfile
# Multi-stage build: compiles Rust binaries, then creates minimal runtime image

# Stage 1: Build
FROM rust:1.82-bookworm AS builder

WORKDIR /build

# Install build dependencies
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    libsodium-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy source code
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY libs ./libs
COPY build.rs ./

# Create SQLite database with schema for sqlx compile-time verification
RUN apt-get update && apt-get install -y sqlite3 && rm -rf /var/lib/apt/lists/*
RUN sqlite3 /build/db_v2.sqlite3 " \
    CREATE TABLE IF NOT EXISTS peer ( \
        guid blob primary key not null, \
        id varchar(100) not null, \
        uuid blob not null, \
        pk blob not null, \
        created_at datetime not null default(current_timestamp), \
        user blob, \
        status tinyint, \
        note varchar(300), \
        info text not null \
    ) without rowid; \
    CREATE UNIQUE INDEX IF NOT EXISTS index_peer_id ON peer (id); \
    CREATE INDEX IF NOT EXISTS index_peer_user ON peer (user); \
    CREATE INDEX IF NOT EXISTS index_peer_created_at ON peer (created_at); \
    CREATE INDEX IF NOT EXISTS index_peer_status ON peer (status);"
ENV DATABASE_URL="sqlite:///build/db_v2.sqlite3"

# Build release binaries
RUN cargo build --release

# Stage 2: Runtime
FROM debian:bookworm-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    libsodium23 \
    && rm -rf /var/lib/apt/lists/*

# Copy binaries from builder
COPY --from=builder /build/target/release/hbbs /usr/bin/hbbs
COPY --from=builder /build/target/release/hbbr /usr/bin/hbbr
COPY --from=builder /build/target/release/eremote-utils /usr/bin/eremote-utils

# Set working directory for data
WORKDIR /data

# Expose ports
# 21115 - NAT type test
# 21116 - ID registration + heartbeat (TCP & UDP)
# 21117 - Relay
# 21118 - WebSocket for web client
# 21119 - WebSocket relay
EXPOSE 21115 21116 21116/udp 21117 21118 21119

# Default to hbbs, but can be overridden to run hbbr
CMD ["hbbs"]
