#!/usr/bin/env python3
"""
Simple webhook receiver for testing Flux notifications.

Usage:
    python webhook-receiver.py [port]

Default port is 8080.
"""

import json
import sys
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler


class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        print("\n" + "=" * 60)
        print(f"📨 Webhook received at {datetime.now().isoformat()}")
        print(f"   Path: {self.path}")
        print("-" * 60)

        # Try to parse as JSON and pretty print
        try:
            data = json.loads(body)
            # Extract key fields for easy reading
            severity = data.get("severity", "unknown")
            involved_obj = data.get("involvedObject", {})
            kind = involved_obj.get("kind", "unknown")
            name = involved_obj.get("name", "unknown")
            namespace = involved_obj.get("namespace", "unknown")
            message = data.get("message", "")
            reason = data.get("reason", "")
            metadata = data.get("metadata", {})

            # Use emoji based on severity
            emoji = "❌" if severity == "error" else "✅" if severity == "info" else "❓"

            print(f"{emoji} Severity: {severity}")
            print(f"   Object:  {kind}/{namespace}/{name}")
            print(f"   Reason:  {reason}")
            print(f"   Message: {message}")

            if metadata:
                print(f"   Metadata:")
                for k, v in metadata.items():
                    print(f"      {k}: {v}")

            print("-" * 60)
            print("Raw JSON:")
            print(json.dumps(data, indent=2))
        except json.JSONDecodeError:
            print("Raw body (not JSON):")
            print(body.decode("utf-8", errors="replace"))

        print("=" * 60)

        # Send response
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status": "received"}')

    def do_GET(self):
        """Health check endpoint"""
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"Webhook receiver is running\n")

    def log_message(self, format, *args):
        """Suppress default logging"""
        pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080

    server = HTTPServer(("0.0.0.0", port), WebhookHandler)
    print(f"🚀 Webhook receiver listening on http://0.0.0.0:{port}")
    print(f"   Waiting for Flux notifications...")
    print(f"   Press Ctrl+C to stop\n")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n\n👋 Shutting down webhook receiver")
        server.shutdown()


if __name__ == "__main__":
    main()
