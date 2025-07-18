const express = require('express');
const WebSocket = require('ws');
const cors = require('cors');
const app = express();
const port = 3400;

// Enable CORS for frontend to make requests to the server
app.use(cors());
app.use(express.json());

// In-memory data structure to store nodes and their edges
let nodes = {}; // Each key is a node_id, value is an object with metadata and edges

// Race condition protection for arc exchanges
let recentlyAddedEdges = new Map(); // Track edges added recently
const EDGE_PROTECTION_WINDOW_MS = 2000; // 2 second protection window

// WebSocket server for real-time updates
const wss = new WebSocket.Server({ noServer: true });

wss.on('connection', (ws) => {
  console.log('New WebSocket connection');
  console.log("Nodes:", nodes);

  // Construct the init message with nodes and edges
  const initMessage = {
    action: 'init',
    nodes: Object.entries(nodes).map(([nodeId, nodeData]) => ({
      id: nodeId,
      metadata: nodeData.metadata || {} // Include metadata
    })),
    edges: Object.entries(nodes).flatMap(([nodeId, nodeData]) =>
      Object.values(nodeData.edges || {}).map(edge => ({
        ulid: edge.ulid,
        from: nodeId,
        to: edge.to
      }))
    )
  };

  // Send the init message
  ws.send(JSON.stringify(initMessage));

  // Handle incoming messages
  ws.on('message', (message) => {
    console.log('Received:', message);
    const data = JSON.parse(message);

    if (data.action === 'add') {
      // Add edge to the corresponding node's edge list
      if (!nodes[data.from]) nodes[data.from] = { metadata: {}, edges: {} };
      nodes[data.from].edges[data.ulid] = { ulid: data.ulid, to: data.to };

      // Mark this edge as recently added to protect against race conditions
      markEdgeAsRecentlyAdded(data.ulid, data.from, data.to);

      // Broadcast the edge add to all clients
      broadcast({ action: 'add', ulid: data.ulid, from: data.from, to: data.to });
    } else if (data.action === 'remove') {
      // Check if this edge was recently added (arc exchange race condition protection)
      if (isEdgeRecentlyAdded(data.ulid, data.from)) {
        console.log(`Ignoring remove for recently added edge: ${data.ulid} from ${data.from}`);
        return; // Skip this remove event
      }

      // Remove edge from the corresponding node's edge list
      if (nodes[data.from] && nodes[data.from].edges[data.ulid]) {
        delete nodes[data.from].edges[data.ulid];

        // Broadcast the edge removal to all clients
        broadcast({ action: 'remove', ulid: data.ulid, from: data.from });
      }
    }
  });
});

// Broadcast function to send data to all WebSocket clients
function broadcast(message) {
  wss.clients.forEach((client) => {
    if (client.readyState === WebSocket.OPEN) {
      client.send(JSON.stringify(message));
    }
  });
}

// Helper functions for race condition protection
function markEdgeAsRecentlyAdded(ulid, from, to) {
  const key = `${ulid}-${from}-${to}`;
  recentlyAddedEdges.set(key, Date.now());
  console.log(`Protected edge: ${key} for ${EDGE_PROTECTION_WINDOW_MS}ms`);
  
  // Auto-cleanup after protection window
  setTimeout(() => {
    recentlyAddedEdges.delete(key);
    console.log(`Protection expired for edge: ${key}`);
  }, EDGE_PROTECTION_WINDOW_MS);
}

function isEdgeRecentlyAdded(ulid, from) {
  const now = Date.now();
  for (const [key, timestamp] of recentlyAddedEdges.entries()) {
    if (key.startsWith(`${ulid}-${from}-`) && (now - timestamp) < EDGE_PROTECTION_WINDOW_MS) {
      console.log(`Edge ${key} is protected (added ${now - timestamp}ms ago)`);
      return true;
    }
  }
  return false;
}

// Create a simple HTTP server to serve the frontend
const server = app.listen(port, () => {
  console.log(`Server listening at http://localhost:${port}`);
});

// Handle upgrade request for WebSocket
server.on('upgrade', (request, socket, head) => {
  wss.handleUpgrade(request, socket, head, (ws) => {
    wss.emit('connection', ws, request);
  });
});

// Serve static files (for the frontend)
app.use(express.static('public'));

// Endpoint to add or remove nodes
app.post('/nodes', (req, res) => {
  const { action, node_id, metadata } = req.body;

  if (!node_id) {
    return res.status(400).send({ message: 'node_id is required' });
  }

  if (action === 'add') {
    // If the node dosn't exist, create it
    if (!nodes[node_id]) {
      nodes[node_id] = { metadata, edges: {} };
      // Broadcast node addition
      broadcast({ action: 'node_add', node_id, metadata });
    } else {
      // If the node already exists, update its metadata
      nodes[node_id].metadata = metadata;
    }
    res.status(200).send({ message: 'Node added or updated' });
  } else if (action === 'remove') {
    if (nodes[node_id]) {
      // Remove the node and its edges
      delete nodes[node_id];
      // Broadcast node removal
      broadcast({ action: 'node_remove', node_id });
      res.status(200).send({ message: 'Node removed' });
    } else {
      res.status(404).send({ message: 'Node not found' });
    }
  } else {
    res.status(400).send({ message: 'Invalid action' });
  }
});

// Endpoint to add edges
app.post('/edges/add', (req, res) => {
  const { action, ulid, from, to } = req.body;

  if (action === 'add') {
    if (!nodes[from]) nodes[from] = { metadata: {}, edges: {} };
    nodes[from].edges[ulid] = { ulid, to };

    // Mark this edge as recently added to protect against race conditions
    markEdgeAsRecentlyAdded(ulid, from, to);

    // Broadcast edge addition to all WebSocket clients
    broadcast({ action: 'add', ulid, from, to });
    res.status(200).send({ message: 'Edge added' });
  } else {
    res.status(400).send({ message: 'Invalid action' });
  }
});

// Endpoint to remove edges
app.post('/edges/remove', (req, res) => {
  const { action, from, ulid } = req.body;

  if (action === 'remove') {
    // Check if this edge was recently added (arc exchange race condition protection)
    if (isEdgeRecentlyAdded(ulid, from)) {
      console.log(`HTTP: Ignoring remove for recently added edge: ${ulid} from ${from}`);
      res.status(200).send({ message: 'Edge remove ignored (recently added)' });
      return;
    }

    if (nodes[from] && nodes[from].edges[ulid]) {
      delete nodes[from].edges[ulid];

      // Broadcast edge removal to all WebSocket clients
      broadcast({ action: 'remove', ulid, from });
      res.status(200).send({ message: 'Edge removed' });
    } else {
      res.status(404).send({ message: 'Edge not found' });
    }
  } else {
    res.status(400).send({ message: 'Invalid action' });
  }
});
