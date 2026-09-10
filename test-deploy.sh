#!/usr/bin/env bash
set -uo pipefail

PASS=0
FAIL=0
SKIP=0
BASE_URL="${BASE_URL:-http://localhost:3000/api}"
LOG_FILE="${LOG_FILE:-test-results.log}"
HAS_NODE=false

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
skip() { SKIP=$((SKIP + 1)); echo "  SKIP: $1"; }

exec > >(tee "$LOG_FILE") 2>&1

echo "Deploy verification — $(date)"
echo ""

# -------------------------------------------------------
echo "=== Phase 1: Node.js availability ==="

if command -v node >/dev/null 2>&1; then
  HAS_NODE=true
  pass "Node.js found: $(node --version)"
else
  skip "Node.js not on PATH — phases 2-3 will be skipped"
fi

# -------------------------------------------------------
echo ""
echo "=== Phase 2: Dependency check (requires Node) ==="

if [ "$HAS_NODE" = true ]; then
  if node -e "require('express-rate-limit')" 2>/dev/null; then
    pass "express-rate-limit is importable"
  else
    fail "express-rate-limit is not installed — run npm install"
  fi
else
  skip "Cannot check — Node.js unavailable"
fi

# -------------------------------------------------------
echo ""
echo "=== Phase 3: Syntax check (requires Node) ==="

if [ "$HAS_NODE" = true ]; then
  for f in app.js routes/*.js routes/api/*.js config/*.js models/*.js; do
    if [ -f "$f" ]; then
      if node -c "$f" 2>/dev/null; then
        pass "$f syntax OK"
      else
        fail "$f has syntax errors"
      fi
    fi
  done
else
  skip "Cannot check — Node.js unavailable"
fi

# -------------------------------------------------------
echo ""
echo "=== Phase 4: Rate limit module structure (requires Node) ==="

if [ "$HAS_NODE" = true ]; then
  node -e "
    var m = require('./routes/rateLimit');
    var ok = typeof m.strict === 'function'
          && typeof m.write  === 'function'
          && typeof m.read   === 'function';
    if (!ok) { process.exit(1); }
  " 2>/dev/null \
    && pass "rateLimit exports strict, write, read as functions" \
    || fail "rateLimit module missing expected exports"
else
  skip "Cannot check — Node.js unavailable"
fi

# -------------------------------------------------------
echo ""
echo "=== Phase 5: Rate limit wiring check ==="

check_limiter() {
  local file="$1" pattern="$2" label="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label"
  fi
}

# users.js — route path comes before limit.* on the line
check_limiter routes/api/users.js    "users/login.*limit\.strict"    "login route has strict limiter"
check_limiter routes/api/users.js    "post.*/users'.*limit\.strict"  "register route has strict limiter"
check_limiter routes/api/users.js    "get.*/user'.*limit\.read"      "get-user route has read limiter"
check_limiter routes/api/users.js    "put.*/user'.*limit\.write"     "update-user route has write limiter"

# articles.js
check_limiter routes/api/articles.js "get.*'/'.*limit\.read"                   "list-articles route has read limiter"
check_limiter routes/api/articles.js "get.*/feed.*limit\.read"                 "feed route has read limiter"
check_limiter routes/api/articles.js "post.*'/'.*limit\.write"                 "create-article route has write limiter"
check_limiter routes/api/articles.js "put.*/:article'.*limit\.write"           "update-article route has write limiter"
check_limiter routes/api/articles.js "delete.*/:article'.*limit\.write"        "delete-article route has write limiter"
check_limiter routes/api/articles.js "/:article/favorite.*limit\.write"        "favorite route has write limiter"
check_limiter routes/api/articles.js "get.*/:article/comments.*limit\.read"    "list-comments route has read limiter"
check_limiter routes/api/articles.js "post.*/:article/comments.*limit\.write"  "create-comment route has write limiter"
check_limiter routes/api/articles.js "delete.*/:article/comments.*limit\.write" "delete-comment route has write limiter"
check_limiter routes/api/articles.js "get.*/:article'.*limit\.read"            "get-article route has read limiter"

# profiles.js
check_limiter routes/api/profiles.js "get.*/:username'.*limit\.read"           "get-profile route has read limiter"
check_limiter routes/api/profiles.js "post.*/:username/follow.*limit\.write"   "follow route has write limiter"
check_limiter routes/api/profiles.js "delete.*/:username/follow.*limit\.write" "unfollow route has write limiter"

# tags.js
check_limiter routes/api/tags.js     "limit\.read"                             "tags route has read limiter"

# rateLimit.js structure (file-level checks, no Node needed)
check_limiter routes/rateLimit.js "require.*express-rate-limit"  "rateLimit.js imports express-rate-limit"
check_limiter routes/rateLimit.js "module\.exports"              "rateLimit.js has module.exports"

# Each route file imports rateLimit
check_limiter routes/api/users.js    "require.*rateLimit"  "users.js imports rateLimit"
check_limiter routes/api/articles.js "require.*rateLimit"  "articles.js imports rateLimit"
check_limiter routes/api/profiles.js "require.*rateLimit"  "profiles.js imports rateLimit"
check_limiter routes/api/tags.js     "require.*rateLimit"  "tags.js imports rateLimit"

# package.json lists the dependency
check_limiter package.json "express-rate-limit"  "package.json lists express-rate-limit"

# -------------------------------------------------------
echo ""
echo "=== Phase 6: Smoke test (requires running server at $BASE_URL) ==="

if ! curl -sf "$BASE_URL/tags" >/dev/null 2>&1; then
  skip "Server not reachable at $BASE_URL — start with: npm run dev"
else
  headers=$(curl -sI "$BASE_URL/tags" 2>/dev/null)

  if echo "$headers" | grep -qi "ratelimit"; then
    pass "Rate limit headers present on GET /tags"
  else
    fail "No rate limit headers on GET /tags"
  fi

  if echo "$headers" | grep -qi "200\|OK"; then
    pass "GET /tags returns 200"
  else
    fail "GET /tags did not return 200"
  fi

  login_status=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST -H "Content-Type: application/json" \
    -d '{"user":{}}' "$BASE_URL/users/login")

  if [ "$login_status" = "422" ]; then
    pass "POST /users/login returns 422 for empty credentials (route works)"
  elif [ "$login_status" = "429" ]; then
    pass "POST /users/login returns 429 (strict rate limit active)"
  else
    fail "POST /users/login returned unexpected status $login_status"
  fi

  login_headers=$(curl -sI -X POST -H "Content-Type: application/json" \
    -d '{"user":{}}' "$BASE_URL/users/login" 2>/dev/null)

  if echo "$login_headers" | grep -qi "ratelimit"; then
    pass "Rate limit headers present on POST /users/login"
  else
    fail "No rate limit headers on POST /users/login"
  fi
fi

# -------------------------------------------------------
echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Log written to: $LOG_FILE"
if [ "$FAIL" -eq 0 ]; then
  echo "All checks passed."
  exit 0
else
  echo "Some checks failed — review output above."
  exit 1
fi
