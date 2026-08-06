#!/usr/bin/env bash
# ============================================================================
# Claude Code commit message post-check hook
# Validates that the most recent commit follows conventional commits format.
# Runs AFTER `git commit` succeeds — reports issues but does not block.
# ============================================================================
set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

COMMIT_MSG=$(git log -1 --format=%B 2>/dev/null || true)
if [ -z "$COMMIT_MSG" ]; then
  echo -e "${YELLOW}⚠ No commits found — skipping check${NC}"
  exit 0
fi

SUBJECT=$(echo "$COMMIT_MSG" | head -1)
BODY=$(echo "$COMMIT_MSG" | tail -n +2)
ISSUES=0
WARNINGS=0

# ---- Valid types ----
TYPES="feat|fix|docs|style|refactor|test|chore|perf|ci|build|revert"

# ---- 1. Conventional commits pattern ----
if ! echo "$SUBJECT" | grep -qE "^($TYPES)(\([^)]+\))?: .+"; then
  echo -e "${RED}✗ Subject must follow: <type>(<scope>): <description>${NC}"
  echo "  Types: feat, fix, docs, style, refactor, test, chore, perf, ci, build, revert"
  echo "  Examples: feat(ox-zotero): add tag sync on update"
  echo "            fix: correct json-array-type for Emacs 27+ vector default"
  ISSUES=$((ISSUES + 1))
fi

# ---- 2. Subject length (≤ 50 chars guideline) ----
LEN=$(echo -n "$SUBJECT" | wc -c | tr -d ' ')
if [ "$LEN" -gt 72 ]; then
  echo -e "${RED}✗ Subject line is ${LEN} chars (hard limit: 72)${NC}"
  ISSUES=$((ISSUES + 1))
elif [ "$LEN" -gt 50 ]; then
  echo -e "${YELLOW}⚠ Subject line is ${LEN} chars (guideline: ≤ 50)${NC}"
  WARNINGS=$((WARNINGS + 1))
fi

# ---- 3. No trailing punctuation ----
if echo "$SUBJECT" | grep -qE '[.!?,;:]$'; then
  echo -e "${RED}✗ Subject should not end with punctuation (.!?,;:)${NC}"
  ISSUES=$((ISSUES + 1))
fi

# ---- 4. Imperative mood heuristics (common non-imperative endings) ----
if echo "$SUBJECT" | grep -qiE '\b(added|fixed|removed|updated|changed|renamed|refactored|rewrote|made|did|was|were)\b'; then
  echo -e "${YELLOW}⚠ Subject may not be imperative mood — prefer 'Add' over 'Added', 'Fix' over 'Fixed'${NC}"
  WARNINGS=$((WARNINGS + 1))
fi

# ---- 5. Body/Subject separator (only if body exists) ----
BODY_TRIMMED=$(echo "$BODY" | sed '/^$/d')
if [ -n "$BODY_TRIMMED" ]; then
  if ! echo "$BODY" | head -1 | grep -qE '^$'; then
    echo -e "${RED}✗ Separate subject from body with a blank line${NC}"
    ISSUES=$((ISSUES + 1))
  fi
  # Body line length ≤ 72
  LONG_LINES=$(echo "$BODY" | grep -cE '^.{73,}$' || true)
  if [ "$LONG_LINES" -gt 0 ]; then
    echo -e "${RED}✗ ${LONG_LINES} body line(s) exceed 72 characters${NC}"
    ISSUES=$((ISSUES + 1))
  fi
fi

# ---- Summary ----
echo ""
if [ "$ISSUES" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
  echo -e "${GREEN}✅ Commit message looks good${NC}"
else
  if [ "$ISSUES" -gt 0 ]; then
    echo -e "${RED}${ISSUES} error(s) found — consider: git commit --amend${NC}"
  fi
  if [ "$WARNINGS" -gt 0 ]; then
    echo -e "${YELLOW}${WARNINGS} warning(s) noted${NC}"
  fi
fi
