FROM ubuntu:22.04

# Avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# 1. Install Git, Bash, Node.js 20 LTS, and required Linux graphics libraries for Chart.js Canvas
RUN apt-get update && apt-get install -y \
    git \
    bash \
    curl \
    ca-certificates \
    build-essential \
    libcairo2-dev \
    libpango1.0-dev \
    libjpeg-dev \
    libgif-dev \
    librsvg2-dev \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# ✅ Required for Windows + Docker volume mounts
RUN git config --system --add safe.directory /repo

# Tool directory
WORKDIR /tool

# 2. Pre-install NPM packages during the Docker build (CI/CD Speed Optimization!)
RUN npm init -y && \
    npm install chartjs-node-canvas chart.js @langchain/groq @langchain/core dotenv

# Copy script into the image
COPY analyze2.sh /tool/analyze2.sh
RUN chmod +x /tool/analyze2.sh

# 3. Add /tool to PATH and tell Node.js where to find the pre-installed modules
ENV PATH="/tool:${PATH}"
ENV NODE_PATH="/tool/node_modules"

# Default working directory (mounted repo)
WORKDIR /repo

# Entrypoint
ENTRYPOINT ["/tool/analyze2.sh"]