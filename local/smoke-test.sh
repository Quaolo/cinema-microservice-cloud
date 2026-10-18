#!/usr/bin/env bash
# Smoke test for the local stack: calls each public endpoint through the API gateway.
# Usage: bash local/smoke-test.sh [gateway-url]   (default http://localhost:8080)
set -u

GATEWAY="${1:-http://localhost:8080}"
failures=0

check() {
  local path="$1" expected="$2"
  local code
  code=$(curl -s -m 30 -o /dev/null -w '%{http_code}' "$GATEWAY$path")
  if [ "$code" = "$expected" ]; then
    echo "OK   $code $path"
  else
    echo "FAIL $code $path (expected $expected)"
    failures=$((failures + 1))
  fi
}

check /health 200
check /movies 200
check /movies/premieres 200
check /movies/1 200
check /cinemas 200
check "/cinemas?cityId=catania" 200
check /payments 200
check /notifications 200

echo
if [ "$failures" -eq 0 ]; then
  echo "All checks passed"
else
  echo "$failures check(s) failed"
  exit 1
fi
