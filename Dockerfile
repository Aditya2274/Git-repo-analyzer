FROM ubuntu:22.04

# Avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    bash \
    python3 \
    python3-pip \
    python3-matplotlib \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ✅ Required for Windows + Docker volume mounts
RUN git config --system --add safe.directory /repo

# Tool directory
WORKDIR /tool
COPY analyze2.sh /tool/analyze2.sh
RUN chmod +x /tool/analyze2.sh

# Add /tool to PATH
ENV PATH="/tool:${PATH}"

# Default working directory (mounted repo)
WORKDIR /repo

# Entrypoint
ENTRYPOINT ["/tool/analyze2.sh"]
