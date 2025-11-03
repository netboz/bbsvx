# Build stage
FROM erlang:27-alpine AS build

# Build the image used to build the release
RUN apk update && apk add --no-cache \
    openssl-dev \
    ncurses-libs \
    libstdc++ \
    git \
    build-base \
    bash \
    expat-dev \
    zlib-dev \
    libexpat \
    bsd-compat-headers \
    linux-headers \
    yaml-dev \
    erlang-dev \
    curl
WORKDIR /buildroot
RUN mkdir src include config priv log

COPY rebar.config ./rebar.config
COPY rebar.lock ./rebar.lock
ENV BUILD_WITHOUT_QUIC=true
RUN rebar3 compile

## Copy needed files and build the release
FROM build AS builded
# Set working directory
WORKDIR /buildroot
COPY src ./src
COPY include ./include
COPY config ./config
COPY priv ./priv
COPY asn1 ./asn1
COPY BBSVXProtocol.hrl ./BBSVXProtocol.hrl

# Build the release
ENV BUILD_WITHOUT_QUIC=true

RUN rebar3 compile && \
    rebar3 release

## Build the runtime image
FROM erlang:27-alpine AS run
RUN apk update && apk add --no-cache \
    openssl-dev \
    ncurses-libs \
    expat-dev \
    libstdc++ \
    bash \
    zlib-dev \
    libexpat \
    yaml-dev \
    erlang-dev \
    curl

## Copy the release from the build stage to the runtime image
FROM run

# Copy only the necessary files from the build stage
COPY --from=builded /buildroot/_build/default/rel/bbsvx /bbsvx

# Create startup script that uses cuttlefish configuration
COPY <<'EOF' /bbsvx/docker-start.sh
#!/bin/bash
set -e

# Detect container IP address for Docker environments
if [ ! -z "$DOCKER_COMPOSE" ]; then
    CONTAINER_IP=$(awk 'END{print $1}' /etc/hosts)
    echo "Detected Docker Compose IP: $CONTAINER_IP"
else
    CONTAINER_IP=${BBSVX_IP:-127.0.0.1}
fi

# Create configuration overrides for Docker environment
mkdir -p /bbsvx/etc/conf.d
CONFIG_OVERRIDES="/bbsvx/etc/conf.d/docker.conf"
echo "# Docker environment overrides" > "$CONFIG_OVERRIDES"

# Set node name based on detected IP - override environment variable with IP
if [ ! -z "$BBSVX_NODE_NAME" ]; then
    # Extract node part from environment variable and use detected IP
    NODE_PART=$(echo "$BBSVX_NODE_NAME" | cut -d'@' -f1)
    FINAL_NODE_NAME="${NODE_PART}@${CONTAINER_IP}"
else
    FINAL_NODE_NAME="bbsvx@${CONTAINER_IP}"
fi
echo "nodename = $FINAL_NODE_NAME" >> "$CONFIG_OVERRIDES"

# Set cookie
COOKIE=${BBSVX_COOKIE:-bbsvx}
echo "distributed_cookie = $COOKIE" >> "$CONFIG_OVERRIDES"

# Set ports if provided
if [ ! -z "$BBSVX_P2P_PORT" ]; then
    echo "network.p2p_port = $BBSVX_P2P_PORT" >> "$CONFIG_OVERRIDES"
fi

if [ ! -z "$BBSVX_HTTP_PORT" ]; then
    echo "network.http_port = $BBSVX_HTTP_PORT" >> "$CONFIG_OVERRIDES"
fi

# Set contact nodes if provided
if [ ! -z "$BBSVX_CONTACT_NODES" ]; then
    echo "network.contact_nodes = $BBSVX_CONTACT_NODES" >> "$CONFIG_OVERRIDES"
fi

# Set boot mode
BOOT_MODE=${BBSVX_BOOT:-root}
echo "boot = $BOOT_MODE" >> "$CONFIG_OVERRIDES"

echo "Docker configuration:"
echo "===================="
echo "Node Name: $FINAL_NODE_NAME (was: $BBSVX_NODE_NAME)"
echo "Cookie: $COOKIE"
echo "Container IP: $CONTAINER_IP"
echo "Boot Mode: $BOOT_MODE"
echo ""

# Support user-space config file locations
CONFIG_FILE="/bbsvx/etc/bbsvx.conf"

# Check for config file environment variable
if [ ! -z "$BBSVX_CONFIG_FILE" ] && [ -f "$BBSVX_CONFIG_FILE" ]; then
    CONFIG_FILE="$BBSVX_CONFIG_FILE"
    echo "Using config file from BBSVX_CONFIG_FILE: $CONFIG_FILE"
elif [ -f "/bbsvx/.bbsvx/bbsvx.conf" ]; then
    CONFIG_FILE="/bbsvx/.bbsvx/bbsvx.conf"
    echo "Using user config file: $CONFIG_FILE"
elif [ -f "/bbsvx/bbsvx.conf" ]; then
    CONFIG_FILE="/bbsvx/bbsvx.conf"
    echo "Using current directory config file: $CONFIG_FILE"
else
    echo "Using default config file: $CONFIG_FILE"
fi

# Debug: Show the config files before starting
echo "=== Main Config ==="
head -20 /bbsvx/etc/bbsvx.conf
echo "=== Docker Override ==="
cat /bbsvx/etc/conf.d/docker.conf
echo "==================="

# Start BBSvx using the native release script
exec /bbsvx/bin/bbsvx foreground
EOF

RUN chmod +x /bbsvx/docker-start.sh

# Expose relevant ports (configurable via environment)
EXPOSE 2304 8085

# Environment variables for configuration  
ENV BBSVX_NODE_NAME=""
ENV BBSVX_COOKIE="bbsvx"
ENV BBSVX_IP=""
ENV BBSVX_P2P_PORT=""
ENV BBSVX_HTTP_PORT=""
ENV BBSVX_CONTACT_NODES=""
ENV BBSVX_BOOT="root"

# Run the application using our Docker-aware startup script
CMD ["/bbsvx/docker-start.sh"]
