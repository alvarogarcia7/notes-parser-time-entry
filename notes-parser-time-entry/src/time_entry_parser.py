import re
import json
import os
import yaml
from typing import Any, Dict, List, Tuple, Optional
from datetime import datetime, timedelta
from dataclasses import dataclass
from pathlib import Path


@dataclass
class ParseResult:
    note_id: str
    title: str
    date: str
    created: str
    last_updated: str
    time_entries: List[Dict[str, Any]]
    raw_text: str
    warnings: List[str]


class TimeEntryParser:
    TIME_CODE_PATTERN: str = r'^\s*[☐☑]?\s*(\d{1,4})\s*([ap]m?|[AP]M?)?\s+(.+)$'
    CONTINUATION_PATTERN: str = r'^(\d{1,4})\s*([ap]m?|[AP]M?)?\s+(\d{1,4})\s*([ap]m?|[AP]M?)?\s+(.*)$'

    ACTIVITY_SHORTCUTS: Dict[str, str] = {
        'st': 'strength training',
        'gym': 'gym class',
        'wk': 'work',
    }

    def __init__(self) -> None:
        tokens_path: str = str(Path(__file__).parent.parent / "tokens.yaml")
        with open(tokens_path, 'r') as f:
            tokens: Dict[str, Any] = yaml.safe_load(f)

        self.START_KEYWORDS: set[str] = set(tokens.get('start_keywords', []))
        self.STOP_KEYWORDS: set[str] = set(tokens.get('end_keywords', []))
        end_keywords = set(tokens.get('end_keywords', []))
        self.END_KEYWORDS: set[str] = end_keywords - self.STOP_KEYWORDS if end_keywords else set()
        self.CONTINUE_KEYWORDS: set[str] = set(tokens.get('continue_keywords', []))
        self.WORK_PROJECTS: set[str] = set(tokens.get('work_projects', []))
        self.PERSONAL_PROJECTS: set[str] = set(tokens.get('personal_projects', []))

    def can_parse(self, note_data: Any) -> bool:
        if not isinstance(note_data, dict):
            return False

        text: str = note_data.get('text', '')
        if not text:
            return False

        lines: List[str] = text.strip().split('\n')
        time_entry_count: int = 0

        for line in lines:
            match = re.match(self.TIME_CODE_PATTERN, line.strip())
            if match:
                time_code: str = match.group(1)
                am_pm: Optional[str] = match.group(2)
                if self._is_valid_time_code(time_code, am_pm):
                    time_entry_count += 1

        return time_entry_count >= 2

    def _is_valid_time_code(self, time_code: str, am_pm: Optional[str] = None) -> bool:
        try:
            time_int = int(time_code)
        except ValueError:
            return False

        if am_pm:
            hours = time_int if len(time_code) <= 2 else int(time_code[:-2])
            minutes = 0 if len(time_code) <= 2 else int(time_code[-2:])
            return 1 <= hours <= 12 and 0 <= minutes <= 59

        if len(time_code) == 1 or len(time_code) == 2:
            return 0 <= time_int <= 23
        elif len(time_code) == 3:
            hours = int(time_code[0])
            minutes = int(time_code[1:])
            return 0 <= hours <= 9 and 0 <= minutes <= 59
        elif len(time_code) == 4:
            hours = int(time_code[:2])
            minutes = int(time_code[2:])
            return 0 <= hours <= 23 and 0 <= minutes <= 59
        else:
            return False

    def _parse_time_code(self, time_code: str, am_pm: Optional[str] = None) -> str:
        time_int = int(time_code)

        if am_pm:
            am_pm_lower = am_pm.lower()
            is_pm = am_pm_lower.startswith('p')

            if len(time_code) <= 2:
                hours = time_int
                minutes = 0
            else:
                hours = time_int // 100
                minutes = time_int % 100

            if is_pm and hours != 12:
                hours += 12
            elif not is_pm and hours == 12:
                hours = 0

            return f"{hours:02d}:{minutes:02d}"

        if len(time_code) == 1 or len(time_code) == 2:
            hours = time_int
            minutes = 0
        elif len(time_code) == 3:
            hours = int(time_code[0])
            minutes = int(time_code[1:])
        elif len(time_code) == 4:
            hours = int(time_code[:2])
            minutes = int(time_code[2:])
        else:
            return ""

        return f"{hours:02d}:{minutes:02d}"

    def _expand_shortcuts(self, activity: str) -> str:
        words = activity.split()
        if words and words[0].lower() in self.ACTIVITY_SHORTCUTS:
            return self.ACTIVITY_SHORTCUTS[words[0].lower()] + ' ' + ' '.join(words[1:])
        return activity

    def _classify_project(self, activity: str) -> str:
        activity_lower = activity.lower()

        for keyword in self.WORK_PROJECTS:
            if keyword in activity_lower:
                return 'work'

        for keyword in self.PERSONAL_PROJECTS:
            if keyword in activity_lower:
                return 'personal'

        return 'personal'

    def _is_stop_activity(self, activity: str) -> bool:
        activity_lower = activity.lower()
        return any(keyword in activity_lower for keyword in self.STOP_KEYWORDS)

    def _is_start_activity(self, activity: str) -> bool:
        activity_lower = activity.lower()
        return any(keyword in activity_lower for keyword in self.START_KEYWORDS)

    def _is_end_keyword(self, activity: str) -> bool:
        activity_lower = activity.lower().strip()
        return activity_lower in self.END_KEYWORDS

    def _is_continue_keyword(self, activity: str) -> bool:
        activity_lower = activity.lower().strip()
        return activity_lower in self.CONTINUE_KEYWORDS

    def _check_continuation_pattern(self, activity: str) -> Optional[Tuple[str, str, str]]:
        match = re.match(self.CONTINUATION_PATTERN, activity)
        if match:
            start_time = match.group(1)
            start_am_pm = match.group(2)
            end_time = match.group(3)
            end_am_pm = match.group(4)
            rest_of_activity = match.group(5).strip()

            if self._is_valid_time_code(start_time, start_am_pm) and self._is_valid_time_code(end_time, end_am_pm):
                start_str = self._parse_time_code(start_time, start_am_pm)
                end_str = self._parse_time_code(end_time, end_am_pm)
                return (start_str, end_str, rest_of_activity)
        return None

    def parse(self, note_data: Any) -> ParseResult:
        if not isinstance(note_data, dict):
            raise ValueError("note_data must be a dictionary")

        text: str = note_data.get('text', '')
        title: str = note_data.get('title', '')
        timestamps: Dict[str, str] = note_data.get('timestamps', {})

        created: str = timestamps.get('created', '')
        edited: str = timestamps.get('edited', '')

        entries, parse_warnings = self._extract_time_entries(text, created, edited)

        first_entry_date = self._extract_date_from_timestamp(created)
        if entries:
            non_auto_entries = [e for e in entries if '[auto-generated' not in e['raw_line']]
            if non_auto_entries:
                first_entry_date = non_auto_entries[0]['date']

        result = ParseResult(
            note_id=note_data.get('id', ''),
            title=title,
            date=first_entry_date,
            created=created,
            last_updated=edited,
            time_entries=entries,
            raw_text=text,
            warnings=parse_warnings
        )

        return result

    def _extract_date_from_timestamp(self, timestamp: str) -> str:
        if not timestamp:
            return ''

        try:
            dt: datetime = datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
            return dt.strftime('%Y-%m-%d')
        except (ValueError, AttributeError):
            return timestamp.split('T')[0] if 'T' in timestamp else timestamp.split(' ')[0]

    def _parse_activity(self, activity: str) -> Tuple[str, str]:
        pattern = r'^(.+?)\s+\d+\.\s+(.+)$'
        match = re.match(pattern, activity)

        if match:
            main_activity = match.group(1).strip()
            sub_activity = match.group(2).strip()
            return main_activity, sub_activity

        return activity, ''

    def _time_to_minutes(self, time_str: str) -> int:
        parts = time_str.split(':')
        return int(parts[0]) * 60 + int(parts[1])

    def _extract_time_entries(self, text: str, created_timestamp: str, edited_timestamp: str) -> Tuple[List[Dict[str, Any]], List[str]]:
        entries: List[Dict[str, Any]] = []
        parse_warnings: List[str] = []
        lines: List[str] = text.strip().split('\n')

        base_date_str: str = self._extract_date_from_timestamp(created_timestamp)
        base_date: Optional[datetime] = None
        if base_date_str:
            try:
                base_date = datetime.fromisoformat(base_date_str)
            except ValueError:
                pass

        current_date = base_date
        last_time_minutes = -1
        last_work_activity: Optional[str] = None
        parsing_active = True
        previous_entry: Optional[Dict[str, Any]] = None

        created_date = self._extract_date_from_timestamp(created_timestamp)
        edited_date = self._extract_date_from_timestamp(edited_timestamp)
        spans_multiple_days = created_date != edited_date

        original_order: List[str] = []

        for line in lines:
            match = re.match(self.TIME_CODE_PATTERN, line.strip())
            if match:
                time_code: str = match.group(1)
                am_pm: Optional[str] = match.group(2)
                activity: str = match.group(3).strip()

                if not self._is_valid_time_code(time_code, am_pm):
                    continue

                if self._is_end_keyword(activity):
                    parsing_active = False
                    continue

                if not parsing_active:
                    parsing_active = True

                activity = self._expand_shortcuts(activity)

                if self._is_continue_keyword(activity):
                    if last_work_activity:
                        activity = last_work_activity
                    else:
                        parse_warnings.append("'cont' keyword used but no previous work activity found")
                        continue

                continuation = self._check_continuation_pattern(activity)

                if continuation:
                    start_time_str, end_time_str, remaining_activity = continuation
                    time_str = start_time_str
                    activity = remaining_activity if remaining_activity else "continued task"
                else:
                    time_str = self._parse_time_code(time_code, am_pm)

                time_minutes = self._time_to_minutes(time_str)
                original_order.append(time_str)

                if time_minutes < last_time_minutes:
                    if current_date and spans_multiple_days:
                        current_date = current_date + timedelta(days=1)

                if current_date:
                    date_str = current_date.strftime('%Y-%m-%d')
                    timestamp_str = f"{date_str}T{time_str}:00"
                else:
                    date_str = base_date_str
                    timestamp_str = f"{time_str}:00" if not base_date_str else f"{base_date_str}T{time_str}:00"

                if self._is_start_activity(activity) and previous_entry and self._is_stop_activity(previous_entry['activity']):
                    pass
                elif previous_entry and self._is_start_activity(activity) and time_minutes >= last_time_minutes:
                    prev_time = previous_entry['time']
                    stop_date: Optional[datetime] = None
                    if current_date:
                        stop_date = current_date - timedelta(days=1)
                    else:
                        stop_date = base_date - timedelta(days=1) if base_date else None

                    if stop_date:
                        stop_entry = {
                            'timestamp': f"{stop_date.strftime('%Y-%m-%d')}T{prev_time}:00",
                            'time': prev_time,
                            'date': stop_date.strftime('%Y-%m-%d'),
                            'activity': 'stop',
                            'main_activity': 'stop',
                            'sub_activity': '',
                            'project_type': 'personal',
                            'project': 'stop',
                            'raw_line': '[auto-generated from start]'
                        }
                        entries.append(stop_entry)

                main_activity, sub_activity = self._parse_activity(activity)
                project_type = self._classify_project(activity)

                entry: Dict[str, Any] = {
                    'timestamp': timestamp_str,
                    'time': time_str,
                    'date': date_str,
                    'activity': activity,
                    'main_activity': main_activity,
                    'sub_activity': sub_activity,
                    'project_type': project_type,
                    'raw_line': line.strip()
                }

                if continuation:
                    entry['end_time'] = end_time_str
                    entry['duration'] = self._time_to_minutes(end_time_str) - self._time_to_minutes(start_time_str)

                if self._is_stop_activity(activity):
                    entry['project'] = 'stop'
                    if current_date:
                        next_date = current_date + timedelta(days=1)
                        current_date = next_date
                        last_time_minutes = -1
                    else:
                        last_time_minutes = time_minutes
                else:
                    last_time_minutes = time_minutes

                entries.append(entry)

                if project_type == 'work':
                    last_work_activity = activity

                previous_entry = entry

        entries.sort(key=lambda x: (x['date'], x['time']))

        if not spans_multiple_days:
            sorted_order: List[str] = [entry['time'] for entry in entries if '[auto-generated' not in entry['raw_line']]
            original_order_filtered = [t for i, t in enumerate(original_order)]
            if original_order_filtered != sorted_order:
                warning_msg = (
                    f"Time entries are out of chronological order. "
                    f"Original order: {original_order_filtered}, Sorted order: {sorted_order}"
                )
                if warning_msg not in parse_warnings:
                    parse_warnings.append(warning_msg)

        return entries, parse_warnings

    def get_schema(self) -> Dict[str, Any]:
        schema_path: str = str(Path(__file__).parent.parent / "schemas" / "time_entry.schema.json")
        with open(schema_path, 'r') as f:
            schema: Dict[str, Any] = json.load(f)
            return schema
