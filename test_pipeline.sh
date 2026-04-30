#!/bin/bash
"""
Test the entire NATS pipeline end-to-end
"""

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATS_URL="nats://localhost:4222"
NATS_PORT=4222

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}🚀 NATS Pipeline Test${NC}"
echo ""

# Check if NATS is running
echo -e "${YELLOW}📍 Checking NATS server...${NC}"
if ! nc -z localhost $NATS_PORT 2>/dev/null; then
    echo -e "${YELLOW}🐳 Starting NATS in Docker...${NC}"
    docker run -d -p $NATS_PORT:4222 --name nats-test nats:latest >/dev/null 2>&1
    sleep 2
    STARTED_NATS=1
else
    echo -e "${GREEN}✓ NATS already running${NC}"
    STARTED_NATS=0
fi

echo ""
echo -e "${YELLOW}📂 Starting pipeline components...${NC}"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}🛑 Cleaning up...${NC}"

    # Kill background processes
    jobs -p | xargs -r kill 2>/dev/null || true
    sleep 1

    # Stop NATS if we started it
    if [ $STARTED_NATS -eq 1 ]; then
        echo "Stopping NATS container..."
        docker stop nats-test >/dev/null 2>&1
        docker rm nats-test >/dev/null 2>&1
    fi

    echo -e "${GREEN}✓ Cleanup complete${NC}"
}

trap cleanup EXIT

# Start writer (step 4)
echo -e "${YELLOW}💾 Starting writer...${NC}"
cd "$REPO_ROOT/training-parser-antlr4"
python nats_writer.py &
WRITER_PID=$!
sleep 1
echo -e "${GREEN}✓ Writer started (PID: $WRITER_PID)${NC}"

# Start training listener (step 3)
echo -e "${YELLOW}🔧 Starting training listener...${NC}"
python nats_training_listener.py &
LISTENER_PID=$!
sleep 1
echo -e "${GREEN}✓ Training listener started (PID: $LISTENER_PID)${NC}"

# Start router (step 2)
echo -e "${YELLOW}🔀 Starting router...${NC}"
cd "$REPO_ROOT/google-keep-notes-parser"
python nats_router.py &
ROUTER_PID=$!
sleep 1
echo -e "${GREEN}✓ Router started (PID: $ROUTER_PID)${NC}"

# Run publisher (step 1)
echo -e "${YELLOW}📤 Running publisher...${NC}"
python nats_publisher.py --input-dir sample
PUBLISHER_EXIT=$?

echo ""
echo -e "${YELLOW}⏳ Waiting for processing...${NC}"
sleep 3

# Check results
echo ""
echo -e "${YELLOW}📊 Pipeline Results${NC}"
echo ""

if [ -d "/tmp/training" ]; then
    FILE_COUNT=$(ls /tmp/training/*.json 2>/dev/null | wc -l)
    if [ $FILE_COUNT -gt 0 ]; then
        echo -e "${GREEN}✓ Successfully processed $FILE_COUNT workout session(s)${NC}"
        echo ""
        echo "Output files:"
        ls -lh /tmp/training/*.json 2>/dev/null | head -5
        echo ""
        echo "Sample output (first 50 lines of first file):"
        head -50 /tmp/training/0.json 2>/dev/null || echo "(no files yet)"
    else
        echo -e "${RED}✗ No output files found in /tmp/training${NC}"
        echo ""
        echo -e "${YELLOW}Debugging info:${NC}"
        echo "Current processes:"
        jobs -l
        echo ""
        echo "Last writer output:"
        tail -20 /tmp/nats_writer.log 2>/dev/null || echo "(no log available)"
    fi
else
    echo -e "${RED}✗ Output directory /tmp/training not found${NC}"
fi

echo ""
echo -e "${YELLOW}Pipeline test complete${NC}"
