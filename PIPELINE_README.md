# NATS Pipeline Implementation

A multi-stage NATS messaging pipeline for note processing with two-stage routing architecture:

**Stage 1 (messages.10.raw.type.*)**: Source-specific publishers publish raw notes
**Stage 2 (messages.20.*)**: Source-specific routers transform to standardized format
**Stage 3+ (messages.30.*)**: Type-specific parsers extract and structure data
**Stage N (Writers)**: Persist messages to disk organized by topic

## Architecture

```
Stage 1: Publishers          Stage 2: Routers (Type Detection)     Stage 3+: Parsers & Writers
───────────────────────────────────────────────────────────────────────────────────────────────

Google Keep Notes                  Google Router
(JSON files)                              ↓
     ↓                     ┌───────────────┼───────────────┐
[Publisher]                ↓               ↓               ↓
     ↓              messages.20    messages.20.hn    messages.20.time/training
messages.10.raw            ↓               ↓               ↓
type.googlenotes           ↓          [HN Parser]   [Time/Training Parsers]
     ↓                     ↓               ↓               ↓
     ├──────────────────────              ↓        messages.30.type.time
     │                                    ↓        messages.30.type.training
     │              [Apple Router]    messages.30
Apple Notes                 ↓        type.hn.10.parsed
(exported)                  ↓               ↓
     ↓                      ↓          [Writers]
[Publisher]                 ↓               ↓
     ↓                 messages.20    /tmp/nats/*
messages.10.raw            ↓
type.applenotes            ↓
                     [Writers]
                           ↓
                    /tmp/nats/*
```

## NATS Topics

### Stage 1: Raw Message Publishing (Source-Specific)
| Topic | Source | Description |
|-------|--------|-------------|
| `messages.10.raw.type.googlenotes` | Google Keep Publisher | Raw notes from Google Keep |
| `messages.10.raw.type.applenotes` | Apple Notes Publisher | Raw notes from Apple Notes |

### Stage 2: Standardized Format (After Routing)
| Topic | Router | Description |
|-------|--------|-------------|
| `messages.20.other.googlenotes` | Google Router | Standardized Google Keep notes |
| `messages.20.other.applenotes` | Apple Router | Standardized Apple Notes |
| `messages.20.hn` | Any Router, format is specific for Type=HN | HackerNews-detected notes |
| `messages.20.time` | Any Router, Format is specific for Type=Time | Time-detected notes |
| `messages.20.training` | Any Router, Format is specific for Type=Training | Training-detected notes |

### Stage 3+: Parsed/Processed Data (Type-Specific)
| Topic | Parser/Listener | Description |
|-------|-----------------|-------------|
| `messages.30.type.hn.10.parsed` | HackerNews Parser | Parsed HackerNews metadata (item ID, URL, links) |
| `messages.30.type.training.10.parsed` | Training Parser | Parsed workout sessions with exercises |
| `messages.30.type.time.10.parsed` | Time Parser | Time entries |
| `messages.30.type.next.10.parsed` | Next Entry Parser | Next task entries |

## Components

### Stage 1: Publishers (Source-Specific)

#### Google Keep Publisher
**File**: `google-keep-notes-parser/nats_publisher.py`

Reads JSON note files from a directory and publishes to `messages.10.raw.type.googlenotes`.

**Usage**:
```bash
cd google-keep-notes-parser
python nats_publisher.py --input-dir sample
```

**Message format**:
```json
{
  "id": "<uuid>",
  "note": { ... raw Google Keep note JSON ... },
  "date": "2026-01-15"
}
```

#### Apple Notes Publisher
**File**: `notes-exporter/nats_publisher.py`

Reads Apple Notes and publishes to `messages.10.raw.type.applenotes`.

**Message format**: Same as Google Keep format

---

### Stage 2: Routers (Standardization & Detection)

#### Google Notes Router
**File**: `notes-parser-router/googlenotes_router.py`

