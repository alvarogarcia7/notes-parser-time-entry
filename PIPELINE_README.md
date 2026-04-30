# NATS Pipeline Implementation

A 4-step NATS messaging pipeline for Google Keep notes processing:

1. **Publisher** — reads Google Keep notes and publishes raw messages
2. **Router** — routes messages to type-specific topics
3. **Training Parser** — parses training notes with ANTLR4 and publishes sessions
4. **Writer** — writes parsed sessions to disk as JSON files

## Architecture

```
Google Keep Notes (JSON files)
         ↓
   [Publisher]
         ↓
   messages.10.raw  (raw notes from Google Keep)
         ↓
   [Router]
         ↓
    ┌────┴────┬──────────┬────────────┐
    ↓         ↓          ↓            ↓
 training   toggl      next          hn
    ↓
messages.20.type.training
         ↓
[Training Parser Listener]
         ↓
messages.30.type.training.10.parsed
         ↓
   [Writer]
         ↓
  /tmp/training/*.json (parsed workout sessions)
```

## NATS Topics

| Topic | Direction | Description |
|-------|-----------|-------------|
| `messages.10.raw` | Publisher → Router | Raw Google Keep notes (all types) |
| `messages.20.type.training` | Router → Training Listener | Training/workout notes |
| `messages.20.type.toggl` | Router → (future) | Time entry notes |
| `messages.20.type.next` | Router → (future) | Next task notes |
| `messages.20.type.hn` | Router → (future) | Hacker News notes |
| `messages.30.type.training.10.parsed` | Training Listener → Writer | Parsed workout sessions |

## Components

### Step 1: Publisher
**File**: `google-keep-notes-parser/nats_publisher.py`

Reads all JSON note files from a directory and publishes each to `messages.10.raw`.

**Usage**:
```bash
cd google-keep-notes-parser
python nats_publisher.py --input-dir sample
```

**Arguments**:
- `--input-dir` — directory containing JSON note files (default: `sample`)

**Message format**:
```json
{
  "id": "<uuid>",
  "note": { ... raw Google Keep note JSON ... }
}
```

### Step 2: Router
**File**: `google-keep-notes-parser/nats_router.py`

Subscribes to `messages.10.raw`, uses parsers to detect message type, routes to appropriate topic.

**Usage**:
```bash
cd google-keep-notes-parser
python nats_router.py
```

**Type Detection**:
- `TrainingParser` → `messages.20.type.training`
- `TimeEntryParser` → `messages.20.type.toggl`
- `NextParser` → `messages.20.type.next`
- `HackerNewsParser` → `messages.20.type.hn`
- `GenericNotesParser` → skipped (logged as unrecognized)

**Message format**:
```json
{
  "id": "<uuid>",
  "type": "training",
  "note": { ... raw Google Keep note JSON ... }
}
```

### Step 3: Training Parser Listener
**File**: `training-parser-antlr4/nats_training_listener.py`

Subscribes to `messages.20.type.training`, parses note text with ANTLR4, publishes parsed sessions.

**Usage**:
```bash
cd training-parser-antlr4
python nats_training_listener.py
```

**Parsing**:
- Uses `SessionGrouper.group_by_sessions()` to split text by training sessions
- Uses `ExerciseParser.parse_sessions()` to parse each session with ANTLR4 grammar
- Serializes exercises with `serialize_exercise()` from `parser.display`

**Message format**:
```json
{
  "id": "<uuid>",
  "source_note_id": "<original note id>",
  "session_index": 0,
  "workout": {
    "workout_id": "w_20230414_000000",
    "type": "set-centric",
    "date": "2023-04-14",
    "location": "",
    "notes": "# Stats: ...",
    "statistics": {},
    "exercises": [
      {
        "name": "Deadlift",
        "equipment": "other",
        "sets": [
          {
            "setNumber": 1,
            "repetitions": 6,
            "weight": { "amount": 80, "unit": "kg" }
          }
        ]
      }
    ]
  }
}
```

### Step 4: Writer
**File**: `training-parser-antlr4/nats_writer.py`

Subscribes to `messages.30.type.training.10.parsed`, writes each to `/tmp/training/<counter>.json`.

**Usage**:
```bash
cd training-parser-antlr4
python nats_writer.py
```

**Output**:
- Creates `/tmp/training/` directory if it doesn't exist
- Writes each parsed workout session to a numbered JSON file: `0.json`, `1.json`, etc.
- Each file contains the complete `workout` object from the message

## Quick Start

### Prerequisites
- NATS server running (Docker: `docker run -p 4222:4222 nats:latest`)
- Python 3.9+
- Dependencies installed in both repos

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

### Run the Pipeline

Terminal 1 - Start NATS:
```bash
docker run -p 4222:4222 nats:latest
```

Terminal 2 - Start writer (listens for output):
```bash
cd training-parser-antlr4
python nats_writer.py
```

Terminal 3 - Start training listener:
```bash
cd training-parser-antlr4
python nats_training_listener.py
```

Terminal 4 - Start router:
```bash
cd google-keep-notes-parser
python nats_router.py
```

Terminal 5 - Start publisher:
```bash
cd google-keep-notes-parser
python nats_publisher.py --input-dir sample
```

### Verify

Check the output:
```bash
ls /tmp/training/
cat /tmp/training/0.json
```

You should see parsed workout sessions as JSON files.

## Environment Variables

- `NATS_URL` — NATS server URL (default: `nats://localhost:4222`)

**Example**:
```bash
export NATS_URL=nats://nats.example.com:4222
python nats_router.py
```

## Message Flow Examples

### Example: Training Note Processing

1. **Publisher** reads `sample/training/sample1.json`:
   ```json
   {
     "id": "aaaaaaaaaaa.bbbbbbbbbbbbbbbb",
     "title": "Training",
     "text": "☐ Bp\n  ☐ 2x30x13.6\n  ☐ 2x15x22.1\n..."
   }
   ```

2. **Router** detects it as training (via `TrainingParser.can_parse()`), publishes to `messages.20.type.training`

3. **Training Listener** parses the text with ANTLR4:
   - Extracts date, exercises, sets, reps, weights
   - Creates structured workout object
   - Publishes to `messages.30.type.training.10.parsed`

4. **Writer** writes to `/tmp/training/0.json`:
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

## Future Enhancements

- [ ] Add persistence layer (database) instead of just file writes
- [ ] Add message acknowledgments and retry logic
- [ ] Add metrics/monitoring (message counts, latency)
- [ ] Add dead-letter queue for failed messages
- [ ] Support other note types (toggl, next, hn) with dedicated listeners
- [ ] Add API endpoint to query parsed sessions
- [ ] Add web UI to visualize pipeline
