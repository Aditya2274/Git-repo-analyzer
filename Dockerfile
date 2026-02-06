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
    maven \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# -------------------------------
# Create non-root user
# -------------------------------
ARG USER_ID=1000
ARG GROUP_ID=1000

RUN groupadd -g ${GROUP_ID} analyzer \
    && useradd -m -u ${USER_ID} -g analyzer analyzer

# Tool directory
WORKDIR /tool
COPY analyze2.sh /tool/analyze2.sh
RUN chmod +x /tool/analyze2.sh

# Add /tool to PATH
ENV PATH="/tool:${PATH}"

# Switch to non-root user
USER analyzer

# Default working directory (mounted repo)
WORKDIR /repo

# Entrypoint
ENTRYPOINT ["analyze2.sh"]
