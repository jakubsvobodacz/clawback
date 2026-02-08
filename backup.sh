#!/usr/bin/env bash
set -euo pipefail

# clawback - Claude Code Configuration Backup
# https://github.com/YOUR_USERNAME/clawback

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DATE=$(date +"%Y-%m-%d %H:%M:%S")

# Defaults (overridable via env vars or flags)
REPO_NAME="${CLAUDE_BACKUP_REPO:-claude-setup}"
BACKUP_DIR="${CLAUDE_BACKUP_DIR:-$HOME/.claude-backup}"

# Flags
PUSH=false
DRY_RUN=false
COMMIT_MSG=""

usage() {
    cat <<'EOF'
Usage: backup.sh [OPTIONS]

Backup Claude Code configuration files with automatic credential sanitization.

Options:
  --push              Commit and push to GitHub (default: local-only)
  --dry-run           Show what would happen without making changes
  --repo NAME         Target repo name (default: claude-setup, env: CLAUDE_BACKUP_REPO)
  --dir PATH          Local backup directory (default: ~/.claude-backup, env: CLAUDE_BACKUP_DIR)
  --message "msg"     Custom commit message (with --push)
  -h, --help          Show this help

Examples:
  ./backup.sh                    # Copy + sanitize locally, show summary
  ./backup.sh --push             # Copy, sanitize, commit, push to GitHub
  ./backup.sh --dry-run          # Preview what would happen
  ./backup.sh --push --repo my-config  # Push to custom repo name
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --push) PUSH=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --repo) REPO_NAME="$2"; shift 2 ;;
        --dir) BACKUP_DIR="$2"; shift 2 ;;
        --message) COMMIT_MSG="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Check prerequisites
check_prereqs() {
    local missing=()
    command -v git >/dev/null 2>&1 || missing+=("git")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")

    if $PUSH; then
        command -v gh >/dev/null 2>&1 || missing+=("gh (GitHub CLI - required for --push)")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing prerequisites:"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        exit 1
    fi
}

# Copy a file if it exists
copy_file() {
    local src="$1"
    local dest="$2"
    if [ -f "$src" ]; then
        if $DRY_RUN; then
            echo "  + $(basename "$src")"
        else
            cp "$src" "$dest"
            echo "  + $(basename "$src")"
        fi
        return 0
    fi
    return 1
}

# Copy a directory if it exists
copy_dir() {
    local src="$1"
    local dest="$2"
    local name="$3"
    if [ -d "$src" ]; then
        if $DRY_RUN; then
            echo "  + $name/"
        else
            cp -r "$src" "$dest"
            echo "  + $name/"
        fi
        return 0
    fi
    return 1
}

echo "======================================================"
echo "clawback - Claude Code Configuration Backup"
echo "======================================================"
if $DRY_RUN; then
    echo "[DRY RUN MODE - No changes will be made]"
fi
echo

check_prereqs

# Verify ~/.claude.json exists (required)
if [ ! -f "$HOME/.claude.json" ]; then
    echo "Error: ~/.claude.json not found"
    echo "Claude Code doesn't appear to be configured on this machine."
    exit 1
fi

# Create backup directory
if ! $DRY_RUN; then
    mkdir -p "$BACKUP_DIR/.claude/plugins"
fi

echo "Copying configuration files..."

# Required files
copy_file "$HOME/.claude.json" "$BACKUP_DIR/.claude.json"

# Optional top-level files
copy_file "$HOME/CLAUDE.md" "$BACKUP_DIR/CLAUDE.md" || true

# Optional .claude directories
for dir in agents skills commands scripts; do
    copy_dir "$HOME/.claude/$dir" "$BACKUP_DIR/.claude/$dir" ".claude/$dir" || true
done

# Plugin config files (individual files, not marketplace dirs)
for file in config.json installed_plugins.json known_marketplaces.json; do
    copy_file "$HOME/.claude/plugins/$file" "$BACKUP_DIR/.claude/plugins/$file" || true
done

# Optional settings files
for file in settings.json settings.local.json; do
    copy_file "$HOME/.claude/$file" "$BACKUP_DIR/.claude/$file" || true
done

# Generate .gitignore in backup dir (if not present)
if [ ! -f "$BACKUP_DIR/.gitignore" ] && ! $DRY_RUN; then
    cat > "$BACKUP_DIR/.gitignore" <<'GITIGNORE'
# Sensitive files
.credentials.json
**/credentials.json
*.key
*.pem
*.p12

# Runtime and cache
cache/
debug/
file-history/
history.jsonl
paste-cache/
projects/
session-env/
shell-snapshots/
stats-cache.json
statsig/
tasks/
telemetry/
todos/

# Plugin marketplaces (reinstallable)
.claude/plugins/marketplaces/

