# BBSvx 🫧
### *The Blockchain-Powered BubbleSoap System That Actually Makes Sense*

---

## What's a BubbleSoap System? 🤔

Forget everything you thought you knew about boring old Bulletin Board Systems. BBSvx stands for **BubbleSoap System** – a name that perfectly captures the essence of what we're building: a system where ideas, knowledge, and interactions bubble up naturally and spread across the network like soap bubbles in the wind.

Just like soap bubbles that form, merge, and carry information across space, BBSvx creates a distributed environment where knowledge ontologies bubble up from individual nodes and spread throughout the network, creating a shared understanding that's both resilient and beautiful to watch.

BBSvx is a blockchain-powered evolution of the classic [BubbleSoap System](https://github.com/netboz/bbs), built on Erlang/OTP for that rock-solid telecommunications-grade reliability that ensures your bubbles never pop unexpectedly.

---

## The "Distributed Bottle Emptying" Problem 🍺

Imagine an agent trying to empty a bottle. In traditional systems, there's usually only one rigid path to achieve this goal. But BBSvx's ontology system provides multiple action pathways:

```prolog
action(drink_bottle(Bottle), [cap_opened(Bottle)], empty(Bottle)).
action(wait(hour(1)), [cap_opened(Bottle), upside_down(Bottle)], empty(Bottle)).
```

Here we see two different ways to achieve the same goal (`empty(Bottle)`): either by drinking it (requiring an opened cap) or by waiting an hour with the bottle upside down and cap opened. The agent will:

1. Check if the goal `empty(Bottle)` is already achieved
2. If not, attempt to satisfy prerequisites like `cap_opened(Bottle)`
3. Execute the transition to reach the final state

This demonstrates how BBSvx's distributed ontologies enable flexible, intelligent problem-solving across the network. Knowledge about different action strategies bubbles up naturally and spreads through the SPRAY protocol, creating a shared understanding of multiple solution paths.

*This is the real power of BubbleSoap Systems: structured knowledge that flows naturally through distributed networks, enabling emergent intelligence.*

---

## What Makes BBSvx Special? ✨

### 🫧 **Bubbling Knowledge Ontologies**
Your knowledge doesn't stay trapped in silos. It bubbles up naturally and spreads across the network, creating shared understanding that persists even when individual nodes disappear.

### 🤖 **Soap-Film Agents**
Agents in BBSvx are like the thin soap film that gives bubbles their structure. They're lightweight but incredibly strong, managing ontologies and ensuring knowledge flows smoothly through the network.

### 🔄 **Bubble Dynamics**
Using the SPRAY protocol for overlay networks and EPTO for event ordering, we create natural bubble dynamics where knowledge merges, splits, and propagates organically – just like real soap bubbles, but with Byzantine fault tolerance.

### 🌈 **Blockchain Iridescence**
All the shimmering benefits of blockchain technology: enhanced security, transparency, and traceability. Plus the ability to track exactly how knowledge bubbles formed and evolved.

---

## Architecture: The BubbleSoap Factory 🏗️

BBSvx operates like a sophisticated bubble-making apparatus where each node generates and manages knowledge bubbles that interact with bubbles from other nodes. This creates a dynamic, self-organizing system powered by:

- **[SPRAY Protocol](https://hal.science/hal-01203363)**: Like air currents that carry bubbles, managing how nodes discover and interact with each other
- **[EPTO Protocol](https://www.dpss.inesc-id.pt/~mm/papers/2015/middleware_epto.pdf)**: Ensuring bubbles merge and split in a consistent order across the network
- **Leader Election**: Because even in bubble dynamics, surface tension needs coordination
- **Prolog Integration**: Using [Erlog](https://github.com/rvirding/erlog) to give our bubbles structured knowledge and reasoning capabilities

---

## Current Status 📊

**Alpha Release** - Like a bubble mixture that's just reached the perfect consistency:

- ✅ **SPRAY Network**: Bubbles are forming and spreading beautifully
- ✅ **EPTO Messaging**: Bubble interactions are consistently ordered
- ✅ **Leader Election**: Surface tension dynamics working perfectly
- ✅ **Blockchain Integration**: Knowledge bubbles are cryptographically secured
- ✅ **Smart Configuration**: No more command-line argument complexity
- 🚧 **Documentation**: You're reading the improved bubble manual right now!

---

## Configuration Made Simple 🛠️

Gone are the days of wrestling with complex command-line arguments. BBSvx now features intelligent configuration management that adapts like soap film to changing conditions.

### User-Friendly Config Files 📝

BBSvx automatically searches for config files in user-friendly locations:

1. **Environment variable**: `BBSVX_CONFIG_FILE=/path/to/config`
2. **User space**: `~/.bbsvx/bbsvx.conf` (recommended for development)
3. **Current directory**: `./bbsvx.conf`
4. **Release default**: `etc/bbsvx.conf` (production)

**Create your personal config with one command:**
```bash
# Initialize user config in ~/.bbsvx/bbsvx.conf
./bin/bbsvx config init

# Or specify a custom location
./bin/bbsvx config init --path ./my-bbsvx.conf

# Check where your config file is located
./bin/bbsvx config locate

# View current configuration
./bin/bbsvx show

# Set configuration values
./bin/bbsvx set boot=root
./bin/bbsvx set network.p2p_port=3000
```

**Quick config editing examples:**
```bash
# First time? Create the initial bubble (in your home directory)
echo "boot = root" >> ~/.bbsvx/bbsvx.conf
./bin/bbsvx start

# Joining an existing bubble cluster? Easy as soap
echo "boot = join existing.node.com 2304" >> ~/.bbsvx/bbsvx.conf  
./bin/bbsvx start

# Restarting? We're smart enough to detect existing bubble patterns
echo "boot = auto" >> ~/.bbsvx/bbsvx.conf
./bin/bbsvx start

# Using current directory config
echo "boot = root" >> ./bbsvx.conf
./bin/bbsvx start
```

**Environment variables work like bubble wands:**
```bash
# Override config file location
BBSVX_CONFIG_FILE=./my-config.conf ./bin/bbsvx start

# Quick parameter overrides
BBSVX_BOOT="root" ./bin/bbsvx start
BBSVX_P2P_PORT=3000 BBSVX_HTTP_PORT=9000 ./bin/bbsvx start
```

---

## Dependencies 📦

### System Requirements
- **Erlang/OTP**: 26.2 or higher (the bubble solution base)
- **Docker**: Latest version (for containerized bubble environments)
- **GNU Make**: For building the bubble apparatus
- **GCC**: The molecular compiler
- **Git**: For version control of bubble recipes

### Development Tools
- **libexpat**: 1.95+ (XML parsing for bubble metadata)
- **libyaml**: 0.1.4+ (YAML configuration for bubble parameters)
- **OpenSSL**: 1.0.0+ (cryptographic bubble integrity)
- **curl**: For testing bubble HTTP APIs

### Runtime Dependencies (Automatically Managed)
BBSvx orchestrates these excellent Erlang bubble-formation libraries:
- **Cowboy**: HTTP server framework (bubble communication protocol)
- **Gproc**: Process registry (bubble tracking system)
- **Cuttlefish**: Configuration management (bubble configuration schema)
- **OpenTelemetry**: Observability (bubble behavior analysis)
- **Prometheus**: Metrics collection (bubble dynamics measurement)
- **And many more...** (check `rebar.config` for the complete bubble recipe)

---

## Quick Start 🚀

### Option 1: Docker (Recommended for First Bubbles)

```bash
# Build the bubble-making image
docker build . -t bbsvx

# Start with one root bubble and one client bubble
docker compose up --scale bbsvx_client=1

# Feeling adventurous? Create a bubble storm!
docker compose up --scale bbsvx_client=5 -d
```

**Watch the bubble dance:** Visit [Grafana](http://localhost:3000) to see your distributed bubbles in action. The "Spray Monitoring" dashboard shows the beautiful bubble network topology in real-time.

### Option 2: Native Build (For Bubble Scientists)

```bash
# Set the magic bubble environment
export BUILD_WITHOUT_QUIC=true

# Mix the bubble solution
rebar3 compile
rebar3 release

# Create user-friendly config and blow your first bubble
_build/default/rel/bbsvx/bin/bbsvx config init
echo "boot = root" >> ~/.bbsvx/bbsvx.conf
_build/default/rel/bbsvx/bin/bbsvx start

# Or use current directory config
echo "boot = root" >> ./bbsvx.conf
_build/default/rel/bbsvx/bin/bbsvx start
```

### Option 3: Development Mode (Bubble Laboratory)

```bash
# For hot bubble reloading and experimentation
rebar3 shell
```

---

## Monitoring & Observability 📊

BBSvx comes with a complete bubble observation deck:

- **Grafana** (`:3000`): Beautiful bubble topology visualization
- **Prometheus** (`:9090`): Bubble metrics collection
- **Victoria Metrics** (`:8428`): Time-series bubble data
- **Loki** (`:3100`): Bubble event log aggregation
- **Dozzle** (`:9999`): Real-time bubble formation logs

---

## CLI Commands 💻

BBSvx provides a unified command interface for all operations:

```bash
# System status and information
./bin/bbsvx status                    # Basic status
./bin/bbsvx status --verbose         # Detailed status
./bin/bbsvx status --json            # JSON output

# Configuration management
./bin/bbsvx show                     # Show all configuration
./bin/bbsvx show boot                # Show specific config key
./bin/bbsvx set boot=root            # Set configuration value
./bin/bbsvx config init              # Initialize user config file
./bin/bbsvx config locate            # Show config file location

# Ontology management
./bin/bbsvx ontology list            # List ontologies
./bin/bbsvx ontology create myapp    # Create local ontology
./bin/bbsvx ontology create myapp --type shared  # Create shared ontology

# Testing and utilities
./bin/bbsvx test                     # Run system tests
```

## API Endpoints 🌐

Interact with your bubble network through HTTP APIs (default port 8085):

```bash
# Check bubble network status
curl http://localhost:8085/spray/nodes

# Examine knowledge bubbles
curl http://localhost:8085/ontologies/bbsvx:root

# Create new bubbles with transactions
curl -X POST http://localhost:8085/transaction \
  -H "Content-Type: application/json" \
  -d '{"namespace": "test", "data": "bubble_knowledge_here"}'
```

---

## Testing 🧪

```bash
# Test bubble integrity
rebar3 ct

# Format bubble code (because beautiful bubbles need beautiful code)
rebar3 erlfmt

# Bubble type checking (because even bubbles need structure)
rebar3 dialyzer
```

---

## Contributing 🤝

Found a bubble that won't pop properly? Have ideas for new bubble formations? Want to improve our bubble analogies? 

1. **Issues**: Report bubble anomalies with detailed reproduction steps
2. **Pull Requests**: Keep them focused like a perfect soap bubble
3. **Documentation**: More bubble science is always welcome
4. **Code Style**: Run `rebar3 erlfmt` to keep your code as smooth as soap film

---

## Architecture Deep Dive 🏗️

For those who want to understand the bubble physics:

- **Application Entry**: `bbsvx_app.erl` - The bubble machine startup
- **Ontology Management**: `bbsvx_ont_service.erl` - The bubble knowledge engine
- **Network Layer**: `bbsvx_actor_spray.erl` - Bubble distribution dynamics
- **Consensus**: `bbsvx_epto_service.erl` - Bubble interaction ordering
- **Blockchain**: `bbsvx_transaction_pipeline.erl` - Bubble transaction processing
- **Configuration**: `priv/bbsvx.schema` - Cuttlefish-powered bubble parameters

---

## The BubbleSoap Philosophy 🫧

BBSvx embodies the BubbleSoap philosophy: knowledge should flow naturally and beautifully through distributed systems, just like soap bubbles floating on air currents. Each bubble carries structured information, and when bubbles meet, they can merge their knowledge or split to explore new territories.

Unlike rigid systems that force information through predefined channels, BBSvx lets knowledge bubble up organically, creating emergent patterns of understanding that are both resilient and aesthetically pleasing to observe.

---

## Ontologies 🧠

Ontologies in BBSvx are knowledge repositories that help agents perform tasks within specific domains. They serve as the foundation for distributed reasoning and action coordination across the network.

### Namespace Structure

Ontologies follow a hierarchical namespace format:
```
bbsvx:subdomain1:subdomain2:...:subdomain_N
```

**Example namespaces:**
- `"bbsvx:agent"` - System ontology for agent management
- `"bbsvx:mts:client:mqtt"` - Message transport ontologies
- `"bbsvx:workflow:automation"` - Workflow management ontologies
- `"bbsvx:security:auth"` - Authentication and security ontologies

Each namespace creates an isolated knowledge domain that can be independently managed, versioned, and distributed across the network.

### Ontology Types

- **Shared Ontologies**: Distributed across the network, synchronized through SPRAY and EPTO protocols
- **Local Ontologies**: Node-specific knowledge that remains private
- **System Ontologies**: Core BBSvx functionality (like `bbsvx:root`)

---

## Actions 🎯

Actions in BBSvx follow a structured Prolog-based design pattern that enables flexible goal achievement and intelligent planning.

### Action Predicate Structure

Every action follows this pattern:
```prolog
action(Transition, [Prerequisites], FinalState).
```

**Components:**
- **Transition**: The action to be performed
- **Prerequisites**: List of conditions that must be satisfied before execution
- **FinalState**: The desired outcome after action completion

### Practical Example: Bottle Emptying Strategies

```prolog
% Direct approach - drink the bottle
action(drink_bottle(Bottle), [cap_opened(Bottle)], empty(Bottle)).

% Patient approach - wait for gravity
action(wait(hour(1)), [cap_opened(Bottle), upside_down(Bottle)], empty(Bottle)).

% Prerequisite actions
action(open_cap(Bottle), [has_bottle_opener], cap_opened(Bottle)).
action(turn_upside_down(Bottle), [], upside_down(Bottle)).
```

### Goal Resolution Process

When an agent receives a goal like `empty(bottle_1)`, the system:

1. **Goal Check**: Verify if `empty(bottle_1)` is already achieved
2. **Action Discovery**: Find all actions that result in `empty(Bottle)`
3. **Prerequisite Resolution**: Recursively satisfy prerequisites for chosen actions
4. **Execution**: Perform the transition and update the knowledge base
5. **Propagation**: Share the outcome across the distributed network

This approach enables emergent problem-solving where agents can discover multiple solution paths and share successful strategies across the bubble network.

---

## License 📄

This project is licensed under the Apache License 2.0 - see the LICENSE file for details.

---

## Final Words 🍻

BBSvx represents the evolution of distributed knowledge systems from rigid hierarchies to organic, bubble-like formations. It's like upgrading from industrial plumbing to a beautiful soap bubble display – same information flow, but now with natural beauty and emergent complexity.

Whether you're building distributed knowledge systems, experimenting with blockchain technology, or just fascinated by the parallels between soap bubble physics and distributed computing, BBSvx offers a unique perspective on how information can flow naturally through networks.

*Remember: In the BubbleSoap System, every node is both a bubble maker and a bubble observer. The beauty emerges from the interactions, not from central control.*

---

**Questions? Issues? Bubble formation tips?**  
Check out the issues tab or start a discussion. We're always excited to talk about distributed systems, blockchain technology, or the optimal surface tension for knowledge propagation in P2P networks.

Happy bubbling! 🫧✨