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
      handleEdgeAdd(data);
    } else if (data.action === 'remove') {
      handleEdgeRemove(data);
    } else if (data.action === 'swap') {
      handleEdgeSwap(data);
    }
  });
});

// Handle edge addition
function handleEdgeAdd(data) {
  const { ulid, from, to } = data;
  
  // Ensure source node exists
  if (!nodes[from]) {
    nodes[from] = { metadata: {}, edges: {} };
  }
  
  // Ensure target node exists
  if (!nodes[to]) {
    nodes[to] = { metadata: {}, edges: {} };
  }
  
  // Add the edge
  nodes[from].edges[ulid] = { ulid, to };
  
  console.log(`Edge added: ${ulid} from ${from} to ${to}`);
  
  // Broadcast the edge add to all clients
  broadcast({ action: 'add', ulid, from, to });
}

// Handle edge removal
function handleEdgeRemove(data) {
  const { ulid, from } = data;
  
  // Remove edge from the source node
  if (nodes[from] && nodes[from].edges[ulid]) {
    delete nodes[from].edges[ulid];
    console.log(`Edge removed: ${ulid} from ${from}`);
    
    // Broadcast the edge removal to all clients
    broadcast({ action: 'remove', ulid, from });
  } else {
    console.log(`Edge removal ignored: ${ulid} from ${from} (not found)`);
  }
}

// Handle edge swap - update the source node for an existing edge
function handleEdgeSwap(data) {
  const { ulid, previous_source, new_source, destination } = data;
  
  console.log(`Edge swap: ${ulid} from ${previous_source} to ${new_source}`);
  
  let edge = null;
  let targetNode = destination;
  
  // Try to find the edge in the previous source
  if (previous_source && nodes[previous_source] && nodes[previous_source].edges[ulid]) {
    edge = nodes[previous_source].edges[ulid];
    // Always use the destination from the event, not the stored edge.to
    delete nodes[previous_source].edges[ulid];
    console.log(`Found edge in expected previous source: ${previous_source}`);
  } else {
    // Edge might have been moved already or doesn't exist in expected location
    // Search for it in all nodes to handle race conditions
    let foundInNode = null;
    for (const [nodeId, nodeData] of Object.entries(nodes)) {
      if (nodeData.edges && nodeData.edges[ulid]) {
        edge = nodeData.edges[ulid];
        // Always use the destination from the event, not the stored edge.to
        delete nodeData.edges[ulid];
        foundInNode = nodeId;
        break;
      }
    }
    
    if (foundInNode) {
      console.log(`Found edge in different node: ${foundInNode} (expected: ${previous_source})`);
    } else {
      console.log(`Edge ${ulid} not found anywhere - creating new edge for swap`);
      // Create a new edge if we can't find it (use provided destination field)
      edge = { ulid, to: targetNode };
    }
  }
  
  // Ensure new source node exists
  if (!nodes[new_source]) {
    nodes[new_source] = { metadata: {}, edges: {} };
  }
  
  // Ensure target node exists
  if (!nodes[targetNode]) {
    nodes[targetNode] = { metadata: {}, edges: {} };
  }
  
  // Add the edge to the new source
  nodes[new_source].edges[ulid] = { ulid, to: targetNode };
  
  // Broadcast the swap to all clients
  broadcast({ 
    action: 'swap', 
    ulid, 
    previous_source, 
    new_source, 
    destination: targetNode,
    to: targetNode  // Keep for backward compatibility
  });
}

// Broadcast function to send data to all WebSocket clients
function broadcast(message) {
  wss.clients.forEach((client) => {
    if (client.readyState === WebSocket.OPEN) {
      client.send(JSON.stringify(message));
    }
  });
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
    // If the node doesn't exist, create it
    if (!nodes[node_id]) {
      nodes[node_id] = { metadata: metadata || {}, edges: {} };
      // Broadcast node addition
      broadcast({ action: 'node_add', node_id, metadata: metadata || {} });
    } else {
      // If the node already exists, update its metadata
      nodes[node_id].metadata = { ...nodes[node_id].metadata, ...metadata };
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
    handleEdgeAdd({ ulid, from, to });
    res.status(200).send({ message: 'Edge added' });
  } else {
    res.status(400).send({ message: 'Invalid action' });
  }
});

// Endpoint to remove edges
app.post('/edges/remove', (req, res) => {
  const { action, from, ulid } = req.body;

  if (action === 'remove') {
    handleEdgeRemove({ ulid, from });
    res.status(200).send({ message: 'Edge removed' });
  } else {
    res.status(400).send({ message: 'Invalid action' });
  }
});

// Endpoint to handle edge swaps
app.post('/edges/swap', (req, res) => {
  const { action, ulid, previous_source, new_source, destination } = req.body;

  if (action === 'swap') {
    handleEdgeSwap({ ulid, previous_source, new_source, destination });
    res.status(200).send({ message: 'Edge swapped' });
  } else {
    res.status(400).send({ message: 'Invalid action' });
  }
});