# IDE locks
.claude/ide/*.lock
.claude/ide/*.pid

# Environment files
.env
.env.local
.env.*.local

# OS files
.DS_Store
*.tmp
*.temp
*.swp
*~
GITIGNORE
    echo "  + .gitignore (generated)"
fi

# Sanitize
echo
echo "Sanitizing credentials..."

SANITIZE_ARGS=("--paths")
if $DRY_RUN; then
    SANITIZE_ARGS+=("--dry-run")
fi

# Build file list for sanitization
SANITIZE_FILES=()
[ -f "$BACKUP_DIR/.claude.json" ] && SANITIZE_FILES+=("$BACKUP_DIR/.claude.json")
[ -f "$BACKUP_DIR/.claude/settings.json" ] && SANITIZE_FILES+=("$BACKUP_DIR/.claude/settings.json")
[ -f "$BACKUP_DIR/.claude/settings.local.json" ] && SANITIZE_FILES+=("$BACKUP_DIR/.claude/settings.local.json")
[ -f "$BACKUP_DIR/CLAUDE.md" ] && SANITIZE_FILES+=("$BACKUP_DIR/CLAUDE.md")

if [ ${#SANITIZE_FILES[@]} -gt 0 ]; then
    python3 "$SCRIPT_DIR/sanitize.py" "${SANITIZE_ARGS[@]}" "${SANITIZE_FILES[@]}" || true
fi

# Summary
echo
echo "======================================================"
echo "Backup directory: $BACKUP_DIR"
echo "Target repo:      $REPO_NAME"

if ! $PUSH; then
    echo
    echo "Local backup complete. Files are sanitized and ready."
    echo
    echo "To commit and push to GitHub, run:"
    echo "  $0 --push"
    echo "======================================================"
    exit 0
fi

# --push: GitHub operations
echo
echo "Pushing to GitHub..."

# Check gh auth
if ! gh auth status >/dev/null 2>&1; then
    echo "Error: GitHub CLI not authenticated. Run: gh auth login"
    exit 1
fi

GH_USER=$(gh api user -q .login)
echo "GitHub user: $GH_USER"

# Check if repo exists, create if not
if ! gh repo view "$GH_USER/$REPO_NAME" >/dev/null 2>&1; then
    echo "Creating private repository: $GH_USER/$REPO_NAME"
    if ! $DRY_RUN; then
        gh repo create "$REPO_NAME" --private --description "Claude Code configuration backup (created by clawback)"
    else
        echo "[DRY RUN] Would create repo: $GH_USER/$REPO_NAME"
    fi
else
    echo "Repository exists: $GH_USER/$REPO_NAME"
fi

if $DRY_RUN; then
    echo "[DRY RUN] Would commit and push to $GH_USER/$REPO_NAME"
    echo "======================================================"
    exit 0
fi

# Initialize or sync git repo in backup dir
cd "$BACKUP_DIR"

if [ ! -d ".git" ]; then
    git init
    git branch -M main
    git remote add origin "https://github.com/$GH_USER/$REPO_NAME.git"
else
    # Source of truth is ~/.claude/, so reset to remote state before adding new files
    git fetch origin 2>/dev/null && git reset --hard origin/main 2>/dev/null || true

    # Re-copy and re-sanitize after reset
    cd "$SCRIPT_DIR"
    # Re-run the copy and sanitize steps (calling self without --push to avoid recursion)
    # Instead, just re-copy inline
    cp "$HOME/.claude.json" "$BACKUP_DIR/.claude.json"
    [ -f "$HOME/CLAUDE.md" ] && cp "$HOME/CLAUDE.md" "$BACKUP_DIR/CLAUDE.md"
    for dir in agents skills commands scripts; do
        [ -d "$HOME/.claude/$dir" ] && cp -r "$HOME/.claude/$dir" "$BACKUP_DIR/.claude/$dir"
    done
    for file in config.json installed_plugins.json known_marketplaces.json; do
        [ -f "$HOME/.claude/plugins/$file" ] && cp "$HOME/.claude/plugins/$file" "$BACKUP_DIR/.claude/plugins/$file"
    done
    for file in settings.json settings.local.json; do
        [ -f "$HOME/.claude/$file" ] && cp "$HOME/.claude/$file" "$BACKUP_DIR/.claude/$file"
    done

    # Re-sanitize
    RESANITIZE_FILES=()
    [ -f "$BACKUP_DIR/.claude.json" ] && RESANITIZE_FILES+=("$BACKUP_DIR/.claude.json")
    [ -f "$BACKUP_DIR/.claude/settings.json" ] && RESANITIZE_FILES+=("$BACKUP_DIR/.claude/settings.json")
    [ -f "$BACKUP_DIR/.claude/settings.local.json" ] && RESANITIZE_FILES+=("$BACKUP_DIR/.claude/settings.local.json")
    [ -f "$BACKUP_DIR/CLAUDE.md" ] && RESANITIZE_FILES+=("$BACKUP_DIR/CLAUDE.md")
    if [ ${#RESANITIZE_FILES[@]} -gt 0 ]; then
        python3 "$SCRIPT_DIR/sanitize.py" --quiet --paths "${RESANITIZE_FILES[@]}" || true
    fi

    cd "$BACKUP_DIR"
fi

# Commit message
if [ -z "$COMMIT_MSG" ]; then
    COMMIT_MSG="Update Claude Code configuration - $BACKUP_DATE"
fi

# Stage and commit
git add -A

if [ -z "$(git status --porcelain)" ]; then
    echo "No changes to commit - backup is up to date"
    echo "======================================================"
    exit 0
fi

git commit -m "$COMMIT_MSG"
git push -u origin main

echo
echo "Backup pushed to: https://github.com/$GH_USER/$REPO_NAME"
echo "======================================================"
