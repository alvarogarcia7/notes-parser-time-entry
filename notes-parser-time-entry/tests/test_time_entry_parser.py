"""Tests for TimeEntryParser."""
import sys
from pathlib import Path
import pytest

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from time_entry_parser import TimeEntryParser, ParseResult


@pytest.fixture
def parser():
    """Create a TimeEntryParser instance."""
    return TimeEntryParser()


def test_can_parse_valid_time_entry_note(parser):
    """Test that parser correctly identifies a valid time entry note."""
    note = {
        "text": "☐ 9 start\n☐ 930 work\n☐ 1700 stop",
        "title": "Daily Log"
    }
    assert parser.can_parse(note) is True


def test_can_parse_requires_two_entries(parser):
    """Test that parser requires at least 2 time entries."""
    note_one_entry = {
        "text": "☐ 9 start",
        "title": "Single Entry"
    }
    assert parser.can_parse(note_one_entry) is False

    note_two_entries = {
        "text": "☐ 9 start\n☐ 930 work",
        "title": "Two Entries"
    }
    assert parser.can_parse(note_two_entries) is True


def test_can_parse_rejects_non_dict(parser):
    """Test that parser rejects non-dict note_data."""
    assert parser.can_parse("not a dict") is False
    assert parser.can_parse(None) is False
    assert parser.can_parse([]) is False


def test_can_parse_rejects_empty_text(parser):
    """Test that parser rejects notes with empty text."""
    note = {"text": "", "title": "Empty"}
    assert parser.can_parse(note) is False

    note = {"title": "No Text"}
    assert parser.can_parse(note) is False


def test_parse_creates_parse_result(parser):
    """Test that parse() returns a ParseResult with correct structure."""
    note = {
        "id": "test-id-123",
        "title": "Daily Log",
        "text": "☐ 9 start\n☐ 930 work\n☐ 1700 stop",
        "timestamps": {
            "created": "2026-01-23T08:00:00+00:00",
            "edited": "2026-01-23T18:00:00+00:00"
        }
    }
    result = parser.parse(note)

    assert isinstance(result, ParseResult)
    assert result.note_id == "test-id-123"
    assert result.title == "Daily Log"
    assert result.date == "2026-01-23"
    assert len(result.time_entries) >= 2


def test_parse_time_entries_basic(parser):
    """Test basic time entry parsing."""
    note = {
        "id": "test-id",
        "title": "Test",
        "text": "☐ 9 start\n☐ 930 work\n☐ 1700 stop",
        "timestamps": {
            "created": "2026-01-23T08:00:00+00:00",
            "edited": "2026-01-23T18:00:00+00:00"
        }
    }
    result = parser.parse(note)

    # Should have at least 3 entries: start, work, stop
    assert len(result.time_entries) >= 3

    # Check first entry
    first_entry = result.time_entries[0]
    assert "time" in first_entry
    assert "activity" in first_entry
    assert "project_type" in first_entry


def test_shortcut_expansion_work(parser):
    """Test that 'wk' shortcut expands to 'work'."""
    note = {
        "id": "test-id",
        "title": "Test",
        "text": "☐ 9 start\n☐ 930 wk meeting\n☐ 1700 stop",
        "timestamps": {
            "created": "2026-01-23T08:00:00+00:00",
            "edited": "2026-01-23T18:00:00+00:00"
        }
    }
    result = parser.parse(note)

    # Find the "wk meeting" entry
    work_entries = [e for e in result.time_entries if "meeting" in e.get("activity", "")]
    assert len(work_entries) > 0
    work_entry = work_entries[0]
    assert "work " in work_entry["activity"].lower()  # Should be "work meeting"


def test_shortcut_expansion_strength_training(parser):
    """Test that 'st' shortcut expands to 'strength training'."""
    note = {
        "id": "test-id",
        "title": "Test",
        "text": "☐ 9 start\n☐ 930 st\n☐ 1700 stop",
        "timestamps": {
            "created": "2026-01-23T08:00:00+00:00",
            "edited": "2026-01-23T18:00:00+00:00"
        }
    }
    result = parser.parse(note)

    # Find the "st" entry
    st_entries = [e for e in result.time_entries if "strength training" in e.get("activity", "")]
    assert len(st_entries) > 0


def test_project_type_classification_work(parser):
    """Test that work projects are classified correctly."""
    note = {
        "id": "test-id",
        "title": "Test",
        "text": "☐ 9 start\n☐ 930 work project\n☐ 1700 stop",
        "timestamps": {
            "created": "2026-01-23T08:00:00+00:00",
            "edited": "2026-01-23T18:00:00+00:00"
        }
    }
    result = parser.parse(note)

    work_entries = [e for e in result.time_entries if "work" in e.get("activity", "")]
    assert len(work_entries) > 0
    assert work_entries[0]["project_type"] == "work"


def test_project_type_classification_personal(parser):
    """Test that personal projects are classified correctly."""
    note = {
        "id": "test-id",
        "title": "Test",
        "text": "☐ 9 start\n☐ 930 gym\n☐ 1700 stop",
        "timestamps": {
            "created": "2026-01-23T08:00:00+00:00",
            "edited": "2026-01-23T18:00:00+00:00"
        }
    }
    result = parser.parse(note)

    gym_entries = [e for e in result.time_entries if "gym" in e.get("activity", "")]
    assert len(gym_entries) > 0
    assert gym_entries[0]["project_type"] == "personal"


def test_time_parsing_24hour_format(parser):
    """Test parsing 24-hour time codes."""
    note = {
        "id": "test-id",
        "title": "Test",
        "text": "☐ 900 start\n☐ 1530 work\n☐ 1700 stop",
        "timestamps": {
            "created": "2026-01-23T08:00:00+00:00",
            "edited": "2026-01-23T18:00:00+00:00"
        }
    }
    result = parser.parse(note)

    times = [e["time"] for e in result.time_entries]
    assert "09:00" in times
    assert "15:30" in times
    assert "17:00" in times
