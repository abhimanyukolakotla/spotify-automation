#!/usr/bin/env bash
# login.sh - Spotify OAuth 2.0 Authorization Code Flow
# Usage:
#   ./login.sh            -> full login with debug output
#   ./login.sh --token-only -> prints only the access token to stdout

set -euo pipefail

TOKEN_ONLY=false
if [[ "${1:-}" == "--token-only" ]]; then
  TOKEN_ONLY=true
fi

log() {
  echo "[login.sh] $*" >&2
}

# ── Configuration ─────────────────────────────────────────────────────────────
# Set these environment variables or create a .env file alongside this script.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  set -a; source "$ENV_FILE"; set +a
fi

CLIENT_ID="${SPOTIFY_CLIENT_ID:-}"
CLIENT_SECRET="${SPOTIFY_CLIENT_SECRET:-}"
REDIRECT_PORT="${SPOTIFY_REDIRECT_PORT:-8080}"
REDIRECT_URI="http://127.0.0.1:${REDIRECT_PORT}/callback"
SCOPE="user-read-private user-read-email playlist-read-private playlist-read-collaborative user-read-playback-state user-modify-playback-state"
TOKEN_CACHE="${TOKEN_CACHE_DIR:-$SCRIPT_DIR}/.spotify_token_cache"

if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
  echo "[login.sh] ERROR: SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET must be set." >&2
  echo "[login.sh]        Create a .env file or export them before running." >&2
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
url_encode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

generate_state() {
  python3 -c "import secrets; print(secrets.token_urlsafe(16))"
}

