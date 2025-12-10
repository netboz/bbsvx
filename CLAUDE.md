# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Development Commands

### Basic Build
```bash
export BUILD_WITHOUT_QUIC=true
rebar3 compile
```

### Configuration Management
BBSvx supports intelligent configuration with automatic file location detection:
- `BBSVX_CONFIG_FILE=/path/to/config` - Environment variable override
- `~/.bbsvx/bbsvx.conf` - User space config (recommended for development)
- `./bbsvx.conf` - Current directory config
- `etc/bbsvx.conf` - Release default (production)

#### Smart Boot Modes
BBSvx provides intelligent boot mode detection to prevent data conflicts:

- **`boot = auto`** - Automatic detection (restarts only)
  - Detects existing data and restarts appropriately
  - Prevents accidental data loss on existing nodes
  - First-time starts require explicit intent (`root` or `join`)

- **`boot = root`** - Start new cluster (fresh data only)
  - Creates new cluster as root node
  - Prevents accidental overwrites of existing data
  - Validates no existing data directory

- **`boot = join <host> <port>`** - Join existing cluster
  - Connects to existing cluster at specified host/port
  - Default port is 2304 if not specified

Initialize user config: `./bin/bbsvx config init`

### Enhanced Command Line Interface

BBSvx provides enhanced command line interface following the Riak pattern, eliminating the need for custom startup scripts. Configuration is managed through **cuttlefish** schemas with commands directly integrated with the release system.

#### Simple Command Interface
BBSvx uses standard OTP release commands with environment variable configuration:

```bash
# Simple Environment Variable Startup
BBSVX_BOOT=root ./bin/bbsvx start                    # Start new cluster
BBSVX_BOOT="join 192.168.1.100 2304" ./bin/bbsvx start  # Join existing cluster
BBSVX_BOOT=auto ./bin/bbsvx start                    # Auto-detect mode

# Standard Node Operations
./bin/bbsvx start                    # Start with config file
./bin/bbsvx stop                     # Stop node
./bin/bbsvx console                  # Start with interactive console
./bin/bbsvx foreground               # Start in foreground mode
./bin/bbsvx ping                     # Check if node is responding

# Administration via bbsvx-admin
./bin/bbsvx-admin status             # Show system status
./bin/bbsvx-admin ping               # Ping the node
./bin/bbsvx-admin show               # Show configuration
./bin/bbsvx-admin show boot          # Show specific config key

# Build the release first
export BUILD_WITHOUT_QUIC=true
rebar3 release

# Start the node
_build/default/rel/bbsvx/bin/bbsvx start

# Configuration management (on running node)
_build/default/rel/bbsvx/bin/bbsvx rpc bbsvx_cli show
_build/default/rel/bbsvx/bin/bbsvx rpc bbsvx_cli show network.p2p_port  
_build/default/rel/bbsvx/bin/bbsvx rpc bbsvx_cli set network.p2p_port 3000
_build/default/rel/bbsvx/bin/bbsvx rpc bbsvx_cli set network.contact_nodes node1@host1,node2@host2

# System status and management
_build/default/rel/bbsvx/bin/bbsvx rpc bbsvx_cli status
_build/default/rel/bbsvx/bin/bbsvx rpc bbsvx_cli status verbose

# Ontology management  
_build/default/rel/bbsvx/bin/bbsvx rpc bbsvx_cli ontology list
_build/default/rel/bbsvx/bin/bbsvx rpc bbsvx_cli ontology create my_namespace
```

#### Startup Configuration
```bash
# Smart boot mode examples

# First time - start new cluster
echo "boot = root" >> _build/default/rel/bbsvx/etc/bbsvx.conf
_build/default/rel/bbsvx/bin/bbsvx start

# First time - join existing cluster  
echo "boot = join existing.node.com 2304" >> _build/default/rel/bbsvx/etc/bbsvx.conf
_build/default/rel/bbsvx/bin/bbsvx start

# Restart existing node - auto-detect
echo "boot = auto" >> _build/default/rel/bbsvx/etc/bbsvx.conf
_build/default/rel/bbsvx/bin/bbsvx start

# Environment variables for deployment
export BBSVX_NODE_NAME="production@10.0.1.100"
export BBSVX_P2P_PORT=2305
export BBSVX_BOOT="join cluster.internal 2304"
_build/default/rel/bbsvx/bin/bbsvx start
```

#### Deployment Example  
```bash
# Production deployment with smart boot detection
cat > production.conf << EOF
# Smart boot mode - auto-detect on restart, explicit join for first start
boot = join node1@10.0.1.101 2304

# Node configuration
nodename = prod@10.0.1.100
node.cookie = production_secret

# Network settings
network.p2p_port = 2305
network.http_port = 8086
network.contact_nodes = node1@10.0.1.101,node2@10.0.1.102

# Storage paths
paths.data_dir = /var/lib/bbsvx
paths.log_dir = /var/log/bbsvx
EOF

cp production.conf _build/default/rel/bbsvx/etc/bbsvx.conf
_build/default/rel/bbsvx/bin/bbsvx start

# Runtime configuration changes
_build/default/rel/bbsvx/bin/bbsvx rpc bbsvx_cli set network.contact_nodes node1@10.0.1.101,node2@10.0.1.102,node3@10.0.1.103
```