Subscribes to `messages.10.raw.type.googlenotes`, detects content type, routes to `messages.20.hn`, `messages.20.time`, `messages.20.training`, then the rest to  `messages.20.other.googlenotes`

**Usage**:
```bash
cd notes-parser-router
python googlenotes_router.py
```

#### Apple Notes Router
**File**: `notes-parser-router/applenotes_router.py`
Subscribes to `messages.10.raw.type.applenotes`, routes to `messages.20.hn`, `messages.20.time`, `messages.20.training`, then the rest to `messages.20.other.applenotes`.

---

### Stage 3: Parsers (Type-Specific Processing)

#### Training Parser
**File**: `training-parser-antlr4/nats_training_listener.py`

Subscribes to `messages.20.type.training`, parses with ANTLR4, publishes to `messages.30.type.training.10.parsed`.

---

### Stage N: Writers (Persistence)

#### HackerNews Writer
**File**: `google-keep-notes-parser/nats_hn_writer.py`

Subscribes to `messages.30.type.hn.10.parsed`, writes to `/tmp/nats/messages.30.type.hn.10.parsed/{N}.json`.

**Usage**:
```bash
cd google-keep-notes-parser
python nats_hn_writer.py
```

**Output**:
- Creates `/tmp/nats/messages.30.type.hn.10.parsed/` directory
- Sequential numbering: `1.json`, `2.json`, `3.json`, etc.
- Counter maintained in `.counter` file

#### Generic Writer
**File**: `nats_generic_writer.py` (root directory)

Writes any NATS topic to `/tmp/nats/$TOPIC/{N}.json`. Topic-agnostic.

**Usage**:
```bash
NATS_TOPIC=messages.20.other.googlenotes python nats_generic_writer.py
```

**Output**:
- Saves messages from any topic: `/tmp/nats/messages.20.other.googlenotes/1.json`, etc.
- Environment variable `NATS_TOPIC` specifies the subscription topic

#### Training Writer
**File**: `training-parser-antlr4/nats_writer.py`

Subscribes to `messages.30.type.training.10.parsed`, writes to `/tmp/nats/messages.30.type.training.10.parsed/{N}.json`.

#### Time Writer
**File**: `time-entry-notes-parser/nats/nats_writer.py`

Subscribes to `messages.30.type.time.10.parsed`, writes to `/tmp/nats/messages.30.type.time.10.parsed/{N}.json`.

#### Next Entry Writer
**File**: `notes-parser-next-entry/nats_writer.py`

Subscribes to `messages.30.type.next.10.parsed`, writes to `/tmp/nats/messages.30.type.next.10.parsed/{N}.json`.

## Quick Start

### Prerequisites
- NATS server running with mTLS (or plaintext for testing)
- Python 3.9+
- TLS certificates in `/tmp/nats-certs/` or configure `CERTS_DIR`

### Installation

**google-keep-notes-parser**:
```bash
cd google-keep-notes-parser
pip install -e .
```

**training-parser-antlr4**:
```bash
cd training-parser-antlr4
pip install -e .
```

**notes-exporter**:
```bash
cd notes-exporter
pip install -e .
```

### Run the Pipeline

**Terminal 1** — Start NATS (plaintext for testing):
```bash
docker run -p 4222:4222 nats:latest
```

**Terminal 2** — Start HackerNews Writer:
```bash
cd google-keep-notes-parser
python nats_hn_writer.py
```

**Terminal 3** — Start HackerNews Parser:
```bash
cd google-keep-notes-parser
python nats_hn_parser.py
```

**Terminal 4** — Start Google Notes Router:
```bash
cd google-keep-notes-parser
python nats_router.py
```

**Terminal 5** — Start Google Keep Publisher:
```bash
cd google-keep-notes-parser
python nats_publisher.py --input-dir sample/hn
```

### Verify

Check HackerNews output:
```bash
ls /tmp/nats/messages.30.type.hn.10.parsed/
cat /tmp/nats/messages.30.type.hn.10.parsed/1.json
```