# ── Check cached token ────────────────────────────────────────────────────────
if [[ -f "$TOKEN_CACHE" ]]; then
  CACHED_EXPIRY=$(jq -r '.expires_at // 0' "$TOKEN_CACHE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if (( NOW < CACHED_EXPIRY - 60 )); then
    log "Using cached access token (expires in $(( CACHED_EXPIRY - NOW ))s)."
    CACHED_TOKEN=$(jq -r '.access_token' "$TOKEN_CACHE")
    echo "$CACHED_TOKEN"
    exit 0
  fi

  # Try refreshing with refresh_token
  REFRESH_TOKEN=$(jq -r '.refresh_token // empty' "$TOKEN_CACHE" 2>/dev/null || true)
  if [[ -n "$REFRESH_TOKEN" ]]; then
    log "Access token expired. Attempting refresh..."
    REFRESH_RESPONSE=$(curl -s -X POST "https://accounts.spotify.com/api/token" \
      -u "${CLIENT_ID}:${CLIENT_SECRET}" \
      -d "grant_type=refresh_token&refresh_token=${REFRESH_TOKEN}")
    NEW_TOKEN=$(echo "$REFRESH_RESPONSE" | jq -r '.access_token // empty')
    if [[ -n "$NEW_TOKEN" ]]; then
      EXPIRES_IN=$(echo "$REFRESH_RESPONSE" | jq -r '.expires_in // 3600')
      NEW_EXPIRY=$(( $(date +%s) + EXPIRES_IN ))
      NEW_REFRESH=$(echo "$REFRESH_RESPONSE" | jq -r '.refresh_token // empty')
      [[ -z "$NEW_REFRESH" ]] && NEW_REFRESH="$REFRESH_TOKEN"
      jq -n \
        --arg access_token "$NEW_TOKEN" \
        --arg refresh_token "$NEW_REFRESH" \
        --argjson expires_at "$NEW_EXPIRY" \
        '{access_token: $access_token, refresh_token: $refresh_token, expires_at: $expires_at}' \
        > "$TOKEN_CACHE"
      log "Token refreshed successfully."
      echo "$NEW_TOKEN"
      exit 0
    fi
    log "Token refresh failed. Re-authorizing..."
  fi
fi

# ── Authorization Code Flow ───────────────────────────────────────────────────
STATE=$(generate_state)
ENCODED_REDIRECT=$(url_encode "$REDIRECT_URI")
ENCODED_SCOPE=$(url_encode "$SCOPE")

AUTH_URL="https://accounts.spotify.com/authorize?response_type=code&client_id=${CLIENT_ID}&scope=${ENCODED_SCOPE}&redirect_uri=${ENCODED_REDIRECT}&state=${STATE}"

log "Opening Spotify login in your browser..."
log "If it doesn't open automatically, visit:"
log "  $AUTH_URL"

# In Docker / headless environments 'open' won't exist — just print the URL
if command -v open &>/dev/null; then
  open "$AUTH_URL" 2>/dev/null || true
else
  echo "" >&2
  echo "  ┌─────────────────────────────────────────────────────┐" >&2
  echo "  │  Open this URL in your browser to log in:           │" >&2
  echo "  │                                                     │" >&2
  echo "  │  $AUTH_URL" >&2
  echo "  │                                                     │" >&2
  echo "  └─────────────────────────────────────────────────────┘" >&2
  echo "" >&2
fi

# ── Local callback server ─────────────────────────────────────────────────────
log "Waiting for Spotify callback on port ${REDIRECT_PORT}..."

CALLBACK_OUT=$(mktemp /tmp/spotify_callback_out.XXXXXX)
PY_SCRIPT=$(mktemp /tmp/spotify_server_XXXXXX).py
trap 'rm -f "$CALLBACK_OUT" "$PY_SCRIPT"' EXIT

cat > "$PY_SCRIPT" <<'PYEOF'
import http.server, urllib.parse, sys, socket

port = int(sys.argv[1])
out  = sys.argv[2]
result = {}

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        result['code']  = params.get('code',  [None])[0]
        result['state'] = params.get('state', [None])[0]
        result['error'] = params.get('error', [None])[0]
        body = b"<html><body><h2>Login successful! You can close this tab.</h2></body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        raise KeyboardInterrupt

# Bind to 0.0.0.0 so Docker port-forwarding can reach us
class ReusableTCPServer(http.server.HTTPServer):
    allow_reuse_address = True

httpd = ReusableTCPServer(("0.0.0.0", port), Handler)
print(f"[login.sh] Callback server listening on port {port}...", flush=True, file=sys.stderr)
try:
    httpd.serve_forever()
except KeyboardInterrupt:
    pass
finally:
    httpd.server_close()
    with open(out, 'w') as f:
        if result.get('code'):
            f.write(f"code={result['code']}\n")
        if result.get('state'):
            f.write(f"state={result['state']}\n")
        if result.get('error'):
            f.write(f"error={result['error']}\n")
PYEOF

python3 "$PY_SCRIPT" "$REDIRECT_PORT" "$CALLBACK_OUT" || true
CALLBACK_RAW=$(cat "$CALLBACK_OUT")

AUTH_CODE=$(echo "$CALLBACK_RAW" | grep '^code=' | cut -d= -f2- || true)
RETURNED_STATE=$(echo "$CALLBACK_RAW" | grep '^state=' | cut -d= -f2- || true)
AUTH_ERROR=$(echo "$CALLBACK_RAW" | grep '^error=' | cut -d= -f2- || true)

if [[ -n "$AUTH_ERROR" ]]; then
  echo "[login.sh] ERROR: Spotify returned an error: $AUTH_ERROR" >&2
  exit 1
fi

if [[ "$RETURNED_STATE" != "$STATE" ]]; then
  echo "[login.sh] ERROR: State mismatch (CSRF check failed)." >&2
  exit 1
fi

if [[ -z "$AUTH_CODE" ]]; then
  echo "[login.sh] ERROR: No authorization code received." >&2
  exit 1
fi

log "Authorization code received. Exchanging for access token..."

TOKEN_RESPONSE=$(curl -s -X POST "https://accounts.spotify.com/api/token" \
  -u "${CLIENT_ID}:${CLIENT_SECRET}" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "code=${AUTH_CODE}" \
  --data-urlencode "redirect_uri=${REDIRECT_URI}")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')
REFRESH_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.refresh_token // empty')
EXPIRES_IN=$(echo "$TOKEN_RESPONSE" | jq -r '.expires_in // 3600')

if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "[login.sh] ERROR: Failed to obtain access token. Response: $TOKEN_RESPONSE" >&2
  exit 1
fi

EXPIRES_AT=$(( $(date +%s) + EXPIRES_IN ))

jq -n \
  --arg access_token "$ACCESS_TOKEN" \
  --arg refresh_token "$REFRESH_TOKEN" \
  --argjson expires_at "$EXPIRES_AT" \
  '{access_token: $access_token, refresh_token: $refresh_token, expires_at: $expires_at}' \
  > "$TOKEN_CACHE"

log "Login successful! Token cached at $TOKEN_CACHE"
echo "$ACCESS_TOKEN"
