#!/usr/bin/env python3
"""
Sanitize sensitive credentials in Claude Code configuration files.

Two-layer sanitization model:
  1. SENSITIVE_KEY_PATTERNS - Key-name matching triggers value replacement
  2. TOKEN_PATTERNS - Logging only, identifies what type of token was replaced

Plus a third pass scanning ALL string values for embedded credentials
(connection strings, URLs with tokens) regardless of key name.
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Tuple

PLACEHOLDER = "PLACEHOLDER"

# Layer 2: Token detection patterns - LOGGING ONLY, never trigger replacement
TOKEN_PATTERNS = {
    "gitlab_pat": r"glpat-[A-Za-z0-9_-]+",
    "github_pat": r"ghp_[A-Za-z0-9]+",
    "github_fine": r"github_pat_[A-Za-z0-9_]+",
    "slack_token": r"xox[bpoa]-[A-Za-z0-9-]+",
    "anthropic_key": r"sk-ant-[A-Za-z0-9-]+",
    "openai_key": r"sk-[A-Za-z0-9]{20,}",
    "aws_key": r"AKIA[A-Z0-9]{16}",
    "generic_bearer": r"Bearer\s+[A-Za-z0-9_.-]+",
}

# Layer 1: Key-name patterns that TRIGGER value replacement
SENSITIVE_KEY_PATTERNS = [
    r".*_TOKEN$",
    r".*_API_KEY$",
    r".*_APP_KEY$",
    r".*_PASSWORD$",
    r".*_SECRET$",
    r".*_PAT$",
    r"^Authorization$",
    r"^token$",
    r"^api[_-]?key$",
]

# Layer 3: Value-scanning patterns applied to ALL string values
# Each tuple: (pattern, replacement)
VALUE_SCAN_PATTERNS = [
    # Connection strings with credentials
    (
        r"((?:postgres|postgresql|mongodb|mongodb\+srv|mysql|redis|amqp|rabbitmq)://)[^\s\"]+",
        r"\1" + PLACEHOLDER,
    ),
    # URLs with token/key query params
    (
        r"(https?://[^\"]*[?&](?:token|key|api_key|apikey|access_token|secret)=)[^\"&]+",
        r"\1" + PLACEHOLDER,
    ),
]


def is_sensitive_key(key: str) -> bool:
    """Check if a key name matches sensitive patterns."""
    for pattern in SENSITIVE_KEY_PATTERNS:
        if re.match(pattern, key, re.IGNORECASE):
            return True
    return False


def is_already_placeholder(value: Any) -> bool:
    """Check if value is already sanitized."""
    if isinstance(value, str):
        return value == PLACEHOLDER or value == f"Bearer {PLACEHOLDER}"
    return False


def detect_token_type(value: str) -> List[str]:
    """Detect token types in a value for logging."""
    detected = []
    for name, pattern in TOKEN_PATTERNS.items():
        if re.search(pattern, value):
            detected.append(name)
    return detected


def sanitize_value(value: Any, key_path: str, quiet: bool = False) -> Tuple[Any, bool]:
    """Sanitize a single value. Returns (sanitized_value, was_modified)."""
    if is_already_placeholder(value):
        return value, False

    if isinstance(value, str):
        token_types = detect_token_type(value)
        if token_types and not quiet:
            print(f"  [SANITIZE] {key_path}: {', '.join(token_types)}")
        elif not quiet:
            print(f"  [SANITIZE] {key_path}")

        if value.startswith("Bearer "):
            return f"Bearer {PLACEHOLDER}", True

        if value.strip():
            return PLACEHOLDER, True

    return value, False


def sanitize_dict(data: Dict, path: str = "", quiet: bool = False) -> Tuple[Dict, int]:
    """Recursively sanitize a dictionary based on key-name patterns."""
    result = {}
    total_changes = 0

    for key, value in data.items():
        current_path = f"{path}.{key}" if path else key

        if isinstance(value, dict):
            sanitized, changes = sanitize_dict(value, current_path, quiet)
            result[key] = sanitized
            total_changes += changes
        elif isinstance(value, list):
            sanitized, changes = sanitize_list(value, current_path, quiet)
            result[key] = sanitized
            total_changes += changes
        elif is_sensitive_key(key):
            sanitized_val, modified = sanitize_value(value, current_path, quiet)
            result[key] = sanitized_val
            if modified:
                total_changes += 1
        else:
            result[key] = value

    return result, total_changes


def sanitize_list(data: List, path: str, quiet: bool = False) -> Tuple[List, int]:
    """Recursively sanitize a list."""
    result = []
    total_changes = 0

    for idx, item in enumerate(data):
        current_path = f"{path}[{idx}]"
        if isinstance(item, dict):
            sanitized, changes = sanitize_dict(item, current_path, quiet)
            result.append(sanitized)
            total_changes += changes
        elif isinstance(item, list):
            sanitized, changes = sanitize_list(item, current_path, quiet)
            result.append(sanitized)
            total_changes += changes
        else:
            result.append(item)

    return result, total_changes


def scan_values(data: Any, path: str = "", quiet: bool = False) -> Tuple[Any, int]:
    """Third pass: scan ALL string values for embedded credentials."""
    total_changes = 0

    if isinstance(data, dict):
        result = {}
        for key, value in data.items():
            current_path = f"{path}.{key}" if path else key
            sanitized, changes = scan_values(value, current_path, quiet)
            result[key] = sanitized
            total_changes += changes
        return result, total_changes

    if isinstance(data, list):
        result = []
        for idx, item in enumerate(data):
            current_path = f"{path}[{idx}]"
            sanitized, changes = scan_values(item, current_path, quiet)
            result.append(sanitized)
            total_changes += changes
        return result, total_changes

    if isinstance(data, str) and not is_already_placeholder(data):
        modified = data
        for pattern, replacement in VALUE_SCAN_PATTERNS:
            new_val = re.sub(pattern, replacement, modified)
            if new_val != modified:
                if not quiet:
                    print(f"  [VALUE SCAN] {path}: embedded credential detected")
                modified = new_val
                total_changes += 1
        return modified, total_changes

    return data, total_changes


def sanitize_paths(content: str) -> Tuple[str, int]:
    """Replace absolute home paths with ~/ for portability."""
    home = os.path.expanduser("~")
    original = content
    content = content.replace(home, "~")
    content = re.sub(r"/(?:Users|home)/[a-zA-Z0-9._-]+/", "~/", content)
    changes = 1 if content != original else 0
    return content, changes


def sanitize_json_file(
    file_path: Path, dry_run: bool = False, quiet: bool = False, do_paths: bool = False
) -> bool:
    """Sanitize a JSON file in-place. Returns True if file was modified."""
    if not file_path.exists():
        if not quiet:
            print(f"[SKIP] {file_path}: not found")
        return False

    if not quiet:
        print(f"\n[PROCESSING] {file_path}")

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        if not quiet:
            print(f"[ERROR] {file_path}: invalid JSON - {e}")
        return False

    # Layer 1: Key-name-based replacement
    sanitized_data, key_changes = sanitize_dict(data, quiet=quiet)

    # Layer 3: Value scanning for embedded credentials
    sanitized_data, value_changes = scan_values(sanitized_data, quiet=quiet)

    total_changes = key_changes + value_changes

    if total_changes == 0:
        if not quiet:
            print("[OK] No sensitive data found (already sanitized)")
        return False

    if not quiet:
        print(f"[MODIFIED] {total_changes} credential(s) replaced with {PLACEHOLDER}")

    if dry_run:
        if not quiet:
            print(f"[DRY RUN] Would update {file_path}")
        return True

    with open(file_path, "w", encoding="utf-8") as f:
        json.dump(sanitized_data, f, indent=2, ensure_ascii=False)
        f.write("\n")

    if not quiet:
        print(f"[UPDATED] {file_path}")
    return True


def sanitize_text_file(
    file_path: Path, dry_run: bool = False, quiet: bool = False
) -> bool:
    """Sanitize paths in a non-JSON file. Returns True if file was modified."""
    if not file_path.exists():
        if not quiet:
            print(f"[SKIP] {file_path}: not found")
        return False

    if not quiet:
        print(f"\n[PROCESSING] {file_path} (path sanitization)")

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            content = f.read()
    except Exception as e:
        if not quiet:
            print(f"[ERROR] {file_path}: {e}")
        return False

    sanitized, changes = sanitize_paths(content)

    if changes == 0:
        if not quiet:
            print("[OK] No paths to sanitize")
        return False

    if not quiet:
        print("[MODIFIED] Home paths replaced with ~/")

    if dry_run:
        if not quiet:
            print(f"[DRY RUN] Would update {file_path}")
        return True

    with open(file_path, "w", encoding="utf-8") as f:
        f.write(sanitized)

    if not quiet:
        print(f"[UPDATED] {file_path}")
    return True


def main():
    parser = argparse.ArgumentParser(
        description="Sanitize sensitive credentials in Claude Code configuration files"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be changed without modifying files",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress output (exit code only)",
    )
    parser.add_argument(
        "--paths",
        action="store_true",
        help="Also sanitize file paths in non-JSON files",
    )
    parser.add_argument(
        "files",
        nargs="*",
        help="Files to sanitize (default: .claude.json, .claude/settings.json, .claude/settings.local.json)",
    )
    args = parser.parse_args()

    default_files = [
        ".claude.json",
        ".claude/settings.json",
        ".claude/settings.local.json",
    ]
    files_to_process = args.files if args.files else default_files

    if not args.quiet:
        print("=" * 60)
        print("clawback - Configuration Sanitizer")
        print("=" * 60)
        if args.dry_run:
            print("[DRY RUN MODE - No files will be modified]")

    modified_files = []
    for file_path_str in files_to_process:
        file_path = Path(file_path_str)
        if file_path.suffix == ".json":
            if sanitize_json_file(file_path, args.dry_run, args.quiet):
                modified_files.append(str(file_path))
        elif args.paths:
            if sanitize_text_file(file_path, args.dry_run, args.quiet):
                modified_files.append(str(file_path))

    if not args.quiet:
        print("\n" + "=" * 60)
        if modified_files:
            print(f"Summary: {len(modified_files)} file(s) {'would be ' if args.dry_run else ''}modified")
            for f in modified_files:
                print(f"  - {f}")
        else:
            print("Summary: No files modified (all clean)")
        print("=" * 60)

    sys.exit(1 if args.dry_run and modified_files else 0)


if __name__ == "__main__":
    main()