You should see parsed HackerNews items with extracted item IDs and URLs.

## Environment Variables

- `NATS_URL` — NATS server URL (default: `nats://localhost:4222`)
- `CERTS_DIR` — TLS certificates directory (default: `/tmp/nats-certs`)
- `NATS_TOPIC` — For generic writer, the topic to subscribe to

**Examples**:
```bash
# Use custom NATS server
export NATS_URL=nats://nats.example.com:4222
python nats_router.py

# Use TLS with certificates
export CERTS_DIR=/etc/nats-certs
python nats_hn_parser.py

# Generic writer for Google Notes
export NATS_TOPIC=messages.20.other.googlenotes
python nats_generic_writer.py
```

## Writer Configuration

All writers follow the same output pattern: `/tmp/nats/$TOPIC/{N}.json`

### Topic-Specific Writers
- `nats_hn_writer.py` — hardcoded to `messages.30.type.hn.10.parsed`
- `nats_writer.py` (training) — hardcoded to `messages.30.type.training.10.parsed`

### Generic Writer
Use `nats_generic_writer.py` for any topic by setting `NATS_TOPIC`:
```bash
# Write Google Notes (messages.20.other.googlenotes)
NATS_TOPIC=messages.20.other.googlenotes python nats_generic_writer.py

# Write Apple Notes (messages.20.other.applenotes)
NATS_TOPIC=messages.20.other.applenotes python nats_generic_writer.py

# Write HackerNews (alternative to specific writer)
NATS_TOPIC=messages.30.type.hn.10.parsed python nats_generic_writer.py
```

### Output Structure
- **Directory**: `/tmp/nats/$TOPIC/`
- **Counter file**: `/tmp/nats/$TOPIC/.counter` (tracks next message number)
- **Message files**: `/tmp/nats/$TOPIC/1.json`, `/tmp/nats/$TOPIC/2.json`, etc.

Example after processing 3 HackerNews messages:
```
/tmp/nats/messages.30.type.hn.10.parsed/
├── .counter
├── 1.json
├── 2.json
└── 3.json
```

## Message Flow Examples

### Example 1: HackerNews Note Processing

1. **Publisher** reads `sample/hn/1.json` with HackerNews URL:
   ```json
   {
     "id": "bbbbbbbbbbb.dddddddddddddddd",
     "title": "Ask HN: How do you safely give LLMs SSHDB access",
     "text": "https://news.ycombinator.com/item?id=46620990",
     "labels": ["AI", "Download-HN"]
   }
   ```

2. **Publisher** publishes to `messages.10.raw.type.googlenotes`:
   ```json
   {
     "id": "c7fb647b-e37f-42b1-9a21-b3be2ab031e8",
     "note": { ... above JSON ... },
     "date": "2026-01-15"
   }
   ```

3. **Router** detects HackerNews (via label or URL pattern), publishes to `messages.20.hn`:
   ```json
   {
     "id": "c7fb647b-e37f-42b1-9a21-b3be2ab031e8",
     "message_type": "hackernews",
     "note": { ... },
     "source": "google-keep"
   }
   ```

4. **HackerNews Parser** extracts metadata, publishes to `messages.30.type.hn.10.parsed`:
   ```json
   {
     "id": "c7fb647b-e37f-42b1-9a21-b3be2ab031e8",
     "type": "hackernews",
     "parsed": {
       "item_id": "46620990",
       "url": "https://news.ycombinator.com/item?id=46620990",
       "title": "Ask HN: How do you safely give LLMs SSHDB access",
       "hn_links": [
         { "url": "https://news.ycombinator.com/item?id=46620990", "item_id": "46620990" }
       ]
     }
   }
   ```

5. **HackerNews Writer** persists to `/tmp/nats/messages.30.type.hn.10.parsed/1.json`

### Example 2: Training Note Processing

