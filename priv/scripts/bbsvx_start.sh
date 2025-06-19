#!/bin/bash

# BBSvx Enhanced Startup Script with Command Line Argument Support
# This script demonstrates integration between command line arguments and cuttlefish configuration

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
BIN_DIR="$ROOT_DIR/_build/default/rel/bbsvx/bin"
CONFIG_DIR="$ROOT_DIR/_build/default/rel/bbsvx/etc"
BBSVX_BIN="$BIN_DIR/bbsvx"

# Get public IP function
get_public_ip() {
    # Try multiple methods to get public IP
    local ip
    
    # Method 1: Check for cloud metadata (AWS, GCP, etc.)
    if command -v curl >/dev/null 2>&1; then
        # AWS EC2
        ip=$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return
        fi
        
        # Try external IP services
        for service in "ipinfo.io/ip" "ifconfig.me" "icanhazip.com"; do
            ip=$(curl -s --connect-timeout 3 "$service" 2>/dev/null | tr -d '\n\r ')
            if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "$ip"
                return
            fi
        done
    fi
    
    # Method 2: Use hostname -I (Linux)
    if command -v hostname >/dev/null 2>&1; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$ip" != "127.0.0.1" ]]; then
            echo "$ip"
            return
        fi
    fi
    
    # Method 3: Use ip command
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return
        fi
    fi
    
    # Fallback to localhost
    echo "127.0.0.1"
}

# Default values
PUBLIC_IP=$(get_public_ip)
NODE_NAME="bbsvx@$PUBLIC_IP"
COOKIE="bbsvx"
P2P_PORT=2304
HTTP_PORT=8085
KB_PATH="."
DATA_DIR="./data"
LOG_DIR="./logs"
BOOT_MODE="root"
CONTACT_NODES=""
MODE="foreground"

# Help function
show_help() {
    cat << EOF
BBSvx - Blockchain-powered BBS

Usage: $0 [OPTIONS] [COMMAND]

Options:
  -n, --node-name NODE        Set node name (default: $NODE_NAME)
  -c, --cookie COOKIE         Set Erlang cookie (default: $COOKIE)
  -p, --p2p-port PORT         Set P2P port (default: $P2P_PORT)
  -h, --http-port PORT        Set HTTP API port (default: $HTTP_PORT)
  -k, --kb-path PATH          Set knowledge base path (default: $KB_PATH)
  -d, --data-dir DIR          Set data directory (default: $DATA_DIR)
  -l, --log-dir DIR           Set log directory (default: $LOG_DIR)
  -b, --boot MODE             Set boot mode (default: $BOOT_MODE)
  --contact-nodes NODES       Comma-separated list of contact nodes
  --daemon                    Run in daemon mode
  --help                      Show this help

Commands:
  start                       Start the application (default)
  console                     Start with interactive console
  stop                        Stop the running application
  restart                     Restart the application
  status                      Show application status
  ping                        Ping the running node

Examples:
  $0 --p2p-port 3000 --http-port 9000 console
  $0 --node-name mynode@192.168.1.100 --contact-nodes node1@host1,node2@host2
  $0 --daemon start

Environment Variables:
  BBSVX_NODE_NAME            Override node name
  BBSVX_COOKIE               Override cookie
  BBSVX_P2P_PORT             Override P2P port
  BBSVX_HTTP_PORT            Override HTTP port

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--node-name)
            NODE_NAME="$2"
            shift 2
            ;;
        -c|--cookie)
            COOKIE="$2"
            shift 2
            ;;
        -p|--p2p-port)
            P2P_PORT="$2"
            shift 2
            ;;
        -h|--http-port)
            HTTP_PORT="$2"
            shift 2
            ;;
        -k|--kb-path)
            KB_PATH="$2"
            shift 2
            ;;
        -d|--data-dir)
            DATA_DIR="$2"
            shift 2
            ;;
        -l|--log-dir)
            LOG_DIR="$2"
            shift 2
            ;;
        -b|--boot)
            BOOT_MODE="$2"
            shift 2
            ;;
        --contact-nodes)
            CONTACT_NODES="$2"
            shift 2
            ;;
        --daemon)
            MODE="daemon"
            shift
            ;;
        --help)
            show_help
            exit 0
            ;;
        start|console|stop|restart|status|ping)
            COMMAND="$1"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Override with environment variables if set
