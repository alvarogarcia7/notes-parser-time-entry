#!/usr/bin/env python3
"""
Diagnostic test to understand NATS TLS behavior.
"""

import asyncio
import ssl
import sys

import nats


async def main():
    print("=" * 70)
    print("NATS TLS Configuration Diagnostic")
    print("=" * 70)

    # Test 1: Plain connection
    print("\n1. Attempting PLAIN connection to nats://docker:4222...")
    try:
        nc = await nats.connect("nats://docker:4222", connect_timeout=2)
        print(f"   ✓ Connected: {nc._client_id}")
        print(f"   Connection type: {type(nc._socket)}")
        print(f"   Is TLS: {isinstance(nc._socket, ssl.SSLSocket)}")
        await nc.close()
    except Exception as e:
        print(f"   ✗ Failed: {e}")

    # Test 2: TLS connection without cert
    print("\n2. Attempting TLS connection WITHOUT client cert...")
    try:
        ctx = ssl.create_default_context()
        nc = await nats.connect("tls://docker:4222", tls=ctx, connect_timeout=2)
        print(f"   ✓ Connected: {nc._client_id}")
        print(f"   Is TLS: {isinstance(nc._socket, ssl.SSLSocket)}")
        await nc.close()
    except Exception as e:
        print(f"   ✗ Failed: {type(e).__name__}: {str(e)[:100]}")

    # Test 3: TLS connection WITH cert
    print("\n3. Attempting TLS connection WITH client cert...")
    try:
        ctx = ssl.create_default_context()
        ctx.load_verify_locations(cafile="certs/rootCA.pem")
        ctx.load_cert_chain(certfile="certs/client.pem", keyfile="certs/client.key")
        nc = await nats.connect("tls://docker:4222", tls=ctx, connect_timeout=2)
        print(f"   ✓ Connected: {nc._client_id}")
        print(f"   Is TLS: {isinstance(nc._socket, ssl.SSLSocket)}")
        await nc.close()
    except Exception as e:
        print(f"   ✗ Failed: {e}")

    print("\n" + "=" * 70)
    print("Analysis:")
    print("=" * 70)
    print("""
If Test 1 succeeds: NATS is accepting PLAIN connections (TLS not enforced)
If Test 2 fails: Client cert is required (good, mutual TLS is enforced)
If Test 3 succeeds: Valid cert works (good)

Current behavior indicates the NATS server configuration may need adjustment.
Try these approaches:
1. Use a separate TLS-only port (e.g., 4443)
2. Disable the plain port entirely in nats-server.conf
3. Check NATS version for TLS enforcement options
""")


if __name__ == "__main__":
    asyncio.run(main())
