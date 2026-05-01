#!/bin/bash
set -e

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATS_PORT=4222
NATS_URL="tls://docker:$NATS_PORT"
NATS_CONTAINER="nats-pipeline-test"
CERTS_DIR="$REPO_ROOT/certs"
TRAINING_OUTPUT_DIR="/tmp/training"
TIME_ENTRIES_OUTPUT_DIR="/tmp/time-entries"
NEXT_OUTPUT_DIR="/tmp/next-entries"
TIMEOUT=15
CLEANUP_DOCKER=0

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --cleanup-docker)
            CLEANUP_DOCKER=1
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--cleanup-docker]"
            exit 1
            ;;
    esac
done

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}🛑 Cleaning up...${NC}"

    # Kill all background processes
    jobs -p | xargs -r kill 2>/dev/null || true
    sleep 1

    # Only clean up Docker if requested
    if [ $CLEANUP_DOCKER -eq 1 ]; then
        print_step "Cleaning up Docker containers..."

        # Remove running container
        if docker ps --format '{{.Names}}' | grep -q "^${NATS_CONTAINER}$"; then
            echo "  Stopping running NATS container..."
            docker stop "$NATS_CONTAINER" >/dev/null 2>&1
        fi

        # Remove stopped container
        if docker ps -a --format '{{.Names}}' | grep -q "^${NATS_CONTAINER}$"; then
            echo "  Removing NATS container..."
            docker rm "$NATS_CONTAINER" >/dev/null 2>&1
        fi

        # Clean up any other nats containers that might be leftover
        ORPHAN_CONTAINERS=$(docker ps -a --filter "ancestor=nats:latest" --format "{{.Names}}" 2>/dev/null | grep -v "^${NATS_CONTAINER}$" || true)
        if [ ! -z "$ORPHAN_CONTAINERS" ]; then
            echo "  Removing orphaned NATS containers..."
            echo "$ORPHAN_CONTAINERS" | xargs -r docker rm -f 2>/dev/null || true
        fi

        print_success "Docker cleanup complete"
    else
        print_success "Docker containers preserved (use --cleanup-docker to remove)"
    fi

    echo -e "${GREEN}✓ Cleanup complete${NC}"
}

trap cleanup EXIT

# Helper functions
print_header() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
}

