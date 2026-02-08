#!/usr/bin/env bash
set -euo pipefail

# clawback - Claude Code Configuration Restore
# https://github.com/YOUR_USERNAME/clawback

REPO_NAME="${CLAUDE_BACKUP_REPO:-claude-setup}"
RESTORE_DIR=""
DRY_RUN=false
FORCE=false

usage() {
    cat <<'EOF'
Usage: restore.sh [OPTIONS]

Restore Claude Code configuration from a GitHub backup.

Options:
  --repo NAME         Source repo name (default: claude-setup, env: CLAUDE_BACKUP_REPO)
  --from PATH         Restore from local directory instead of cloning from GitHub
  --dry-run           Show what would be restored without copying
  --force             Overwrite existing files without confirmation
  -h, --help          Show this help

Examples:
  ./restore.sh                        # Clone backup from GitHub and restore
  ./restore.sh --dry-run              # Preview what would be restored
  ./restore.sh --from ~/.claude-backup  # Restore from local backup dir
  ./restore.sh --force                # Overwrite without prompts
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO_NAME="$2"; shift 2 ;;
        --from) RESTORE_DIR="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --force) FORCE=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

echo "======================================================"
echo "clawback - Claude Code Configuration Restore"
echo "======================================================"
if $DRY_RUN; then
    echo "[DRY RUN MODE - No changes will be made]"
fi
echo

# If no local dir specified, clone from GitHub
if [ -z "$RESTORE_DIR" ]; then
    command -v gh >/dev/null 2>&1 || { echo "Error: gh (GitHub CLI) required. Install: https://cli.github.com"; exit 1; }

    if ! gh auth status >/dev/null 2>&1; then
        echo "Error: GitHub CLI not authenticated. Run: gh auth login"
        exit 1
    fi

    GH_USER=$(gh api user -q .login)
    echo "GitHub user: $GH_USER"

    if ! gh repo view "$GH_USER/$REPO_NAME" >/dev/null 2>&1; then
        echo "Error: Repository $GH_USER/$REPO_NAME not found."
        echo "Run backup.sh --push first to create a backup."
        exit 1
    fi

    RESTORE_DIR=$(mktemp -d)
    trap "rm -rf '$RESTORE_DIR'" EXIT

    echo "Cloning $GH_USER/$REPO_NAME..."
    if ! $DRY_RUN; then
        gh repo clone "$GH_USER/$REPO_NAME" "$RESTORE_DIR" -- --depth 1 2>/dev/null
    else
        echo "[DRY RUN] Would clone $GH_USER/$REPO_NAME"
    fi
fi

# Verify source directory
if ! $DRY_RUN && [ ! -f "$RESTORE_DIR/.claude.json" ]; then
    echo "Error: $RESTORE_DIR/.claude.json not found"
    echo "This doesn't look like a valid Claude Code backup."
    exit 1
fi

# Confirm overwrite
confirm_overwrite() {
    local dest="$1"
    if [ -f "$dest" ] && ! $FORCE && ! $DRY_RUN; then
        echo -n "  Overwrite $dest? [y/N] "
        read -r answer
        case "$answer" in
            [yY]|[yY][eE][sS]) return 0 ;;
            *) echo "  Skipped."; return 1 ;;
        esac
    fi
    return 0
}

# Restore a file
restore_file() {
    local src="$1"
    local dest="$2"
    local label="$3"

    if [ ! -f "$src" ]; then
        return 1
    fi

    if $DRY_RUN; then
        if [ -f "$dest" ]; then
            echo "  ~ $label (would overwrite)"
        else
            echo "  + $label (new)"
        fi
        return 0
    fi

    if confirm_overwrite "$dest"; then
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
        echo "  + $label"
        return 0
    fi
    return 1
}

# Restore a directory
restore_dir() {
    local src="$1"
    local dest="$2"
    local label="$3"

    if [ ! -d "$src" ]; then
        return 1
    fi

    if $DRY_RUN; then
        local count
        count=$(find "$src" -type f | wc -l | tr -d ' ')
        echo "  + $label/ ($count files)"
        return 0
    fi

    if [ -d "$dest" ] && ! $FORCE; then
        echo -n "  Overwrite $label/? [y/N] "
        read -r answer
        case "$answer" in
            [yY]|[yY][eE][sS]) ;;
            *) echo "  Skipped."; return 1 ;;
        esac
    fi

    mkdir -p "$(dirname "$dest")"
    cp -r "$src" "$dest"
    echo "  + $label/"
    return 0
}

echo "Restoring configuration files..."

# Core files
restore_file "$RESTORE_DIR/.claude.json" "$HOME/.claude.json" "~/.claude.json" || true
restore_file "$RESTORE_DIR/CLAUDE.md" "$HOME/CLAUDE.md" "~/CLAUDE.md" || true

# .claude directories
for dir in agents skills commands scripts; do
    restore_dir "$RESTORE_DIR/.claude/$dir" "$HOME/.claude/$dir" "~/.claude/$dir" || true
done

# Plugin config files
mkdir -p "$HOME/.claude/plugins" 2>/dev/null || true
for file in config.json installed_plugins.json known_marketplaces.json; do
    restore_file "$RESTORE_DIR/.claude/plugins/$file" "$HOME/.claude/plugins/$file" "~/.claude/plugins/$file" || true
done

# Settings files
for file in settings.json settings.local.json; do
    restore_file "$RESTORE_DIR/.claude/$file" "$HOME/.claude/$file" "~/.claude/$file" || true
done

# Find placeholders that need replacement
echo
echo "======================================================"
echo "Restore complete!"
echo

if ! $DRY_RUN && [ -f "$HOME/.claude.json" ]; then
    PLACEHOLDERS=$(grep -c "PLACEHOLDER" "$HOME/.claude.json" 2>/dev/null || echo "0")
    if [ "$PLACEHOLDERS" -gt 0 ]; then
        echo "ACTION REQUIRED: $PLACEHOLDERS placeholder(s) need real credentials."
        echo
        echo "Edit ~/.claude.json and replace PLACEHOLDER values:"
        echo
        grep -n "PLACEHOLDER" "$HOME/.claude.json" | while IFS= read -r line; do
            echo "  $line"
        done
        echo
        echo "Then restart Claude Code to apply changes."
    else
        echo "No placeholders found - configuration is ready to use."
    fi
fi

echo "======================================================"
