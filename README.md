# clawback

Backup and restore your [Claude Code](https://docs.anthropic.com/en/docs/claude-code) configuration with automatic credential sanitization.

Clone once, run `./backup.sh`, get a sanitized backup of your Claude Code setup on GitHub. All API keys, tokens, and passwords are automatically replaced with `PLACEHOLDER` before anything touches git.

## Quick Start

```bash
# 1. Clone clawback
git clone https://github.com/YOUR_USERNAME/clawback.git
cd clawback

# 2. Run backup (local-only by default, no GitHub access needed)
./backup.sh

# 3. Push to GitHub when ready
./backup.sh --push
```

That's it. Step 2 copies and sanitizes your config to `~/.claude-backup/`. Step 3 creates a private `claude-setup` repo on your GitHub and pushes the sanitized files.

## What Gets Backed Up

| File / Directory | Purpose | Required |
|---|---|---|
| `~/.claude.json` | MCP servers, trust settings, tool permissions | Yes |
| `~/CLAUDE.md` | Global instructions for Claude Code | No |
| `~/.claude/agents/` | Custom agent definitions | No |
| `~/.claude/skills/` | Custom skills (slash commands) | No |
| `~/.claude/commands/` | Legacy commands | No |
| `~/.claude/scripts/` | Utility scripts | No |
| `~/.claude/plugins/*.json` | Plugin config and metadata | No |
| `~/.claude/settings.json` | User preferences and permissions | No |
| `~/.claude/settings.local.json` | Machine-specific overrides | No |

**Not backed up:** Runtime caches, conversation history, telemetry, task data, plugin marketplace directories (reinstallable), project-level `.mcp.json` files (project-specific), `.credentials.json`.

**Scope:** Only `~/CLAUDE.md` is backed up. Project-specific `CLAUDE.md` files belong in their respective repositories.

## What Gets Sanitized

### Key-Name Matching

Any JSON key matching these patterns has its value replaced with `PLACEHOLDER`:

- `*_TOKEN`, `*_API_KEY`, `*_APP_KEY`, `*_PASSWORD`, `*_SECRET`, `*_PAT`
- `Authorization` headers
- `token`, `api_key`, `apikey` fields

This catches MCP server credentials at any nesting depth:
```json
{"mcpServers": {"myserver": {"env": {"MY_API_KEY": "PLACEHOLDER"}}}}
```

### Value Scanning

A separate pass catches credentials embedded in values regardless of key name:

- Connection strings: `postgres://user:pass@host/db` → `postgres://PLACEHOLDER`
- URLs with token params: `https://api.example.com?token=abc123` → `https://api.example.com?token=PLACEHOLDER`

### Path Sanitization

Absolute home paths are replaced with `~/` for portability:
- `/Users/yourname/projects/` → `~/projects/`
- `/home/yourname/.config/` → `~/.config/`

### Token Type Detection

When a credential is replaced, clawback logs what type it detected:
`gitlab_pat`, `github_pat`, `slack_token`, `anthropic_key`, `openai_key`, `aws_key`, `generic_bearer`

This is for reporting only — replacement is driven by key-name matching, not value patterns.

## Commands

### `backup.sh`

```
Usage: backup.sh [OPTIONS]

Options:
  --push              Commit and push to GitHub (default: local-only)
  --dry-run           Show what would happen without making changes
  --repo NAME         Target repo name (default: claude-setup)
  --dir PATH          Local backup directory (default: ~/.claude-backup)
  --message "msg"     Custom commit message (with --push)
```

### `restore.sh`

```
Usage: restore.sh [OPTIONS]

Options:
  --repo NAME         Source repo name (default: claude-setup)
  --from PATH         Restore from local directory instead of GitHub
  --dry-run           Show what would be restored without copying
  --force             Overwrite existing files without confirmation
```

### `sanitize.py`

```
Usage: sanitize.py [OPTIONS] [FILES...]

Options:
  --dry-run           Show changes without modifying files
  --quiet             Suppress output (exit code only)
  --paths             Also sanitize file paths in non-JSON files
```

## Configuration

| Environment Variable | Default | Description |
|---|---|---|
| `CLAUDE_BACKUP_REPO` | `claude-setup` | Name of your backup repository on GitHub |
| `CLAUDE_BACKUP_DIR` | `~/.claude-backup` | Local directory for backup files |
| `CLAWBACK_DIR` | _(none)_ | Path to clawback installation (used by the skill) |

## Claude Code Skill

Install the `/clawback-backup` skill to run backups from within Claude Code:

```bash
# Copy the skill to your Claude Code skills directory
cp -r skill/clawback-backup ~/.claude/skills/

# Set the install path (add to your shell profile)
export CLAWBACK_DIR="/path/to/clawback"
```

After restarting Claude Code, use `/clawback-backup` or `/clawback-backup --push`.

## Updating

clawback uses a run-from-source architecture. Scripts stay in this repo — your backup repo only contains config files.

To get the latest sanitization patterns and features:

```bash
cd /path/to/clawback
git pull
```

## Restoring from Backup

```bash
# Preview what would be restored
./restore.sh --dry-run

# Restore (prompts before overwriting existing files)
./restore.sh

# Restore without prompts
./restore.sh --force
```

After restoring, edit `~/.claude.json` and replace `PLACEHOLDER` values with your actual credentials. The restore script will show you exactly which lines need updating.

## Extending Sanitization

### Adding Key-Name Patterns

Edit `sanitize.py` and add to `SENSITIVE_KEY_PATTERNS`:

```python
SENSITIVE_KEY_PATTERNS = [
    ...
    r'^my_custom_secret$',    # Exact match
    r'.*_CREDENTIALS$',       # Suffix match
]
```

### Adding Token Detection

Edit `sanitize.py` and add to `TOKEN_PATTERNS` (logging only, doesn't trigger replacement):

```python
TOKEN_PATTERNS = {
    ...
    'my_service': r'mytoken_[A-Za-z0-9]+',
}
```

## Prerequisites

- **git** — Version control
- **python3** (3.7+) — Runs the sanitization script
- **gh** (GitHub CLI) — Only needed for `--push` and `restore.sh`. Install: https://cli.github.com

## License

MIT
