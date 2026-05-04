.PHONY: sync test install clean

sync:
	uv sync

test: sync
	uv run pytest tests/ -v

install: sync

clean:
	find . -type d -name __pycache__ -exec rm -rf {} +
	find . -type f -name "*.pyc" -delete
	rm -rf build/ dist/ *.egg-info/

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  sync     - Install dependencies using uv"
	@echo "  test     - Run pytest tests"
	@echo "  install  - Install dependencies"
	@echo "  clean    - Clean up cache and build artifacts"
