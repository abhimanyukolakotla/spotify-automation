FROM debian:bookworm-slim

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    jq \
    python3 \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy scripts (credentials come in via env_file at runtime, not baked in)
COPY login.sh get_playlist.sh play_playlist.sh ./
RUN chmod +x login.sh get_playlist.sh play_playlist.sh

# Token cache directory — persisted via a named volume or bind mount at runtime
ENV TOKEN_CACHE_DIR=/app/.cache
RUN mkdir -p /app/.cache

EXPOSE 8765

ENTRYPOINT ["bash"]
CMD ["play_playlist.sh"]