#### Key Features
- **Unified Command Interface**: Single `bbsvx` command for all operations via RPC
- **Smart Boot Detection**: Prevents data conflicts with intelligent boot modes
- **Runtime Configuration**: Live configuration changes without restart using RPC calls
- **Type-Safe Configuration**: Cuttlefish schema validation with helpful error messages
- **Standard OTP Release**: Follows Erlang/OTP best practices like Riak
- **Production Ready**: Environment variable support for containerized deployments
- **Data Protection**: Prevents accidental data loss through boot mode validation

### Testing
```bash
rebar3 ct                    # Run Common Test suites
rebar3 eunit                 # Run EUnit tests (if any)
```

### Release Management
```bash
rebar3 release               # Build release
rebar3 shell                 # Start development shell
```

### Code Quality
```bash
rebar3 dialyzer             # Type checking
rebar3 erlfmt               # Format code
rebar3 eqwalizer            # Additional type checking
```

### Docker Development
```bash
docker build . -t bbsvx
docker compose up  --scale bbsvx_client=1    # Run with 1 client
docker compose up  --scale bbsvx_client=N -d # Scale to N clients
```

## Architecture Overview

BBSvx is a blockchain-powered BBS (Bulletin Board System) built on Erlang/OTP with the following key components:

### Core Systems
- **P2P Network**: SPRAY protocol implementation for overlay network formation (`bbsvx_actor_spray.erl`)
- **Consensus**: EPTO protocol for consistent event ordering (`bbsvx_epto_service.erl`)
- **Ontology Management**: Prolog-based knowledge bases using Erlog (`bbsvx_actor_ontology.erl`, `bbsvx_ont_service.erl`)
- **Transaction Processing**: Blockchain-style transactions with validation pipeline (`bbsvx_transaction_pipeline.erl`)
- **HTTP API**: Cowboy-based REST API for external interactions (port 8085)

### HTTP API Endpoints

BBSvx provides the following REST API endpoints (default port: 8085):

#### Ontology Management
- **PUT /ontologies/:namespace** - Create or update an ontology
  - Body: `{"namespace": "my_ont", "type": "local|shared", "version": "0.0.1", "contact_nodes": [...]}`
  - Creates `local` (non-distributed) or `shared` (distributed with SPRAY/EPTO) ontologies
  - Returns: 201 (created) or 200 (already exists)

- **GET /ontologies/:namespace** - Retrieve ontology facts and rules as JSON
  - Returns: List of Prolog clauses and facts in JSON format

- **DELETE /ontologies/:namespace** - Delete an ontology
  - Returns: 204 (deleted) or 404 (not found)

- **PUT /ontologies/prove** - Execute a Prolog goal/query
  - Body: `{"namespace": "my_ont", "goal": "query_here"}`
  - Creates a transaction with the goal, broadcasts to network
  - Returns: `{"status": "accepted", "id": "ulid"}`

#### SPRAY Protocol Debugging
- **GET /spray/inview** - View incoming SPRAY connections
  - Body: `{"namespace": "my_ont"}`
  - Returns: Array of incoming arcs with source/target node details

- **GET /spray/outview** - View outgoing SPRAY connections
  - Body: `{"namespace": "my_ont"}`
  - Returns: Array of outgoing arcs with source/target node details

- **GET /spray/nodes** - SPRAY node information
  - Body: `{"namespace": "my_ont"}`
  - Returns: Node metadata

- **DELETE /spray/nodes** - Stop SPRAY agent for namespace
  - Body: `{"namespace": "my_ont"}`
  - Returns: `{"result": "ok"}`

#### Real-time Updates
- **WebSocket /websocket** - Real-time ontology change notifications
  - Sends initial ontology state on connection
  - Pushes transaction diffs as they occur
  - Auto-subscribes to `bbsvx:root` namespace

