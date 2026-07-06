#!/bin/bash
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
git add -A
git commit -m "$(date)" || true
git push
