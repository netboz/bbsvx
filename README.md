# BBSvx

BBSvx is a blockchain-powered BBS (Bulletin Board System) built on Erlang/OTP with distributed consensus and knowledge management capabilities.

## Features

- **P2P Network**: SPRAY protocol implementation for overlay network formation
- **Consensus**: EPTO protocol for consistent event ordering
- **Ontology Management**: Prolog-based knowledge bases using Erlog
- **Transaction Processing**: Blockchain-style transactions with validation pipeline
- **HTTP API**: Cowboy-based REST API for external interactions
- **ASN.1 Protocol**: High-performance binary protocol (102x faster than term encoding)

## Quick Start

### Build

```bash
export BUILD_WITHOUT_QUIC=true
rebar3 compile
```

### Development

```bash
# Build release
rebar3 release

# Start development shell
rebar3 shell

# Run tests
rebar3 ct
```

### Release Management

```bash
# Build release
export BUILD_WITHOUT_QUIC=true
rebar3 release

# Start node
_build/default/rel/bbsvx/bin/bbsvx start

# Node operations
_build/default/rel/bbsvx/bin/bbsvx stop
_build/default/rel/bbsvx/bin/bbsvx console
_build/default/rel/bbsvx/bin/bbsvx ping
```

## Configuration

BBSvx supports intelligent configuration with automatic file location detection:

- `BBSVX_CONFIG_FILE=/path/to/config` - Environment variable override
- `~/.bbsvx/bbsvx.conf` - User space config (recommended for development)
- `./bbsvx.conf` - Current directory config
- `etc/bbsvx.conf` - Release default (production)

### Smart Boot Modes

- **`boot = auto`** - Automatic detection (restarts only)
- **`boot = root`** - Start new cluster (fresh data only)
- **`boot = join <host> <port>`** - Join existing cluster

### Configuration Examples

```bash
# Initialize user config
./bin/bbsvx config init

# Start new cluster
echo "boot = root" >> _build/default/rel/bbsvx/etc/bbsvx.conf
_build/default/rel/bbsvx/bin/bbsvx start

# Join existing cluster
echo "boot = join existing.node.com 2304" >> _build/default/rel/bbsvx/etc/bbsvx.conf
_build/default/rel/bbsvx/bin/bbsvx start

# Environment variables for deployment
export BBSVX_NODE_NAME="production@10.0.1.100"
export BBSVX_P2P_PORT=2305
export BBSVX_BOOT="join cluster.internal 2304"
_build/default/rel/bbsvx/bin/bbsvx start
```

## Runtime Management

```bash
# System status
_build/default/rel/bbsvx/bin/bbsvx rpc bbsvx_cli status
_build/default/rel/bbsvx/bin/bbsvx rpc bbsvx_cli status verbose

# Configuration management
_build/default/rel/bbsvx/bin/bbsvx rpc bbsvx_cli show
_build/default/rel/bbsvx/bin/bbsvx rpc bbsvx_cli show network.p2p_port
_build/default/rel/bbsvx/bin/bbsvx rpc bbsvx_cli set network.p2p_port 3000

# Ontology management
_build/default/rel/bbsvx/bin/bbsvx rpc bbsvx_cli ontology list
_build/default/rel/bbsvx/bin/bbsvx rpc bbsvx_cli ontology create my_namespace
```

## Docker Development

```bash
# Build image
docker build . -t bbsvx

# Run with scaling
docker compose up --scale bbsvx_client=1    # Run with 1 client
docker compose up --scale bbsvx_client=N -d # Scale to N clients
```

## Services

- **P2P Network**: Port 2304 (configurable)
- **HTTP API**: Port 8085
- **Graph Visualizer**: Port 3400 (Docker only) - http://localhost:3400
- **Grafana Dashboards**: Port 3000 - http://localhost:3000

## Code Quality

```bash
# Type checking
rebar3 dialyzer
rebar3 eqwalizer

# Format code
rebar3 erlfmt
```

## Architecture

BBSvx is built on a distributed architecture with the following key components:

- **Application Flow**: `bbsvx_app` → `bbsvx_sup` → service processes
- **Ontology Operations**: `bbsvx_ont_service` ↔ `bbsvx_actor_ontology` ↔ `bbsvx_erlog_db_*`
- **Network Layer**: `bbsvx_network_service` ↔ `bbsvx_actor_spray` ↔ connection handlers
- **Transaction Flow**: HTTP API → `bbsvx_transaction_pipeline` → `bbsvx_actor_ontology`

## Testing

```bash
# Run Common Test suites
rebar3 ct

# Run EUnit tests
rebar3 eunit
```

## Performance

BBSvx uses ASN.1 encoding as the default protocol format:

- **Performance**: 102x faster than Erlang term encoding
- **Size**: 2.4x smaller messages
- **Interoperability**: Standardized format for cross-language compatibility

## License

See LICENSE file for details.