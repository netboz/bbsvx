#!/bin/bash

# BBSvx Clique-based Startup Script
# This script demonstrates proper integration with clique for unified configuration management

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
BIN_DIR="$ROOT_DIR/_build/default/rel/bbsvx/bin"
BBSVX_BIN="$BIN_DIR/bbsvx"

# Get public IP function
get_public_ip() {
    local ip
    
    # Try external IP service first
    if command -v curl >/dev/null 2>&1; then
        ip=$(curl -s --connect-timeout 3 "ipinfo.io/ip" 2>/dev/null | tr -d '\n\r ')
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return
        fi
    fi
    
    # Fallback to local IP detection
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return
        fi
    fi
    
    echo "127.0.0.1"
}

# Build configuration parameters from command line arguments and environment variables
build_config_args() {
    local config_args=()
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--node-name)
                config_args+=("node.name=$2")
                shift 2
                ;;
            -c|--cookie)
                config_args+=("node.cookie=$2")
                shift 2
                ;;
            -p|--p2p-port)
                config_args+=("network.p2p_port=$2")
                shift 2
                ;;
            -h|--http-port)
                config_args+=("network.http_port=$2")
                shift 2
                ;;
            --kb-path)
                config_args+=("paths.kb_path=$2")
                shift 2
                ;;
            --data-dir)
                config_args+=("paths.data_dir=$2")
                shift 2
                ;;
            --log-dir)
                config_args+=("paths.log_dir=$2")
                shift 2
                ;;
            --contact-nodes)
                config_args+=("network.contact_nodes=$2")
                shift 2
                ;;
            --boot)
                config_args+=("boot=$2")
                shift 2
                ;;
            --help)
                show_help
                exit 0
                ;;
            start|console|stop|restart|status|ping)
                # These are handled after configuration
                break
                ;;
            *)
                echo "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Add environment variable overrides
    [[ -n "$BBSVX_NODE_NAME" ]] && config_args+=("node.name=$BBSVX_NODE_NAME")
    [[ -n "$BBSVX_COOKIE" ]] && config_args+=("node.cookie=$BBSVX_COOKIE")
    [[ -n "$BBSVX_P2P_PORT" ]] && config_args+=("network.p2p_port=$BBSVX_P2P_PORT")
    [[ -n "$BBSVX_HTTP_PORT" ]] && config_args+=("network.http_port=$BBSVX_HTTP_PORT")
    
    # Set default node name with public IP if not specified
    local has_node_name=false
    for arg in "${config_args[@]}"; do
        if [[ "$arg" =~ ^node\.name= ]]; then
            has_node_name=true
            break
        fi
    done
    
    if [[ "$has_node_name" == "false" ]]; then
        public_ip=$(get_public_ip)
        config_args+=("node.name=bbsvx@$public_ip")
    fi
    
    printf '%s\n' "${config_args[@]}"
}

# Apply configuration using clique
apply_configuration() {
    local config_args=("$@")
    
    if [[ ${#config_args[@]} -gt 0 ]]; then
        echo "Applying configuration..."
        for config in "${config_args[@]}"; do
            echo "  Setting: $config"
            "$BBSVX_BIN" eval "clique:run([\"bbsvx\", \"config\", \"set\", \"$config\"])" 2>/dev/null || true
        done
        echo ""
    fi
}

# Execute command using clique
execute_clique_command() {
    local cmd="$1"
    shift
    
    case "$cmd" in
        status)
            "$BBSVX_BIN" eval "clique:run([\"bbsvx\", \"status\"])"
            ;;
        ontology)
            if [[ "$1" == "list" ]]; then
                "$BBSVX_BIN" eval "clique:run([\"bbsvx\", \"ontology\", \"list\"])"
            elif [[ "$1" == "create" && -n "$2" ]]; then
                "$BBSVX_BIN" eval "clique:run([\"bbsvx\", \"ontology\", \"create\", \"$2\"])"
            else
                echo "Usage: ontology list|create <name>"
                exit 1
            fi
            ;;
        config)
            if [[ "$1" == "show" ]]; then
                "$BBSVX_BIN" eval "clique:run([\"bbsvx\", \"config\", \"show\"])"
            elif [[ "$1" == "set" && -n "$2" ]]; then
                "$BBSVX_BIN" eval "clique:run([\"bbsvx\", \"config\", \"set\", \"$2\"])"
            else
                echo "Usage: config show|set <key=value>"
                exit 1
            fi
            ;;
        *)
            echo "Unknown clique command: $cmd"
            show_help
            exit 1
            ;;
    esac
}

show_help() {
    cat << EOF
BBSvx - Blockchain-powered BBS (Clique Integration)

Usage: $0 [OPTIONS] [COMMAND]

Configuration Options:
  -n, --node-name NODE        Set node name (auto-detects public IP)
  -c, --cookie COOKIE         Set Erlang cookie  
  -p, --p2p-port PORT         Set P2P port (default: 2304)
  -h, --http-port PORT        Set HTTP API port (default: 8085)
      --kb-path PATH          Set knowledge base path
      --data-dir DIR          Set data directory  
      --log-dir DIR           Set log directory
      --contact-nodes NODES   Comma-separated contact nodes
      --boot MODE             Set boot mode
      --help                  Show this help

Standard Commands:
  start                       Start the application
  console                     Start with interactive console
  stop                        Stop the running application
  restart                     Restart the application
  ping                        Ping the running node

Clique Commands:
  status                      Show system status via clique
  ontology list               List ontologies via clique
  ontology create NAME        Create ontology via clique
  config show                 Show all configuration via clique
  config set KEY=VALUE        Set configuration via clique

Environment Variables:
  BBSVX_NODE_NAME            Override node name
  BBSVX_COOKIE               Override cookie
  BBSVX_P2P_PORT             Override P2P port
  BBSVX_HTTP_PORT            Override HTTP port

Examples:
  # Start with custom configuration
  $0 --p2p-port 3000 --http-port 9000 start
  
  # Use clique for configuration
  $0 config set network.p2p_port=3000
  $0 config show
  
  # Runtime status and management
  $0 status
  $0 ontology list

EOF
}

# Main execution flow
main() {
    # Ensure release is built
    if [[ ! -f "$BBSVX_BIN" ]]; then
        echo "BBSvx release not found. Building..."
        cd "$ROOT_DIR"
        export BUILD_WITHOUT_QUIC=true
        rebar3 release
    fi
    
    # Parse arguments and build configuration
    config_args=($(build_config_args "$@"))
    
    # Find remaining command arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--node-name|--cookie|-c|-p|--p2p-port|-h|--http-port|--kb-path|--data-dir|--log-dir|--contact-nodes|--boot)
                shift 2  # Skip option and its value
                ;;
            start|console|stop|restart|ping)
                # Standard release commands
                command="$1"
                shift
                break
                ;;
            status|ontology|config)
                # Clique commands
                execute_clique_command "$@"
                exit $?
                ;;
            *)
                shift
                ;;
        esac
    done
    
    # Apply configuration if any was specified
    if [[ ${#config_args[@]} -gt 0 ]]; then
        apply_configuration "${config_args[@]}"
    fi
    
    # Execute standard release command
    command="${command:-start}"
    echo "Executing: $BBSVX_BIN $command"
    exec "$BBSVX_BIN" "$command"
}

# Run main function with all arguments
main "$@"