# Time Entry Notes Parser - NATS Pipeline

Part of the larger NATS messaging pipeline for note processing. This module handles time entry detection, parsing, and persistence.

## Architecture

The time entry parser operates in **Stage 3** of the pipeline:

```
messages.20.time (Router → detected time entries)
         ↓
    [Time Parser]
         ↓
messages.30.type.time.10.parsed
         ↓
   [Time Writer]
         ↓
/tmp/nats/messages.30.type.time.10.parsed/{N}.json
```

## NATS Topics

### Input: Stage 2 (Routed Messages)
| Topic | Source | Description |
|-------|--------|-------------|
| `messages.20.time` | Source routers (Google Keep, Apple Notes) | Time-detected notes in standardized format |

### Output: Stage 3 (Parsed Data)
| Topic | Component | Description |
|-------|-----------|-------------|
| `messages.30.type.time.10.parsed` | Time Parser → Time Writer | Parsed time entries with structured data |

## Components

### Stage 3: Time Parser
**File**: `nats/nats_time_listener.py`

Subscribes to `messages.20.time`, parses using `TimeEntryParser`, publishes parsed results to `messages.30.type.time.10.parsed`.

**Input message format** (from router):
```json
{
  "id": "uuid",
  "message_type": "time",
  "note": {
    "id": "source_id",
    "title": "Time Entry",
    "text": "... time entry text ...",
    "date": "2026-05-04"
  },
  "source": "google-keep" or "apple-notes"
}
```

**Output message format**:
```json
{
  "id": "uuid",
  "source_note_id": "source_id",
  "result": {
    "date": "2026-05-04",
    "time_entries": [...]
  }
}
```

### Stage N: Time Writer
**File**: `nats/nats_writer.py`

Subscribes to `messages.30.type.time.10.parsed`, writes messages to `/tmp/nats/messages.30.type.time.10.parsed/{N}.json` with sequential numbering.

**Output structure**:
```
/tmp/nats/messages.30.type.time.10.parsed/
├── .counter (next message number)
├── 1.json
├── 2.json
└── 3.json
```

## Quick Start

### Prerequisites
- NATS server running (plaintext for testing, mTLS for production)
- Python 3.9+
- Time entry parser installed: `pip install -e .`

### Running Individual Components

**Start Time Parser** (Terminal 1):
```bash
cd time-entry-notes-parser
export NATS_URL=nats://localhost:4222  # or tls:// for production
python nats/nats_time_listener.py
```

**Start Time Writer** (Terminal 2):
```bash
export NATS_URL=nats://localhost:4222
python nats/nats_writer.py
```

**Publish a time entry** (Terminal 3):
```bash
cd google-keep-notes-parser
python nats_publisher.py --input-dir sample/time-entry
```

### Verify Output

```bash
ls /tmp/nats/messages.30.type.time.10.parsed/
cat /tmp/nats/messages.30.type.time.10.parsed/1.json
```

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `NATS_URL` | (required) | NATS server URL (e.g., `nats://localhost:4222` or `tls://docker:4222`) |
| `CERTS_DIR` | `/tmp/nats-certs` | Directory containing mTLS certificates (for `tls://` URLs) |

## Integration with Pipeline

This module is part of the larger pipeline:

1. **Publishers** (Google Keep, Apple Notes) → `messages.10.raw.type.*`
2. **Routers** (Google, Apple) detect types → `messages.20.time` (and others)
3. **Type-Specific Parsers** parse → `messages.30.type.time.10.parsed`
4. **Writers** persist → `/tmp/nats/$TOPIC/`

### Router Configuration

For the router to detect time entries, it must include a TimeEntryParser:

```python
from src.time_entry_parser import TimeEntryParser

# In router's type detection:
parser = TimeEntryParser()
if parser.can_parse(note):
    topic = "messages.20.time"
```

## File Structure

```
time-entry-notes-parser/
├── nats/
│   ├── nats_time_listener.py    # Parser (Stage 3)
│   └── nats_writer.py            # Writer (Stage N)
├── src/
│   ├── time_entry_parser.py      # Parsing logic
│   └── ...
├── PIPELINE_README.md            # This file
├── pyproject.toml
└── ...
```

## Troubleshooting

### "Could not connect to NATS"
- Ensure NATS server is running: `docker run -p 4222:4222 nats:latest`
- Check `NATS_URL`: `echo $NATS_URL`
- For mTLS, ensure certificates exist: `ls -la /tmp/nats-certs/`

### "No messages received"
- Verify messages are being published to `messages.20.time`
- Check router is running and detecting time entries
- Monitor with `nats-top`: `docker run --rm -it natsio/nats-top -s nats://localhost:4222`

### "Error parsing message"
- Verify note text matches TimeEntryParser pattern
- Check parser logic in `src/time_entry_parser.py`
- Test parser standalone: `python -c "from src.time_entry_parser import TimeEntryParser; ..."`

## Related Documentation

- **Main Pipeline**: See `/PIPELINE_README.md` for full architecture
- **Type Detection**: Time entries detected by checking note format/labels
- **Other Parsers**: Training (`training-parser-antlr4`), HackerNews (`google-keep-notes-parser`)
