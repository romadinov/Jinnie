#!/bin/bash
# Raises the build number (CURRENT_PROJECT_VERSION) for the next release; optionally sets the version.
#   scripts/bump-build.sh          → build N+1
#   scripts/bump-build.sh 0.2.0    → version 0.2.0, build N+1
# TestFlight and Sparkle both need a higher build number for every release.
set -euo pipefail
cd "$(dirname "$0")/.."
build=$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml)
next=$((build + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION: \"$build\"/CURRENT_PROJECT_VERSION: \"$next\"/" project.yml
if [ -n "${1:-}" ]; then sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$1\"/" project.yml; fi
echo "Version $(sed -n 's/.*MARKETING_VERSION: "\([^"]*\)".*/\1/p' project.yml) ($next)"
