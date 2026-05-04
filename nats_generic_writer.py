#!/usr/bin/env python3
"""
Generic NATS Writer - saves messages from any topic to /tmp/nats/$TOPIC/$X.json

Usage:
    NATS_URL=tls://docker:4222 NATS_TOPIC=messages.20.googlenotes python3 nats_generic_writer.py
"""

import asyncio
import json
import os
import ssl
import sys
from pathlib import Path

import nats

NATS_URL = os.environ.get("NATS_URL")
NATS_TOPIC = os.environ.get("NATS_TOPIC")

if not NATS_URL:
    print("Error: NATS_URL environment variable not set")
    sys.exit(1)

if not NATS_TOPIC:
    print("Error: NATS_TOPIC environment variable not set")
    print("Example: NATS_TOPIC=messages.20.googlenotes")
    sys.exit(1)

CERTS_DIR = os.environ.get("CERTS_DIR", "/tmp/nats-certs")
OUTPUT_DIR = Path("/tmp/nats") / NATS_TOPIC
MESSAGE_COUNTER_FILE = OUTPUT_DIR / ".counter"


def _make_ssl_ctx() -> ssl.SSLContext:
    """Create SSL context with client certificate for mTLS."""
    ctx = ssl.create_default_context()
    ctx.load_verify_locations(cafile=f"{CERTS_DIR}/rootCA.pem")
    ctx.load_cert_chain(
        certfile=f"{CERTS_DIR}/client.pem",
        keyfile=f"{CERTS_DIR}/client.key"
    )
    return ctx


def _get_next_message_number() -> int:
    """Get the next message number from counter file."""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    try:
        if MESSAGE_COUNTER_FILE.exists():
            count = int(MESSAGE_COUNTER_FILE.read_text().strip())
        else:
            count = 0
        count += 1
        MESSAGE_COUNTER_FILE.write_text(str(count))
        return count
    except Exception as e:
        print(f"Warning: Could not read counter file: {e}")
        return 1


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


async def write_message(input_msg: dict) -> None:
    """Write message to file."""
    msg_num = _get_next_message_number()
    filename = f"{msg_num}.json"
    filepath = OUTPUT_DIR / filename

    try:
        with open(filepath, "w") as f:
            json.dump(input_msg, f, indent=2)

        print(f"✓ Saved message #{msg_num}")
        print(f"  File: {filepath}")
    except Exception as e:
        print(f"✗ Failed to write message to {filepath}: {e}")


async def main() -> None:
    """Subscribe to NATS topic and write messages to disk."""
    nc = await _connect_with_retry(NATS_URL)

    print(f"📝 Generic Writer started")
    print(f"  Input topic:  {NATS_TOPIC}")
    print(f"  Output dir:   {OUTPUT_DIR}")

    try:
        async def handler(msg):
            try:
                message_data = json.loads(msg.data.decode())
                await write_message(message_data)
            except json.JSONDecodeError as e:
                print(f"✗ Failed to decode message: {e}")
            except Exception as e:
                print(f"✗ Error processing message: {e}")

        await nc.subscribe(NATS_TOPIC, cb=handler)
        await asyncio.Future()  # run forever

    except KeyboardInterrupt:
        print("\n✓ Writer stopped")
    finally:
        await nc.close()


if __name__ == "__main__":
    asyncio.run(main())
