# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Development Commands

### Basic Build
```bash
export BUILD_WITHOUT_QUIC=true
rebar3 compile
```

### Enhanced Command Line Interface

BBSvx now provides **native clique integration** following the Riak pattern, eliminating the need for custom startup scripts. Configuration is managed through **cuttlefish** schemas and **clique** commands directly integrated with the release system.

#### Native Clique Integration (No Scripts Required!)
```bash
# Build the release first
export BUILD_WITHOUT_QUIC=true
rebar3 release

# Start the node
_build/default/rel/bbsvx/bin/bbsvx start

# Use bbsvx-admin for all configuration and management (like riak-admin)
_build/default/rel/bbsvx/bin/bbsvx-admin --help

# Configuration management (on running node)
_build/default/rel/bbsvx/bin/bbsvx-admin show
_build/default/rel/bbsvx/bin/bbsvx-admin show network.p2p_port  
_build/default/rel/bbsvx/bin/bbsvx-admin set network.p2p_port=3000
_build/default/rel/bbsvx/bin/bbsvx-admin set network.contact_nodes=node1@host1,node2@host2

# System status and management
_build/default/rel/bbsvx/bin/bbsvx-admin status
_build/default/rel/bbsvx/bin/bbsvx-admin status -v -j  # verbose + JSON

# Ontology management  
_build/default/rel/bbsvx/bin/bbsvx-admin ontology list
_build/default/rel/bbsvx/bin/bbsvx-admin ontology create my_namespace --type local
```

#### Startup Configuration
```bash
# Edit the configuration file directly
vim _build/default/rel/bbsvx/etc/bbsvx.conf

# Or use environment variables in deployment
export BBSVX_NODE_NAME="production@10.0.1.100"
export BBSVX_P2P_PORT=2305
_build/default/rel/bbsvx/bin/bbsvx start
```

#### Deployment Example  
```bash
# Production deployment with custom configuration
cat > production.conf << EOF
node.name = prod@10.0.1.100
node.cookie = production_secret
network.p2p_port = 2305
network.http_port = 8086
paths.data_dir = /var/lib/bbsvx
paths.log_dir = /var/log/bbsvx
network.contact_nodes = node1@10.0.1.101,node2@10.0.1.102
EOF

cp production.conf _build/default/rel/bbsvx/etc/bbsvx.conf
_build/default/rel/bbsvx/bin/bbsvx start

# Runtime configuration changes
_build/default/rel/bbsvx/bin/bbsvx-admin set network.contact_nodes=node1@10.0.1.101,node2@10.0.1.102,node3@10.0.1.103
```

#### Key Features
- **No Custom Scripts**: Direct integration with release system like Riak
- **Runtime Configuration**: Change settings without restart using clique  
- **Cuttlefish Integration**: Type-safe configuration with automatic validation
- **Standard OTP Release**: Follows Erlang/OTP best practices
- **Production Ready**: Environment variable support for containerized deployments

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

### Key Module Relationships
- **Application Flow**: `bbsvx_app` → `bbsvx_sup` → service processes
- **Ontology Operations**: `bbsvx_ont_service` ↔ `bbsvx_actor_ontology` ↔ `bbsvx_erlog_db_*`
- **Network Layer**: `bbsvx_network_service` ↔ `bbsvx_actor_spray` ↔ connection handlers
- **Transaction Flow**: HTTP API → `bbsvx_transaction_pipeline` → `bbsvx_actor_ontology`

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

## Important Notes

- Always set `BUILD_WITHOUT_QUIC=true` for compilation
- P2P network runs on port 2304 (configurable)
- HTTP API runs on port 8085
- Leader election is used for side effects in Prolog queries
- The system is designed for distributed deployment with contact nodes
- Proper OTP supervision trees ensure fault tolerance