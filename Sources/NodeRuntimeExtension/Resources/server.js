// Minimal placeholder entry point for the embedded Node runtime.
//
// This proves out the full pipeline end to end (App starts the
// packet-tunnel-provider extension -> extension calls node_start() with this
// file -> this file binds an HTTP server on loopback -> the app's WKWebView
// loads it) before the much larger job of getting code-server's actual
// server entry point (with its Express app, node-pty removed, and file
// system provider bridged to iOS) running in this same process.
//
// Port must match RuntimeConfig.loopbackPort in Sources/App/ContentView.swift.
const http = require('http');

const PORT = 8482;
const HOST = '127.0.0.1';

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(`<!doctype html>
<html>
  <head><meta charset="utf-8"><title>iPadVSCode</title></head>
  <body style="font-family: -apple-system, sans-serif; padding: 2rem;">
    <h1>Node runtime is alive</h1>
    <p>This is the placeholder server started by <code>node_start()</code>
       inside the packet-tunnel-provider extension. code-server's real
       server entry point (with its extension host, LSP, and the fixed set
       of built-in extensions) replaces this file next.</p>
    <p>Request: ${req.method} ${req.url}</p>
  </body>
</html>`);
});

server.listen(PORT, HOST, () => {
  console.log(`iPadVSCode node runtime listening on http://${HOST}:${PORT}/`);
});
