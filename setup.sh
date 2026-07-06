#!/bin/bash
set -e
echo "Setting up Claude Code sync from ~/.claude-config ..."
ln -sf ~/.claude-config/skills ~/.claude/skills
echo "  ~/.claude/skills -> ~/.claude-config/skills"
ln -sf ~/.claude-config/settings.json ~/.claude/settings.json
echo "  ~/.claude/settings.json -> ~/.claude-config/settings.json"
