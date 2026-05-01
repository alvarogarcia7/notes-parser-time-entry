#!/usr/bin/env python3
"""
NATS Time Entry Writer
Subscribes to parsed time entry messages and writes them to disk
"""

import asyncio
import json
import os
import ssl
import sys
from pathlib import Path

import nats

NATS_URL = os.environ.get("NATS_URL", "tls://docker:4222")
CERTS_DIR = os.environ.get("CERTS_DIR", "/tmp/nats-certs")
INPUT_TOPIC = "messages.30.type.time.10.parsed"
OUTPUT_DIR = "/tmp/time-entries"


def _make_ssl_ctx() -> ssl.SSLContext:
    """Create SSL context with client certificate for mTLS."""
    ctx = ssl.create_default_context()
    ctx.load_verify_locations(cafile=f"{CERTS_DIR}/rootCA.pem")
    ctx.load_cert_chain(
        certfile=f"{CERTS_DIR}/client.pem",
        keyfile=f"{CERTS_DIR}/client.key"
    )
    return ctx


async def _connect_with_retry(url: str) -> nats.aio.client.Client:
    """Connect to NATS with retry logic and TLS."""
    ssl_ctx = _make_ssl_ctx()
    for attempt in range(5):
        try:
            return await nats.connect(url, tls=ssl_ctx, connect_timeout=2)
        except Exception as e:
            if attempt < 4:
                print(f"Connection attempt {attempt + 1}/5 failed, retrying in 1s...")
                await asyncio.sleep(1)
            else:
                print(f"Error: Could not connect to NATS at {url} after 5 attempts")
                print(f"Make sure NATS server is running: {e}")
                sys.exit(1)


async def main() -> None:
    """Subscribe to messages.30.type.time.10.parsed and write to disk."""
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    nc = await _connect_with_retry(NATS_URL)

    try:
        counter = 0
        print(f"✍️  Writer started, listening on '{INPUT_TOPIC}'...")
        print(f"💾 Writing to: {OUTPUT_DIR}")

        async def handler(msg):
            nonlocal counter
            try:
                envelope = json.loads(msg.data.decode())
                result = envelope.get("result", {})
                source_note_id = envelope.get("source_note_id", "unknown")

                output_file = Path(OUTPUT_DIR) / f"{counter}.json"
                with open(output_file, 'w') as f:
                    json.dump(result, f, indent=2)

                date_str = result.get("date", "unknown")
                entries_count = len(result.get("time_entries", []))
                print(f"✓ Wrote {output_file.name} ({entries_count} entries, date: {date_str}, note_id: {source_note_id})")
                counter += 1

            except Exception as e:
                print(f"✗ Error writing message: {e}")

        await nc.subscribe(INPUT_TOPIC, cb=handler)
        await asyncio.Future()  # run forever

    finally:
        await nc.close()


def main_sync() -> None:
    """Entry point for script execution."""
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n✓ Writer stopped")


if __name__ == "__main__":
    main_sync()
