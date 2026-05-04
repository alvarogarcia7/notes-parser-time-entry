.PHONY: sync test install clean help listener-time writer-time

sync:
	uv sync

test: sync
	uv run pytest tests/ -v

install: sync

clean:
	find . -type d -name __pycache__ -exec rm -rf {} +
	find . -type f -name "*.pyc" -delete
	rm -rf build/ dist/ *.egg-info/

listener-time: sync
	uv run python nats/nats_time_listener.py

writer-time: sync
	uv run python nats/nats_writer.py

help:
	@echo "Time Entry Parser"
	@echo ""
	@echo "Build & Test:"
	@echo "  make sync          - Install dependencies using uv"
	@echo "  make test          - Run pytest tests"
	@echo "  make install       - Install dependencies"
	@echo "  make clean         - Clean up cache and build artifacts"
	@echo ""
	@echo "Components:"
	@echo "  make listener-time - Start time entry listener"
	@echo "  make writer-time   - Start time entry writer"
