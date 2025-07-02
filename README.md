# BBSvx

This project is under development and started as a proof of concept.

BBSvx is blockchain powered Virtual Reality engine.

Application logic is based on [BBS](https://github.com/netboz/bbs)

Integrating blockchain into BBS should permit to :

- Have permanent ontologies
- Have permanently running agents (agents being ontologies)
- Keep consistency of ontologies in distributed environments as agents are interacting with them
- Benefit from blockchain inherent characteristics: Enhanced security, transparency, traceability etc.

This blockchain is supported by a P2P overlay network formed by nodes following [SPRAY protocol](https://hal.science/hal-01203363). This permits to bring up a network where each peer only have a partial view of the whole network, named neighnours. Regularly, each node exchange a part of its neighbours with one of them.

Nodes are exchanging messages following [EPTO protocol](https://asc.di.fct.unl.pt/~jleitao/pdf/srds07-leitao.pdf). This permits to have a consistent ordering of events among the nodes.

To permit side effects to Prolog queries, a leader is elected among the nodes of an ontology.

## Introduction - Quick Start with Docker

This tutorial will get you up and running with BBSvx in minutes using Docker Compose, demonstrating the distributed P2P network formation and monitoring capabilities.

### Prerequisites

- Docker and Docker Compose installed
- Git (to clone the repository)

### Step 1: Build and Start the BBSvx Cluster

```bash
# Clone and enter the repository
git clone https://github.com/netboz/bbsvx.git
cd bbsvx

# Build the BBSvx Docker image
docker build . -t bbsvx

# Build the Graph Visualizer Docker image
docker build ./priv/graph-visualizer -t graph-visualizer

# Start BBSvx with 4 client nodes
docker compose up --scale bbsvx_client=4
```

This command starts:
- **1 BBSvx server node** (the root/seed node)
- **4 BBSvx client nodes** (joining the cluster)
- **Grafana** for monitoring dashboards
- **Graph Visualizer** for network topology visualization

### Step 2: Monitor Network Formation

Once the containers are running, you can monitor the P2P network formation:

#### Grafana Dashboard (SPRAY Protocol Monitoring)
Open http://localhost:3000 in your browser to access Grafana dashboards:

- **Username**: admin
- **Password**: admin (default)
- Navigate to the **BBSvx SPRAY Dashboard** to see:
  - Total connection slopes across the cluster
  - Arc exchange monitoring in real-time
  - Inview/outview connections per node
  - Network topology metrics

#### Graph Visualizer (Real-time Network Topology)
Open http://localhost:3400 in your browser to see:

- **Interactive network graph** showing all nodes and connections
- **Real-time updates** via WebSocket as nodes join/leave
- **Right-click any node** to inspect its inview/outview connections
- Visual representation of the SPRAY protocol overlay network

### Step 3: Scale the Network

Now let's scale up to 10 client nodes to observe how the SPRAY protocol adapts:

```bash
# Scale up to 10 client nodes (keep existing containers running)
docker compose up --scale bbsvx_client=10 -d
```

Watch the monitoring dashboards as:
1. **New nodes join** the network automatically
2. **SPRAY protocol exchanges** redistribute connections
3. **Network topology evolves** to maintain optimal connectivity
4. **Connection slopes adjust** to accommodate the larger network

### Step 4: Observe Network Behavior

In the **Graph Visualizer** (http://localhost:3400):
- Watch new nodes appear and connect to existing ones
- Observe how connections redistribute as the network grows
- Right-click nodes to see how inview/outview connections balance

In the **Grafana Dashboard** (http://localhost:3000):
- Monitor the "Total Connection Slopes" metric increasing
- Watch "Arc Exchange" activity as nodes negotiate connections
- Observe how the network maintains stability despite scaling

### Step 5: API Interaction

The HTTP API is available at http://localhost:8085:

```bash
# Check node status
curl http://localhost:8085/status

# Query ontology (if configured)
curl http://localhost:8085/ontology/list
```

### Step 6: Cleanup

```bash
# Stop all containers
docker compose down

# Remove volumes (optional, clears all data)
docker compose down -v
```


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

- **`boot = root`** - Start new cluster (fresh data only)
- **`boot = join <host> <port>`** - Join existing cluster
- **`boot = auto`** - Automatic detection (restarts only)

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