#### Static Files
- **/console/*** - Web console static files
  - Serves files from `priv/web_console/theme`

### Key Module Relationships
- **Application Flow**: `bbsvx_app` → `bbsvx_sup` → service processes
- **Ontology Operations**: `bbsvx_ont_service` ↔ `bbsvx_actor_ontology` ↔ `bbsvx_erlog_db_*`
- **Network Layer**: `bbsvx_network_service` ↔ `bbsvx_actor_spray` ↔ connection handlers
- **Transaction Flow**: HTTP API → `bbsvx_ont_service:prove/2` → creates transaction → `bbsvx_epto_service:broadcast/2` → `bbsvx_actor_ontology`

### Cowboy HTTP Handlers
- **bbsvx_cowboy_handler_ontology** - Ontology CRUD and Prolog query execution
- **bbsvx_cowboy_handler_spray** - SPRAY protocol debugging (inview/outview inspection)
- **bbsvx_cowboy_websocket_handler** - Real-time ontology updates via WebSocket
- **cowboy_static** - Static file serving for web console

### Database Layer
- **ETS-based storage**: `bbsvx_erlog_db_ets.erl` for Erlog facts and rules
- **Change tracking**: `bbsvx_erlog_db_differ.erl` for transaction diffs
- **Mnesia**: Used for distributed persistence

## Development Environment

### Configuration
- Main config: `config/sys.config.src`
- VM args: `config/vm.args`
- Cuttlefish config: `priv/bbsvx.schema`

### Testing Structure
- Common Test suites in `ct/bbsvx/` directory
- Integration tests using Robot Framework in `tests/integration/`
- Key test suites: ontology service, SPRAY protocol, database operations

### Monitoring and Observability
- **Prometheus metrics** for performance monitoring
- **OpenTelemetry** for distributed tracing
- **Grafana dashboards** for network visualization (accessible at http://localhost:3000)
- **Structured logging** with JSON format

### Dependencies
- **erlog**: Prolog implementation for knowledge representation
- **cowboy**: HTTP server framework
- **gproc**: Process registry for service discovery
- **riak_dt**: Distributed data types
- **jiffy**: JSON processing

## Recent Work and Improvements

### Protocol Performance (ASN.1 Implementation)
BBSvx now uses **ASN.1 encoding as the default protocol format** for superior performance:

- **Performance**: ASN.1 is 102x faster than Erlang term encoding (0.34 μs vs 34.5 μs per operation)
- **Size**: ASN.1 produces 2.4x smaller messages (90 bytes vs 118 bytes)
- **Interoperability**: Standardized format enables cross-language compatibility
- **Migration**: Automatic format detection maintains backward compatibility with term encoding

#### Protocol Codec Usage
```erlang
%% Default encoding (ASN.1)
{ok, Binary} = bbsvx_protocol_codec:encode(Message),
{ok, DecodedMessage} = bbsvx_protocol_codec:decode(Binary),

%% Explicit format selection
{ok, ASN1Binary} = bbsvx_protocol_codec:encode(Message, asn1),
{ok, TermBinary} = bbsvx_protocol_codec:encode(Message, term),

%% Auto-detection for migration
{ok, Message} = bbsvx_protocol_codec:decode(Binary, auto),
```

#### Benchmarking
Use `benchmark_test:run().` to compare encoding performance:
```bash
# In Erlang shell
rebar3 shell
> benchmark_test:run().
```

### SPRAY Protocol Stability Fixes
Fixed critical race conditions in arc exchange that caused "depleted views":

#### Issue Resolved
- **Problem**: Arc swapping sequence created isolation windows during exchanges
- **Root Cause**: `gproc:unreg_other()` → `gproc:reg()` gap where no process owned arc ULIDs
- **Impact**: `get_inview/1`/`get_outview/1` returned empty results, showing as depleted views in Grafana

#### Solution Implemented
Atomic arc swapping in `bbsvx_server_connection.erl` and `bbsvx_server_connection_asn1.erl`:
```erlang
%% Atomic arc swap: register new connection first, then unregister old
try
  gproc:reg({n, l, {arc, in/out, Ulid}}, NewLock)
catch
  error:{already_registered, {n, l, {arc, in/out, Ulid}}} ->
    gproc:unreg_other({n, l, {arc, in/out, Ulid}}, OtherConnectionPid),
    gproc:reg({n, l, {arc, in/out, Ulid}}, NewLock)
end
```

This ensures nodes maintain permanent arc connectivity during exchanges, preventing temporary isolation.

### Network Visualization (Graph Visualizer)
Integrated real-time network topology visualization:

- **Location**: `priv/graph-visualizer/` - Web-based vis.js visualization
- **Access**: http://localhost:3400 when running with Docker Compose
- **Features**: 
  - Real-time arc visualization with WebSocket updates
  - Right-click node inspection for inview/outview analysis
  - Race condition protection for accurate arc display
  - Docker Compose integration for development

### Monitoring and Observability Enhancements
Enhanced Grafana dashboards with additional SPRAY protocol metrics:

- **Total Connection Slopes**: Aggregated inview/outview connections across cluster
- **Arc Exchange Monitoring**: Real-time tracking of SPRAY protocol exchanges
- **Performance Metrics**: Protocol encoding/decoding performance tracking
- **Race Condition Detection**: Monitoring for depleted views and isolation events

## Important Notes

- Always set `BUILD_WITHOUT_QUIC=true` for compilation
- **Default Protocol**: ASN.1 encoding (102x faster, 2.4x smaller than term encoding)
- P2P network runs on port 2304 (configurable)
- HTTP API runs on port 8085
- Graph visualizer runs on port 3400 (Docker only)
- Leader election is used for side effects in Prolog queries
- The system is designed for distributed deployment with contact nodes
- Proper OTP supervision trees ensure fault tolerance
- **SPRAY Protocol**: Arc exchanges are now atomic to prevent isolation during swaps