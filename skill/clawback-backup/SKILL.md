---
name: clawback-backup
description: Backup Claude Code configuration to GitHub using clawback
disable-model-invocation: true
allowed-tools: Bash
---

Run the clawback backup tool to backup Claude Code configuration.

Arguments: $ARGUMENTS

Steps:
1. Find clawback by checking CLAWBACK_DIR env var. If not set, error with:
   "Set CLAWBACK_DIR to your clawback install path, e.g.: export CLAWBACK_DIR=~/clawback"
2. Run $CLAWBACK_DIR/backup.sh with any provided arguments
3. Report results to user (files backed up, sanitization summary, push status)

If --push is not in arguments, remind user they can add --push to commit and push.