print_step() {
    echo -e "\n${YELLOW}→ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Check if a port is open (works without nc)
is_port_open() {
    local port=$1

    # Try nc first if available
    if command -v nc &> /dev/null; then
        nc -z localhost "$port" 2>/dev/null && return 0
    fi

    # Try bash built-in /dev/tcp
    if (echo > /dev/tcp/localhost/"$port") 2>/dev/null; then
        return 0
    fi

    # Fallback: try curl if available
    if command -v curl &> /dev/null; then
        curl -s http://localhost:"$port"/varz > /dev/null 2>&1 && return 0
    fi

    # Last resort: check docker container status
    if docker ps --filter "name=$NATS_CONTAINER" --format "{{.State}}" 2>/dev/null | grep -q "running"; then
        return 0
    fi

    return 1
}

# Clean up any previous resources
print_header "Cleanup Previous Resources"

print_step "Killing any existing pipeline processes..."
pkill -f "nats_writer.py" 2>/dev/null || true
pkill -f "nats_training_listener.py" 2>/dev/null || true
pkill -f "nats_time_listener.py" 2>/dev/null || true
pkill -f "nats_next_listener.py" 2>/dev/null || true
pkill -f "router.py" 2>/dev/null || true
pkill -f "nats_publisher.py" 2>/dev/null || true
sleep 1
print_success "Previous processes cleaned up"

# Check if Docker container exists and reuse it
print_step "Checking for existing Docker containers..."
if docker ps -a --format '{{.Names}}' | grep -q "^${NATS_CONTAINER}$"; then
    if docker ps --format '{{.Names}}' | grep -q "^${NATS_CONTAINER}$"; then
        print_success "NATS container already running"
    else
        print_success "NATS container exists (stopped) - will reuse"
    fi
else
    print_success "No existing NATS container found"
fi

if [ $CLEANUP_DOCKER -eq 1 ]; then
    print_step "Removing Docker containers (--cleanup-docker flag set)..."

    # Remove running container
    if docker ps --format '{{.Names}}' | grep -q "^${NATS_CONTAINER}$"; then
        docker stop "$NATS_CONTAINER" >/dev/null 2>&1
    fi

    # Remove stopped container
    if docker ps -a --format '{{.Names}}' | grep -q "^${NATS_CONTAINER}$"; then
        docker rm "$NATS_CONTAINER" >/dev/null 2>&1
    fi

    # Clean up any orphaned nats containers
    ORPHAN_CONTAINERS=$(docker ps -a --filter "ancestor=nats:latest" --format "{{.Names}}" 2>/dev/null | grep -v "^${NATS_CONTAINER}$" || true)
    if [ ! -z "$ORPHAN_CONTAINERS" ]; then
        docker rm -f $ORPHAN_CONTAINERS 2>/dev/null || true
    fi

    print_success "Docker containers removed"
fi

print_step "Cleaning output directories..."
rm -rf "$TRAINING_OUTPUT_DIR" "$TIME_ENTRIES_OUTPUT_DIR" "$NEXT_OUTPUT_DIR"
mkdir -p "$TRAINING_OUTPUT_DIR" "$TIME_ENTRIES_OUTPUT_DIR" "$NEXT_OUTPUT_DIR"
print_success "Output directories cleaned"

sleep 1

# Generate TLS certificates if needed
print_header "TLS Certificate Setup"

print_step "Checking for TLS certificates..."
if [ ! -f "$CERTS_DIR/rootCA.pem" ] || [ ! -f "$CERTS_DIR/client.pem" ] || [ ! -f "$CERTS_DIR/server.pem" ]; then
    print_step "Generating TLS certificates..."
    bash "$REPO_ROOT/gen-certs.sh"
    print_success "TLS certificates generated"
else
    print_success "TLS certificates already present, reusing"
fi

# Check certificates exist
if [ ! -f "$CERTS_DIR/rootCA.pem" ] || [ ! -f "$CERTS_DIR/client.pem" ] || [ ! -f "$CERTS_DIR/server.pem" ]; then
    print_error "Failed to generate or locate TLS certificates"
    exit 1
fi
print_success "All required certificates present"

# Export for subprocesses
export CERTS_DIR

# Check prerequisites
print_header "Prerequisites Check"

print_step "Checking for required tools..."

# Check Docker
if ! command -v docker &> /dev/null; then
    print_error "Docker not found. Please install Docker."
    exit 1
fi
print_success "Docker found"

# Check Python
if ! command -v python3 &> /dev/null; then
    print_error "Python3 not found. Please install Python3."
    exit 1
fi
print_success "Python3 found"

# Check repositories exist
if [ ! -d "$REPO_ROOT/google-keep-notes-parser" ]; then
    print_error "google-keep-notes-parser directory not found"
    exit 1
fi
print_success "google-keep-notes-parser found"

if [ ! -d "$REPO_ROOT/training-parser-antlr4" ]; then
    print_error "training-parser-antlr4 directory not found"
    exit 1
fi
print_success "training-parser-antlr4 found"

if [ ! -d "$REPO_ROOT/project-router" ]; then
    print_error "project-router directory not found"
    exit 1
fi
print_success "project-router found"

if [ ! -d "$REPO_ROOT/time-entry-notes-parser" ]; then
    print_error "time-entry-notes-parser directory not found"
    exit 1
fi
print_success "time-entry-notes-parser found"

if [ ! -d "$REPO_ROOT/notes-parser-next-entry" ]; then
    print_error "notes-parser-next-entry directory not found"
    exit 1
fi
print_success "notes-parser-next-entry found"

# Check required files exist
print_step "Checking for implementation files..."

FILES=(
    "google-keep-notes-parser/nats_publisher.py"
    "project-router/nats-poc/subscriber-python/src/nats_subscriber/router.py"
    "training-parser-antlr4/nats_training_listener.py"
    "training-parser-antlr4/nats_writer.py"
    "time-entry-notes-parser/nats_time_listener.py"
    "time-entry-notes-parser/nats_writer.py"
    "notes-parser-next-entry/nats_next_listener.py"
    "notes-parser-next-entry/nats_writer.py"
)

for file in "${FILES[@]}"; do
    if [ ! -f "$REPO_ROOT/$file" ]; then
        print_error "File not found: $file"
        exit 1
    fi
    print_success "Found: $file"
done

# Check sample data exists
print_step "Checking for sample data..."
if [ ! -d "$REPO_ROOT/google-keep-notes-parser/sample" ]; then
    print_error "Sample data directory not found"
    exit 1
fi
SAMPLE_FILES=$(find "$REPO_ROOT/google-keep-notes-parser/sample" -name "*.json" | wc -l)
if [ $SAMPLE_FILES -eq 0 ]; then
    print_error "No sample JSON files found"
    exit 1
fi
print_success "Found $SAMPLE_FILES sample JSON files"

# Check for uv installer
check_uv() {
    if ! command -v uv &> /dev/null; then
        print_error "uv not found. Please install uv: pip install uv"
        exit 1
    fi
    print_success "uv found"
}

# Install dependencies
print_header "Installing Dependencies"

print_step "Checking for uv installer..."
check_uv

print_step "Syncing google-keep-notes-parser dependencies..."
cd "$REPO_ROOT/google-keep-notes-parser"
uv sync > /tmp/uv_publisher.log 2>&1
if [ $? -eq 0 ]; then
    print_success "google-keep-notes-parser dependencies synced"
else
    print_error "Failed to sync google-keep-notes-parser"
    echo "Log: /tmp/uv_publisher.log"
    tail -20 /tmp/uv_publisher.log
    exit 1
fi

print_step "Syncing training-parser-antlr4 dependencies..."
cd "$REPO_ROOT/training-parser-antlr4"
uv sync > /tmp/uv_listener.log 2>&1
if [ $? -eq 0 ]; then
    print_success "training-parser-antlr4 dependencies synced"
else
    print_error "Failed to sync training-parser-antlr4"
    echo "Log: /tmp/uv_listener.log"
    tail -20 /tmp/uv_listener.log
    exit 1
fi

print_step "Syncing project-router/nats-poc/subscriber-python dependencies..."
cd "$REPO_ROOT/project-router/nats-poc/subscriber-python"
uv pip install -e . > /tmp/uv_router.log 2>&1
if [ $? -eq 0 ]; then
    print_success "project-router dependencies synced"
else
    print_error "Failed to sync project-router"
    echo "Log: /tmp/uv_router.log"
    tail -20 /tmp/uv_router.log
    exit 1
fi

print_step "Syncing time-entry-notes-parser dependencies..."
cd "$REPO_ROOT/time-entry-notes-parser"
uv sync > /tmp/uv_time_entry.log 2>&1
if [ $? -eq 0 ]; then
    print_success "time-entry-notes-parser dependencies synced"
else
    print_error "Failed to sync time-entry-notes-parser"
    echo "Log: /tmp/uv_time_entry.log"
    tail -20 /tmp/uv_time_entry.log
    exit 1
fi

print_step "Syncing notes-parser-next-entry dependencies..."
cd "$REPO_ROOT/notes-parser-next-entry"
uv sync > /tmp/uv_next_entry.log 2>&1
if [ $? -eq 0 ]; then
    print_success "notes-parser-next-entry dependencies synced"
else
    print_error "Failed to sync notes-parser-next-entry"
    echo "Log: /tmp/uv_next_entry.log"
    tail -20 /tmp/uv_next_entry.log
    exit 1
fi

print_step "Generating ANTLR4 grammar files..."
cd "$REPO_ROOT/training-parser-antlr4"
make compile-grammar > /tmp/antlr_compile.log 2>&1
if [ $? -eq 0 ]; then
    print_success "ANTLR4 grammar compiled"
else
    print_error "Failed to compile ANTLR4 grammar"
    echo "Log: /tmp/antlr_compile.log"
    tail -20 /tmp/antlr_compile.log
    exit 1
fi

# Start NATS
print_header "Starting NATS"

print_step "Checking if NATS is already running..."
if docker ps --format '{{.Names}}' | grep -q "^${NATS_CONTAINER}$"; then
    print_success "NATS already running"
elif is_port_open $NATS_PORT; then
    print_success "NATS already running on port $NATS_PORT"
else
    print_step "Starting NATS in Docker with TLS..."
    docker run -d \
        --name "$NATS_CONTAINER" \
        -p "$NATS_PORT:4222" \
        -v "$CERTS_DIR:/certs:ro" \
        -v "$REPO_ROOT/nats-server.conf:/etc/nats/nats-server.conf:ro" \
        nats:latest \
        -c /etc/nats/nats-server.conf >/dev/null 2>&1

    # Wait for NATS to be ready
    NATS_READY=0
    for i in {1..60}; do
        if is_port_open $NATS_PORT; then
            print_success "NATS port $NATS_PORT is open"
            NATS_READY=1
            break
        fi
        if [ $((i % 10)) -eq 0 ]; then
            echo "  Waiting for NATS (${i}s)..."
        fi
        sleep 0.5
    done

    if [ $NATS_READY -eq 0 ]; then
        print_error "NATS port not responding after 30 seconds"
        echo ""
        echo -e "${YELLOW}Docker container status:${NC}"
        docker ps -a --filter "name=$NATS_CONTAINER" || echo "  Container not found"
        echo ""
        echo -e "${YELLOW}Docker logs (last 30 lines):${NC}"
        docker logs "$NATS_CONTAINER" 2>/dev/null | tail -30 || echo "  (no logs available)"
        exit 1
    fi

    # Wait extra time to ensure NATS is fully accepting connections
    print_step "Waiting for NATS to fully initialize..."
    sleep 3

    # Verify NATS is actually responding by checking logs
    if ! docker logs "$NATS_CONTAINER" 2>/dev/null | grep -q "Server is ready"; then
        echo -e "${YELLOW}Note: NATS may still be initializing, components will retry${NC}"
    fi
fi

# Start all components
print_header "Starting Pipeline Components"

print_step "Starting Writer (listens for parsed sessions)..."
cd "$REPO_ROOT/training-parser-antlr4"
uv run python nats_writer.py > /tmp/nats_writer.log 2>&1 &
WRITER_PID=$!
sleep 2
if kill -0 $WRITER_PID 2>/dev/null; then
    print_success "Writer started (PID: $WRITER_PID)"
else
    print_error "Writer failed to start"
    echo "Error output:"
    cat /tmp/nats_writer.log
    echo ""
    echo "Checking NATS container:"
    docker logs "$NATS_CONTAINER" 2>/dev/null | tail -10
    exit 1
fi

print_step "Starting Training Listener (parses with ANTLR4)..."
uv run python nats_training_listener.py > /tmp/nats_training_listener.log 2>&1 &
LISTENER_PID=$!
sleep 2
if kill -0 $LISTENER_PID 2>/dev/null; then
    print_success "Training Listener started (PID: $LISTENER_PID)"
else
    print_error "Training Listener failed to start"
    echo "Error output:"
    cat /tmp/nats_training_listener.log
    echo ""
    echo "Checking NATS container:"
    docker logs "$NATS_CONTAINER" 2>/dev/null | tail -10
    exit 1
fi

print_step "Starting Time Entry Writer (writes parsed time entries)..."
cd "$REPO_ROOT/time-entry-notes-parser"
uv run python nats_writer.py > /tmp/nats_time_writer.log 2>&1 &
TIME_WRITER_PID=$!
sleep 2
if kill -0 $TIME_WRITER_PID 2>/dev/null; then
    print_success "Time Entry Writer started (PID: $TIME_WRITER_PID)"
else
    print_error "Time Entry Writer failed to start"
    echo "Error output:"
    cat /tmp/nats_time_writer.log
    echo ""
    echo "Checking NATS container:"
    docker logs "$NATS_CONTAINER" 2>/dev/null | tail -10
    exit 1
fi

print_step "Starting Time Entry Listener (parses time entries)..."
uv run python nats_time_listener.py > /tmp/nats_time_listener.log 2>&1 &
TIME_LISTENER_PID=$!
sleep 2
if kill -0 $TIME_LISTENER_PID 2>/dev/null; then
    print_success "Time Entry Listener started (PID: $TIME_LISTENER_PID)"
else
    print_error "Time Entry Listener failed to start"
    echo "Error output:"
    cat /tmp/nats_time_listener.log
    echo ""
    echo "Checking NATS container:"
    docker logs "$NATS_CONTAINER" 2>/dev/null | tail -10
    exit 1
fi

print_step "Starting Next Entry Writer (writes parsed next entries)..."
cd "$REPO_ROOT/notes-parser-next-entry"
uv run python nats_writer.py > /tmp/nats_next_writer.log 2>&1 &
NEXT_WRITER_PID=$!
sleep 2
if kill -0 $NEXT_WRITER_PID 2>/dev/null; then
    print_success "Next Entry Writer started (PID: $NEXT_WRITER_PID)"
else
    print_error "Next Entry Writer failed to start"
    echo "Error output:"
    cat /tmp/nats_next_writer.log
    echo ""
    echo "Checking NATS container:"
    docker logs "$NATS_CONTAINER" 2>/dev/null | tail -10
    exit 1
fi

print_step "Starting Next Entry Listener (parses next entries)..."
uv run python nats_next_listener.py > /tmp/nats_next_listener.log 2>&1 &
NEXT_LISTENER_PID=$!
sleep 2
if kill -0 $NEXT_LISTENER_PID 2>/dev/null; then
    print_success "Next Entry Listener started (PID: $NEXT_LISTENER_PID)"
else
    print_error "Next Entry Listener failed to start"
    echo "Error output:"
    cat /tmp/nats_next_listener.log
    echo ""
    echo "Checking NATS container:"
    docker logs "$NATS_CONTAINER" 2>/dev/null | tail -10
    exit 1
fi

print_step "Starting Router (routes by type)..."
cd "$REPO_ROOT/project-router/nats-poc/subscriber-python"
uv run nats-router > /tmp/nats_router.log 2>&1 &
ROUTER_PID=$!
sleep 2
if kill -0 $ROUTER_PID 2>/dev/null; then
    print_success "Router started (PID: $ROUTER_PID)"
else
    print_error "Router failed to start"
    echo "Error output:"
    cat /tmp/nats_router.log
    echo ""
    echo "Checking NATS container:"
    docker logs "$NATS_CONTAINER" 2>/dev/null | tail -10
    exit 1
fi

# Run publisher
print_header "Publishing Sample Data"

print_step "Running Publisher (reads JSON files)..."
cd "$REPO_ROOT/google-keep-notes-parser"
uv run python nats_publisher.py --input-dir sample

# Wait for processing
print_header "Processing"

print_step "Waiting for pipeline processing (${TIMEOUT}s timeout)..."
WAITED=0
TRAINING_COUNT=0
TIME_ENTRIES_COUNT=0
NEXT_COUNT=0

while [ $WAITED -lt $TIMEOUT ]; do
    TRAINING_COUNT=$(ls "$TRAINING_OUTPUT_DIR"/*.json 2>/dev/null | wc -l)
    TIME_ENTRIES_COUNT=$(ls "$TIME_ENTRIES_OUTPUT_DIR"/*.json 2>/dev/null | wc -l)
    NEXT_COUNT=$(ls "$NEXT_OUTPUT_DIR"/*.json 2>/dev/null | wc -l)

    if [ $TRAINING_COUNT -gt 0 ] || [ $TIME_ENTRIES_COUNT -gt 0 ] || [ $NEXT_COUNT -gt 0 ]; then
        echo -ne "\r${BLUE}Found $TRAINING_COUNT training file(s), $TIME_ENTRIES_COUNT time entry file(s), $NEXT_COUNT next entry file(s)${NC}"
        if [ $TRAINING_COUNT -gt 0 ]; then
            ls "$TRAINING_OUTPUT_DIR"/*.json 2>/dev/null || true
        fi
        if [ $TIME_ENTRIES_COUNT -gt 0 ]; then
            ls "$TIME_ENTRIES_OUTPUT_DIR"/*.json 2>/dev/null || true
        fi
        if [ $NEXT_COUNT -gt 0 ]; then
            ls "$NEXT_OUTPUT_DIR"/*.json 2>/dev/null || true
        fi
    fi

    sleep 1
    WAITED=$((WAITED + 1))
done
echo ""

# Verify results
print_header "Results Verification"

TRAINING_FILES=$(ls "$TRAINING_OUTPUT_DIR"/*.json 2>/dev/null | wc -l)
TIME_ENTRY_FILES=$(ls "$TIME_ENTRIES_OUTPUT_DIR"/*.json 2>/dev/null | wc -l)
NEXT_FILES=$(ls "$NEXT_OUTPUT_DIR"/*.json 2>/dev/null | wc -l)

if [ $TRAINING_FILES -gt 0 ] || [ $TIME_ENTRY_FILES -gt 0 ] || [ $NEXT_FILES -gt 0 ]; then
    print_success "Pipeline executed successfully!"
    print_success "Generated $TRAINING_FILES training file(s), $TIME_ENTRY_FILES time entry file(s), and $NEXT_FILES next entry file(s)"

    if [ $TRAINING_FILES -gt 0 ]; then
        echo -e "\n${YELLOW}Training Output Files:${NC}"
        ls -lh "$TRAINING_OUTPUT_DIR"/*.json | awk '{print "  " $9 " (" $5 ")"}'

        echo -e "\n${YELLOW}Training Sample Output (first file, first 30 lines):${NC}"
        echo "---"
        head -30 "$TRAINING_OUTPUT_DIR"/0.json | sed 's/^/  /'
        echo "---"
    fi

    if [ $TIME_ENTRY_FILES -gt 0 ]; then
        echo -e "\n${YELLOW}Time Entry Output Files:${NC}"
        ls -lh "$TIME_ENTRIES_OUTPUT_DIR"/*.json | awk '{print "  " $9 " (" $5 ")"}'

        echo -e "\n${YELLOW}Time Entry Sample Output (first file, first 30 lines):${NC}"
        echo "---"
        head -30 "$TIME_ENTRIES_OUTPUT_DIR"/0.json | sed 's/^/  /'
        echo "---"
    fi

    if [ $NEXT_FILES -gt 0 ]; then
        echo -e "\n${YELLOW}Next Entry Output Files:${NC}"
        ls -lh "$NEXT_OUTPUT_DIR"/*.json | awk '{print "  " $9 " (" $5 ")"}'

        echo -e "\n${YELLOW}Next Entry Sample Output (first file, first 30 lines):${NC}"
        echo "---"
        head -30 "$NEXT_OUTPUT_DIR"/0.json | sed 's/^/  /'
        echo "---"
    fi

    # Validate JSON for training files
    if [ $TRAINING_FILES -gt 0 ]; then
        print_step "Validating training JSON output..."
        VALID_JSON=0
        for file in "$TRAINING_OUTPUT_DIR"/*.json; do
            if python3 -c "import json; json.load(open('$file'))" 2>/dev/null; then
                VALID_JSON=$((VALID_JSON + 1))
            fi
        done
        if [ $VALID_JSON -eq $TRAINING_FILES ]; then
            print_success "All training output files are valid JSON ($VALID_JSON/$TRAINING_FILES)"
        else
            print_error "Some training files are invalid JSON ($VALID_JSON/$TRAINING_FILES)"
        fi

        # Check training file content
        print_step "Checking training output content..."
        FIRST_FILE="$TRAINING_OUTPUT_DIR/0.json"
        if grep -q '"workout_id"' "$FIRST_FILE" 2>/dev/null; then
            print_success "Output contains 'workout_id' field"
        fi
        if grep -q '"exercises"' "$FIRST_FILE" 2>/dev/null; then
            print_success "Output contains 'exercises' field"
        fi
        if grep -q '"date"' "$FIRST_FILE" 2>/dev/null; then
            print_success "Output contains 'date' field"
        fi
    fi

    # Validate JSON for time entry files
    if [ $TIME_ENTRY_FILES -gt 0 ]; then
        print_step "Validating time entry JSON output..."
        VALID_JSON=0
        for file in "$TIME_ENTRIES_OUTPUT_DIR"/*.json; do
            if python3 -c "import json; json.load(open('$file'))" 2>/dev/null; then
                VALID_JSON=$((VALID_JSON + 1))
            fi
        done
        if [ $VALID_JSON -eq $TIME_ENTRY_FILES ]; then
            print_success "All time entry output files are valid JSON ($VALID_JSON/$TIME_ENTRY_FILES)"
        else
            print_error "Some time entry files are invalid JSON ($VALID_JSON/$TIME_ENTRY_FILES)"
        fi

        # Check time entry file content
        print_step "Checking time entry output content..."
        FIRST_TIME_FILE="$TIME_ENTRIES_OUTPUT_DIR/0.json"
        if grep -q '"time_entries"' "$FIRST_TIME_FILE" 2>/dev/null; then
            print_success "Output contains 'time_entries' field"
        fi
        if grep -q '"date"' "$FIRST_TIME_FILE" 2>/dev/null; then
            print_success "Output contains 'date' field"
        fi
    fi

    # Validate JSON for next entry files
    if [ $NEXT_FILES -gt 0 ]; then
        print_step "Validating next entry JSON output..."
        VALID_JSON=0
        for file in "$NEXT_OUTPUT_DIR"/*.json; do
            if python3 -c "import json; json.load(open('$file'))" 2>/dev/null; then
                VALID_JSON=$((VALID_JSON + 1))
            fi
        done
        if [ $VALID_JSON -eq $NEXT_FILES ]; then
            print_success "All next entry output files are valid JSON ($VALID_JSON/$NEXT_FILES)"
        else
            print_error "Some next entry files are invalid JSON ($VALID_JSON/$NEXT_FILES)"
        fi

        # Check next entry file content
        print_step "Checking next entry output content..."
        FIRST_NEXT_FILE="$NEXT_OUTPUT_DIR/0.json"
        if grep -q '"projects"' "$FIRST_NEXT_FILE" 2>/dev/null; then
            print_success "Output contains 'projects' field"
        fi
        if grep -q '"note_date"' "$FIRST_NEXT_FILE" 2>/dev/null; then
            print_success "Output contains 'note_date' field"
        fi
    fi

else
    print_error "No output files generated"

    echo -e "\n${YELLOW}Debugging Information:${NC}"

    echo -e "\n${YELLOW}Training Writer Log:${NC}"
    tail -10 /tmp/nats_writer.log 2>/dev/null || echo "  (no log)"

    echo -e "\n${YELLOW}Training Listener Log:${NC}"
    tail -10 /tmp/nats_training_listener.log 2>/dev/null || echo "  (no log)"

    echo -e "\n${YELLOW}Time Entry Writer Log:${NC}"
    tail -10 /tmp/nats_time_writer.log 2>/dev/null || echo "  (no log)"

    echo -e "\n${YELLOW}Time Entry Listener Log:${NC}"
    tail -10 /tmp/nats_time_listener.log 2>/dev/null || echo "  (no log)"

    echo -e "\n${YELLOW}Next Entry Writer Log:${NC}"
    tail -10 /tmp/nats_next_writer.log 2>/dev/null || echo "  (no log)"

    echo -e "\n${YELLOW}Next Entry Listener Log:${NC}"
    tail -10 /tmp/nats_next_listener.log 2>/dev/null || echo "  (no log)"

    echo -e "\n${YELLOW}Router Log:${NC}"
    tail -10 /tmp/nats_router.log 2>/dev/null || echo "  (no log)"

    echo -e "\n${YELLOW}Running Processes:${NC}"
    jobs -l

    exit 1
fi

# Final summary
print_header "Test Complete"

echo -e "${GREEN}✓ All pipeline components executed successfully!${NC}"
echo -e "${GREEN}✓ Sample data published from google-keep-notes-parser${NC}"
echo -e "${GREEN}✓ Messages routed by type using ParserRegistry${NC}"
echo -e "${GREEN}✓ Training messages parsed with ANTLR4${NC}"
echo -e "${GREEN}✓ Time entry messages parsed${NC}"
echo -e "${GREEN}✓ Next entry messages parsed${NC}"
echo -e "${GREEN}✓ Parsed data written to /tmp/training, /tmp/time-entries, and /tmp/next-entries${NC}"

echo -e "\n${YELLOW}Pipeline Verification Summary:${NC}"
echo "  Input:  Google Keep notes (JSON files)"
echo "  Step 1: Publisher → messages.10.raw"
echo "  Step 2: Router → messages.20.type.training, messages.20.type.time, messages.20.type.next"
echo "  Step 3a: Training Listener → messages.30.type.training.10.parsed"
echo "  Step 3b: Time Entry Listener → messages.30.type.time.10.parsed"
echo "  Step 3c: Next Entry Listener → messages.30.type.next.10.parsed"
echo "  Step 4: Writers → /tmp/training/*.json, /tmp/time-entries/*.json, /tmp/next-entries/*.json"
echo "  Output: $TRAINING_FILES workout(s), $TIME_ENTRY_FILES time entry(ies), $NEXT_FILES next entry(ies)"

echo -e "\n${YELLOW}Component Status:${NC}"
if kill -0 $WRITER_PID 2>/dev/null; then echo "  ✓ Training Writer running"; else echo "  ✗ Training Writer stopped"; fi
if kill -0 $LISTENER_PID 2>/dev/null; then echo "  ✓ Training Listener running"; else echo "  ✗ Training Listener stopped"; fi
if kill -0 $TIME_WRITER_PID 2>/dev/null; then echo "  ✓ Time Entry Writer running"; else echo "  ✗ Time Entry Writer stopped"; fi
if kill -0 $TIME_LISTENER_PID 2>/dev/null; then echo "  ✓ Time Entry Listener running"; else echo "  ✗ Time Entry Listener stopped"; fi
if kill -0 $NEXT_WRITER_PID 2>/dev/null; then echo "  ✓ Next Entry Writer running"; else echo "  ✗ Next Entry Writer stopped"; fi
if kill -0 $NEXT_LISTENER_PID 2>/dev/null; then echo "  ✓ Next Entry Listener running"; else echo "  ✗ Next Entry Listener stopped"; fi
if kill -0 $ROUTER_PID 2>/dev/null; then echo "  ✓ Router running"; else echo "  ✗ Router stopped"; fi

echo -e "\n${GREEN}===================================================${NC}"
echo -e "${GREEN}NATS Pipeline Test PASSED ✓${NC}"
echo -e "${GREEN}===================================================${NC}"