1. **Publisher** reads `sample/training/sample1.json`:
   ```json
   {
     "id": "aaaaaaaaaaa.bbbbbbbbbbbbbbbb",
     "title": "Training",
     "text": "☐ Bp\n  ☐ 2x30x13.6\n  ☐ 2x15x22.1\n..."
   }
   ```

2. **Router** detects training, publishes to `messages.20.type.training`

3. **Training Parser** parses with ANTLR4, extracts exercises, publishes to `messages.30.type.training.10.parsed`

4. **Writer** persists to `/tmp/nats/messages.30.type.training.10.parsed/1.json`:
   ```json
   {
     "workout_id": "w_<date>_000000",
     "date": "<date>",
     "exercises": [ ... ]
   }
   ```

## Debugging

### View NATS Messages

Use `nats-top` to monitor message flow:
```bash
docker run --rm -it natsio/nats-top -s nats://localhost:4222
```

### Check Logs

Run any component without `-d` flag to see console output:
```bash
python nats_router.py
# Shows: "✓ Routed to 'training' (messages.20.type.training): Training"
```

### Test Parser Only

To test the training parser without NATS:
```bash
cd training-parser-antlr4
python -c "
from src.data_access import SessionGrouper, ExerciseParser
text = '''2023-04-14
Deadlift: 5x6x80k'''
sessions = SessionGrouper.group_by_sessions(text.split('\\n'))
parser = ExerciseParser()
parsed = parser.parse_sessions(sessions)
print(parsed)
"
```

## Extending

### Add a New Parser Type

1. Create a new parser in `google-keep-notes-parser/parsers/my_parser.py`
2. Register it in `nats_router.py`:
   ```python
   from parsers.my_parser import MyParser
   registry.register(MyParser)
   PARSER_TO_TYPE[MyParser] = "my_type"
   TYPE_TO_TOPIC["my_type"] = "messages.20.type.my_type"
   ```
3. Create a new listener for the topic if needed

### Add Post-Processing

To add processing after training listener (e.g., database storage, API calls):
1. Create a new listener that subscribes to `messages.30.type.training.10.parsed`
2. Implement your processing logic
3. Optionally publish to a new topic

## Troubleshooting

### "Could not connect to NATS"
- Ensure NATS server is running: `docker run -p 4222:4222 nats:latest`
- Check `NATS_URL` environment variable: `echo $NATS_URL`

### "No JSON files found"
- Verify input directory exists: `ls sample/training/`
- Check file naming: must end in `.json`

### "No parser found for note"
- Note may not match any `can_parse()` criteria
- Check note content against parser patterns (e.g., training notes need exercise abbreviations like "Bp", "Dl")

### "Error parsing message"
- Check note text format for training notes (must follow ANTLR4 grammar)
- Review error message and traceback in console

## Architecture Decisions

1. **Async/Await**: All components use Python's async/await with `nats-py` for concurrent message handling
2. **No Error Recovery**: Messages that fail to parse are logged but not retried (fire-and-forget)
3. **Simple Serialization**: Each component publishes complete context in messages (no external state)
4. **Type Detection First**: Router uses `can_parse()` to detect types (no assumptions about message content)
5. **Separate Concerns**: Each step in the pipeline is a separate process (easier to develop, test, monitor)

## Implementation Status

### Completed
- [x] Two-stage routing architecture (messages.10.raw.type.* → messages.20.*)
- [x] HackerNews detection and parsing
- [x] Generic NATS writer for any topic
- [x] Simplified file naming: `/tmp/nats/$TOPIC/$N.json`
- [x] Apple Notes publisher with routing
- [x] HackerNews item ID extraction and link detection

### In Progress
- [ ] Training parser (ANTLR4-based)
- [ ] Time entry (Toggl) parser
- [ ] Next task parser

### Planned
- [ ] Message acknowledgments and retry logic
- [ ] Metrics/monitoring (message counts, latency)
- [ ] Dead-letter queue for failed messages
- [ ] Database persistence layer instead of file writes
- [ ] API endpoint to query parsed sessions
- [ ] Web UI to visualize pipeline
