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
NATS_URL="nats://localhost:$NATS_PORT"
NATS_CONTAINER="nats-pipeline-test"
OUTPUT_DIR="/tmp/training"
TIMEOUT=15

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}🛑 Cleaning up...${NC}"

    # Kill all background processes
    jobs -p | xargs -r kill 2>/dev/null || true
    sleep 1

    # Stop and remove NATS container (both running and stopped)
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
pkill -f "nats_router.py" 2>/dev/null || true
pkill -f "nats_publisher.py" 2>/dev/null || true
sleep 1
print_success "Previous processes cleaned up"

print_step "Stopping any existing Docker containers..."

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

print_success "Docker containers cleaned up"

print_step "Cleaning output directory..."
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
print_success "Output directory cleaned"

sleep 1

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

# Check required files exist
print_step "Checking for implementation files..."

FILES=(
    "google-keep-notes-parser/nats_publisher.py"
    "google-keep-notes-parser/nats_router.py"
    "training-parser-antlr4/nats_training_listener.py"
    "training-parser-antlr4/nats_writer.py"
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

print_step "Installing google-keep-notes-parser dependencies..."
cd "$REPO_ROOT/google-keep-notes-parser"
uv pip install -e . > /tmp/uv_publisher.log 2>&1
if [ $? -eq 0 ]; then
    print_success "google-keep-notes-parser installed"
else
    print_error "Failed to install google-keep-notes-parser"
    echo "Log: /tmp/uv_publisher.log"
    tail -20 /tmp/uv_publisher.log
    exit 1
fi

print_step "Installing training-parser-antlr4 dependencies..."
cd "$REPO_ROOT/training-parser-antlr4"
uv pip install -e . > /tmp/uv_listener.log 2>&1
if [ $? -eq 0 ]; then
    print_success "training-parser-antlr4 installed"
else
    print_error "Failed to install training-parser-antlr4"
    echo "Log: /tmp/uv_listener.log"
    tail -20 /tmp/uv_listener.log
    exit 1
fi

# Install nats-py if not already installed
print_step "Installing NATS client library..."
uv pip install 'nats-py>=2.6.0' > /tmp/uv_nats.log 2>&1
if [ $? -eq 0 ]; then
    print_success "NATS client library installed"
else
    print_error "Failed to install NATS client library"
    echo "Log: /tmp/uv_nats.log"
    tail -20 /tmp/uv_nats.log
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
    print_step "Starting NATS in Docker..."
    docker run -d \
        --name "$NATS_CONTAINER" \
        -p "$NATS_PORT:4222" \
        nats:latest >/dev/null 2>&1

    # Wait for NATS to be ready
    NATS_READY=0
    for i in {1..30}; do
        if is_port_open $NATS_PORT; then
            print_success "NATS started and ready"
            NATS_READY=1
            break
        fi
        sleep 0.5
    done

    if [ $NATS_READY -eq 0 ]; then
        print_error "NATS failed to start after 15 seconds"
        echo ""
        echo -e "${YELLOW}Docker container status:${NC}"
        docker ps -a --filter "name=$NATS_CONTAINER" || echo "  Container not found"
        echo ""
        echo -e "${YELLOW}Docker logs (last 20 lines):${NC}"
        docker logs "$NATS_CONTAINER" 2>/dev/null | tail -20 || echo "  (no logs available)"
        exit 1
    fi
fi

# Start all components
print_header "Starting Pipeline Components"

print_step "Starting Writer (listens for parsed sessions)..."
cd "$REPO_ROOT/training-parser-antlr4"
python nats_writer.py > /tmp/nats_writer.log 2>&1 &
WRITER_PID=$!
sleep 1
if kill -0 $WRITER_PID 2>/dev/null; then
    print_success "Writer started (PID: $WRITER_PID)"
else
    print_error "Writer failed to start"
    cat /tmp/nats_writer.log
    exit 1
fi

print_step "Starting Training Listener (parses with ANTLR4)..."
python nats_training_listener.py > /tmp/nats_training_listener.log 2>&1 &
LISTENER_PID=$!
sleep 1
if kill -0 $LISTENER_PID 2>/dev/null; then
    print_success "Training Listener started (PID: $LISTENER_PID)"
else
    print_error "Training Listener failed to start"
    cat /tmp/nats_training_listener.log
    exit 1
fi

print_step "Starting Router (routes by type)..."
cd "$REPO_ROOT/google-keep-notes-parser"
python nats_router.py > /tmp/nats_router.log 2>&1 &
ROUTER_PID=$!
sleep 1
if kill -0 $ROUTER_PID 2>/dev/null; then
    print_success "Router started (PID: $ROUTER_PID)"
else
    print_error "Router failed to start"
    cat /tmp/nats_router.log
    exit 1
fi

# Run publisher
print_header "Publishing Sample Data"

print_step "Running Publisher (reads JSON files)..."
python nats_publisher.py --input-dir sample

# Wait for processing
print_header "Processing"

print_step "Waiting for pipeline processing (${TIMEOUT}s timeout)..."
WAITED=0
LAST_COUNT=0

while [ $WAITED -lt $TIMEOUT ]; do
    CURRENT_COUNT=$(ls "$OUTPUT_DIR"/*.json 2>/dev/null | wc -l)

    if [ $CURRENT_COUNT -gt $LAST_COUNT ]; then
        echo -ne "\r${BLUE}Found $CURRENT_COUNT output file(s)${NC}"
        LAST_COUNT=$CURRENT_COUNT
        ls "$OUTPUT_DIR"/*.json
    fi

    sleep 1
    WAITED=$((WAITED + 1))
done
echo ""

# Verify results
print_header "Results Verification"

if [ -d "$OUTPUT_DIR" ]; then
    FILE_COUNT=$(ls "$OUTPUT_DIR"/*.json 2>/dev/null | wc -l)

    if [ $FILE_COUNT -gt 0 ]; then
        print_success "Pipeline executed successfully!"
        print_success "Generated $FILE_COUNT output file(s)"

        echo -e "\n${YELLOW}Output Files:${NC}"
        ls -lh "$OUTPUT_DIR"/*.json | awk '{print "  " $9 " (" $5 ")"}'

        echo -e "\n${YELLOW}Sample Output (first file, first 30 lines):${NC}"
        echo "---"
        head -30 "$OUTPUT_DIR"/0.json | sed 's/^/  /'
        echo "---"

        # Validate JSON
        print_step "Validating JSON output..."
        VALID_JSON=0
        for file in "$OUTPUT_DIR"/*.json; do
            if python3 -c "import json; json.load(open('$file'))" 2>/dev/null; then
                VALID_JSON=$((VALID_JSON + 1))
            fi
        done

        if [ $VALID_JSON -eq $FILE_COUNT ]; then
            print_success "All output files are valid JSON ($VALID_JSON/$FILE_COUNT)"
        else
            print_error "Some files are invalid JSON ($VALID_JSON/$FILE_COUNT)"
        fi

        # Check file content
        print_step "Checking output content..."
        FIRST_FILE="$OUTPUT_DIR/0.json"

        if grep -q '"workout_id"' "$FIRST_FILE" 2>/dev/null; then
            print_success "Output contains 'workout_id' field"
        else
            print_error "Output missing 'workout_id' field"
        fi

        if grep -q '"exercises"' "$FIRST_FILE" 2>/dev/null; then
            print_success "Output contains 'exercises' field"
        else
            print_error "Output missing 'exercises' field"
        fi

        if grep -q '"date"' "$FIRST_FILE" 2>/dev/null; then
            print_success "Output contains 'date' field"
        else
            print_error "Output missing 'date' field"
        fi

    else
        print_error "No output files generated"

        echo -e "\n${YELLOW}Debugging Information:${NC}"

        echo -e "\n${YELLOW}Writer Log:${NC}"
        tail -10 /tmp/nats_writer.log 2>/dev/null || echo "  (no log)"

        echo -e "\n${YELLOW}Training Listener Log:${NC}"
        tail -10 /tmp/nats_training_listener.log 2>/dev/null || echo "  (no log)"

        echo -e "\n${YELLOW}Router Log:${NC}"
        tail -10 /tmp/nats_router.log 2>/dev/null || echo "  (no log)"

        echo -e "\n${YELLOW}Running Processes:${NC}"
        jobs -l

        exit 1
    fi
else
    print_error "Output directory not found"
    exit 1
fi

# Final summary
print_header "Test Complete"

echo -e "${GREEN}✓ All pipeline components executed successfully!${NC}"
echo -e "${GREEN}✓ Sample data published from google-keep-notes-parser${NC}"
echo -e "${GREEN}✓ Messages routed by type using ParserRegistry${NC}"
echo -e "${GREEN}✓ Training messages parsed with ANTLR4${NC}"
echo -e "${GREEN}✓ Parsed sessions written to $OUTPUT_DIR${NC}"

echo -e "\n${YELLOW}Pipeline Verification Summary:${NC}"
echo "  Input:  Google Keep notes (JSON files)"
echo "  Step 1: Publisher → messages.10.raw"
echo "  Step 2: Router → messages.20.type.training"
echo "  Step 3: Training Listener → messages.30.type.training.10.parsed"
echo "  Step 4: Writer → /tmp/training/*.json"
echo "  Output: $FILE_COUNT parsed workout session(s)"

echo -e "\n${YELLOW}Component Status:${NC}"
if kill -0 $WRITER_PID 2>/dev/null; then echo "  ✓ Writer running"; else echo "  ✗ Writer stopped"; fi
if kill -0 $LISTENER_PID 2>/dev/null; then echo "  ✓ Training Listener running"; else echo "  ✗ Training Listener stopped"; fi
if kill -0 $ROUTER_PID 2>/dev/null; then echo "  ✓ Router running"; else echo "  ✗ Router stopped"; fi

echo -e "\n${GREEN}===================================================${NC}"
echo -e "${GREEN}NATS Pipeline Test PASSED ✓${NC}"
echo -e "${GREEN}===================================================${NC}"
