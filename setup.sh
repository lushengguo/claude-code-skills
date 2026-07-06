#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ln -sf "${SCRIPT_DIR}/skills" ~/.claude/skills
ln -sf "${SCRIPT_DIR}/settings.json" ~/.claude/settings.json
echo "Done. ~/.claude/skills -> ${SCRIPT_DIR}/skills"
echo "      ~/.claude/settings.json -> ${SCRIPT_DIR}/settings.json"
