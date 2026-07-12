#!/usr/bin/env node

// Maintenance-only, dependency-free MCP fixture for the real-provider harness.
// It deliberately emits no diagnostics and drops credential-like environment
// variables before handling any request.

for (const name of Object.keys(process.env)) {
  if (/(?:API[_-]?KEY|TOKEN|SECRET|AUTHORIZATION)/i.test(name)) {
    delete process.env[name];
  }
}

process.stdin.setEncoding("utf8");

let pending = "";

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function error(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

function handle(message) {
  if (!message || message.jsonrpc !== "2.0" || typeof message.method !== "string") {
    if (message && Object.prototype.hasOwnProperty.call(message, "id")) {
      error(message.id, -32600, "invalid request");
    }
    return;
  }

  const hasId = Object.prototype.hasOwnProperty.call(message, "id");
  if (!hasId) return;

  switch (message.method) {
    case "initialize":
      send({
        jsonrpc: "2.0",
        id: message.id,
        result: {
          protocolVersion: message.params?.protocolVersion ?? "2025-03-26",
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "provider-compat-echo", version: "1.0.0" },
        },
      });
      return;

    case "ping":
      send({ jsonrpc: "2.0", id: message.id, result: {} });
      return;

    case "tools/list":
      send({
        jsonrpc: "2.0",
        id: message.id,
        result: {
          tools: [
            {
              name: "echo_nonce",
              description: "Return the supplied non-secret test nonce unchanged.",
              inputSchema: {
                type: "object",
                properties: { nonce: { type: "string", minLength: 1, maxLength: 200 } },
                required: ["nonce"],
                additionalProperties: false,
              },
            },
          ],
        },
      });
      return;

    case "tools/call": {
      if (message.params?.name !== "echo_nonce") {
        error(message.id, -32602, "unknown tool");
        return;
      }
      const nonce = message.params?.arguments?.nonce;
      if (typeof nonce !== "string" || nonce.length < 1 || nonce.length > 200) {
        error(message.id, -32602, "nonce must be a non-empty string of at most 200 characters");
        return;
      }
      send({
        jsonrpc: "2.0",
        id: message.id,
        result: {
          content: [{ type: "text", text: nonce }],
          structuredContent: { nonce },
          isError: false,
        },
      });
      return;
    }

    case "shutdown":
      send({ jsonrpc: "2.0", id: message.id, result: null });
      return;

    default:
      error(message.id, -32601, "method not found");
  }
}

process.stdin.on("data", (chunk) => {
  pending += chunk;
  while (true) {
    const newline = pending.indexOf("\n");
    if (newline < 0) break;
    const line = pending.slice(0, newline).trim();
    pending = pending.slice(newline + 1);
    if (!line) continue;
    try {
      handle(JSON.parse(line));
    } catch {
      // A parse error has no trustworthy JSON-RPC id. Stay silent on stderr.
    }
  }
});

process.stdin.on("end", () => process.exit(0));
