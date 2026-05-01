#!/usr/bin/env python3
"""
NATS Next Entry Listener
Subscribes to next entry messages, parses them, and publishes structured results
"""

import asyncio
import json
import os
import ssl
import sys
import uuid
from dataclasses import asdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent / "src"))

import nats
from next_parser import NextParser

NATS_URL = os.environ.get("NATS_URL", "tls://docker:4222")
CERTS_DIR = os.environ.get("CERTS_DIR", "/tmp/nats-certs")


def _make_ssl_ctx() -> ssl.SSLContext:
    """Create SSL context with client certificate for mTLS."""
    ctx = ssl.create_default_context()
    ctx.load_verify_locations(cafile=f"{CERTS_DIR}/rootCA.pem")
    ctx.load_cert_chain(
        certfile=f"{CERTS_DIR}/client.pem",
        keyfile=f"{CERTS_DIR}/client.key"
    )
    return ctx
INPUT_TOPIC = "messages.20.type.next"
OUTPUT_TOPIC = "messages.30.type.next.10.parsed"


async def parse_and_publish(message_data: dict, nc):
    """Parse next entry message and publish parsed result."""
    try:
        note = message_data.get("note", {})
        source_note_id = note.get("id", "unknown")
        note_title = note.get("title", "Untitled")
        note_text = note.get("text", "")

        if not note_text.strip():
            print(f"⚠ Note '{note_title}' has no text, skipping")
            return

        print(f"📖 Parsing: {note_title}")

        parser = NextParser()
        parse_result = parser.parse(note)
        result_dict = asdict(parse_result)

        envelope = {
            "id": str(uuid.uuid4()),
            "source_note_id": source_note_id,
            "result": result_dict
        }

        await nc.publish(OUTPUT_TOPIC, json.dumps(envelope).encode())
        print(f"✓ Parsed: {note_title} ({len(parse_result.projects)} project(s))")

    except Exception as e:
        print(f"✗ Error parsing message: {e}")


async def _connect_with_retry(url: str) -> nats.aio.client.Client:
    ssl_ctx = _make_ssl_ctx()
    for attempt in range(5):
        try:
            return await nats.connect(url, tls=ssl_ctx, connect_timeout=2)
        except Exception as e:
            if attempt < 4:
                print(f"Connection attempt {attempt + 1}/5 failed, retrying in 1s...")
                await asyncio.sleep(1)
            else:
                print(f"Error: Could not connect to NATS at {url} after 5 attempts: {e}")
                sys.exit(1)


async def main() -> None:
    nc = await _connect_with_retry(NATS_URL)

    try:
        print(f"🔄 Next listener started, listening on '{INPUT_TOPIC}'...")

        async def handler(msg):
            try:
                message_data = json.loads(msg.data.decode())
                await parse_and_publish(message_data, nc)
            except json.JSONDecodeError as e:
                print(f"✗ Failed to decode message: {e}")
            except Exception as e:
                print(f"✗ Error processing message: {e}")

        await nc.subscribe(INPUT_TOPIC, cb=handler)
        await asyncio.Future()

    finally:
        await nc.close()


def main_sync() -> None:
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n✓ Next listener stopped")


if __name__ == "__main__":
    main_sync()