NODE_NAME="${BBSVX_NODE_NAME:-$NODE_NAME}"
COOKIE="${BBSVX_COOKIE:-$COOKIE}"
P2P_PORT="${BBSVX_P2P_PORT:-$P2P_PORT}"
HTTP_PORT="${BBSVX_HTTP_PORT:-$HTTP_PORT}"

# Set default command
COMMAND="${COMMAND:-start}"

# Create directories
mkdir -p "$DATA_DIR" "$LOG_DIR"

# Generate vars.config for the release overlay system
VARS_CONFIG="$ROOT_DIR/config/vars.config"
cat > "$VARS_CONFIG" << EOF
%% Erlang node longname
{node, "$NODE_NAME"}.

%% Erlang cookie  
{cookie, "$COOKIE"}.

%% Paths
{platform_data_dir, "$DATA_DIR"}.
{log_path, "$LOG_DIR"}.
{crash_dump, "{{platform_log_dir}}/erl_crash.dump"}.
EOF

# Generate dynamic configuration
CONFIG_FILE="$CONFIG_DIR/bbsvx.conf"

# Create the configuration file directly (don't rely on envsubst which might not be available)
cat > "$CONFIG_FILE" << EOF
## BBSvx Configuration File

## Node Configuration
node.name = $NODE_NAME
node.cookie = $COOKIE

## Network Configuration  
network.p2p_port = $P2P_PORT
network.http_port = $HTTP_PORT
network.contact_nodes = $CONTACT_NODES

## Paths
paths.kb_path = $KB_PATH  
paths.data_dir = $DATA_DIR
paths.log_dir = $LOG_DIR

## Boot Configuration
boot = $BOOT_MODE

## Prometheus Configuration
port = 10300
path = /metrics
format = auto

## OpenTelemetry Configuration  
span_processor = batch
traces_exporter = otlp
otlp_protocol = grpc
otlp_endpoint = http://tempo_collector:4317

## Logging
logger_level = info
EOF

# Rebuild the release with updated vars.config to get the correct vm.args
echo "Updating release configuration..."
cd "$ROOT_DIR"
export BUILD_WITHOUT_QUIC=true
rebar3 release >/dev/null 2>&1

echo "BBSvx Configuration:"
echo "  Node: $NODE_NAME"
echo "  Cookie: $COOKIE" 
echo "  P2P Port: $P2P_PORT"
echo "  HTTP Port: $HTTP_PORT"
echo "  KB Path: $KB_PATH"
echo "  Data Dir: $DATA_DIR"
echo "  Log Dir: $LOG_DIR"
echo "  Boot Mode: $BOOT_MODE"
if [[ -n "$CONTACT_NODES" ]]; then
    echo "  Contact Nodes: $CONTACT_NODES"
fi
echo ""

# Execute the appropriate command
case $COMMAND in
    start)
        if [[ "$MODE" == "daemon" ]]; then
            echo "Starting BBSvx in daemon mode..."
            "$BBSVX_BIN" daemon
        else
            echo "Starting BBSvx in foreground mode..."
            "$BBSVX_BIN" foreground
        fi
        ;;
    console)
        echo "Starting BBSvx with interactive console..."
        "$BBSVX_BIN" console
        ;;
    stop)
        echo "Stopping BBSvx..."
        "$BBSVX_BIN" stop
        ;;
    restart)
        echo "Restarting BBSvx..."
        "$BBSVX_BIN" restart
        ;;
    status)
        echo "BBSvx status:"
        "$BBSVX_BIN" eval "bbsvx_cli:command([\"bbsvx\", \"status\"])"
        ;;
    ping)
        echo "Pinging BBSvx node..."
        "$BBSVX_BIN" ping
        ;;
    *)
        echo "Unknown command: $COMMAND"
        show_help
        exit 1
        ;;
esac