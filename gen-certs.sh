#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$SCRIPT_DIR/certs"

echo "Generating TLS certificates in $CERTS_DIR..."
mkdir -p "$CERTS_DIR"
cd "$CERTS_DIR"

# Remove old certs if they exist
rm -f *.pem *.key *.csr *.srl 2>/dev/null || true

echo "Generating Root CA (ed25519)..."
openssl genpkey -algorithm ed25519 -out rootCA.key
openssl req -new -x509 -key rootCA.key -out rootCA.pem -days 3650 \
    -subj "/CN=NATS-Root-CA"

echo "Generating Server Certificate (ed25519)..."
openssl genpkey -algorithm ed25519 -out server.key
openssl req -new -key server.key -out server.csr -subj "/CN=nats-server"
openssl x509 -req -in server.csr \
    -CA rootCA.pem -CAkey rootCA.key -CAcreateserial \
    -out server.pem -days 365 \
    -extfile <(printf "subjectAltName=DNS:docker,DNS:localhost,DNS:nats-pipeline-test,IP:127.0.0.1")

echo "Generating Client Certificate (ed25519)..."
openssl genpkey -algorithm ed25519 -out client.key
openssl req -new -key client.key -out client.csr -subj "/CN=pipeline-client"
openssl x509 -req -in client.csr \
    -CA rootCA.pem -CAkey rootCA.key -CAcreateserial \
    -out client.pem -days 365

# Set proper permissions
chmod 600 *.key
chmod 644 *.pem

# Clean up CSR files
rm -f *.csr *.srl

echo "✓ Certificates generated successfully"
ls -lh "$CERTS_DIR"/*.pem "$CERTS_DIR"/*.key 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
