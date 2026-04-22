#!/usr/bin/env bash
# play_playlist.sh - Fetch playlists and play the selected one on the active Spotify device
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Get access token ──────────────────────────────────────────────────────────
echo "[play_playlist.sh] Obtaining access token..." >&2
ACCESS_TOKEN=$(bash "$SCRIPT_DIR/login.sh" --token-only)

if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
  echo "[play_playlist.sh] ERROR: Could not obtain access token." >&2
  exit 1
fi

# ── Fetch playlists (up to 50) ────────────────────────────────────────────────
echo "[play_playlist.sh] Fetching your playlists..." >&2

USER_RESPONSE=$(curl -s --request GET \
  --url https://api.spotify.com/v1/me \
  --header "Authorization: Bearer $ACCESS_TOKEN")
USER_ID=$(echo "$USER_RESPONSE" | jq -r '.id')

PLAYLIST_RESPONSE=$(curl -s --request GET \
  --url "https://api.spotify.com/v1/users/$USER_ID/playlists?limit=50" \
  --header "Authorization: Bearer $ACCESS_TOKEN")

# Build parallel arrays: names and URIs (mapfile-free for bash 3.2 compat)
NAMES=()
URIS=()
while IFS= read -r line; do NAMES+=("$line"); done < <(echo "$PLAYLIST_RESPONSE" | jq -r '.items[].name')
while IFS= read -r line; do URIS+=("$line");  done < <(echo "$PLAYLIST_RESPONSE" | jq -r '.items[].uri')

if [[ ${#NAMES[@]} -eq 0 ]]; then
  echo "[play_playlist.sh] ERROR: No playlists found." >&2
  exit 1
fi

# ── Interactive selection ─────────────────────────────────────────────────────
echo ""
echo "  Your Playlists"
echo "  ──────────────"
for i in "${!NAMES[@]}"; do
  printf "  %3d) %s\n" $(( i + 1 )) "${NAMES[$i]}"
done
echo ""

CHOICE=""
while true; do
  printf "  Select a playlist [1-${#NAMES[@]}] (auto-selects 1 in 10s): " >&2
  CHOICE=$(python3 -c "
import sys, select
ready = select.select([sys.stdin], [], [], 10)[0]
if ready:
    print(sys.stdin.readline().strip())
else:
    print('', file=sys.stderr)
    print('  No selection made — defaulting to #1.', file=sys.stderr)
    print('1')
" 2>/dev/tty || echo "1")
  if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#NAMES[@]} )); then
    break
  fi
  echo "  Invalid choice. Please enter a number between 1 and ${#NAMES[@]}." >&2
done

SELECTED_NAME="${NAMES[$((CHOICE - 1))]}"
SELECTED_URI="${URIS[$((CHOICE - 1))]}"

echo ""
echo "[play_playlist.sh] Selected: \"$SELECTED_NAME\" ($SELECTED_URI)" >&2

# ── Get available devices ─────────────────────────────────────────────────────
DEVICES_RESPONSE=$(curl -s --request GET \
  --url "https://api.spotify.com/v1/me/player/devices" \
  --header "Authorization: Bearer $ACCESS_TOKEN")

DEVICE_COUNT=$(echo "$DEVICES_RESPONSE" | jq '(.devices // []) | length')

if [[ "$DEVICE_COUNT" -eq 0 ]]; then
  echo "[play_playlist.sh] ERROR: No online Spotify devices found." >&2
  echo "[play_playlist.sh]        Open Spotify on any device and try again." >&2
  exit 1
fi

if [[ "$DEVICE_COUNT" -eq 1 ]]; then
  DEVICE_ID=$(echo "$DEVICES_RESPONSE" | jq -r '.devices[0].id')
  DEVICE_NAME=$(echo "$DEVICES_RESPONSE" | jq -r '.devices[0].name')
  echo "[play_playlist.sh] One device found, using: \"$DEVICE_NAME\"" >&2
else
  # Multiple devices — let the user pick
  DEV_NAMES=()
  DEV_IDS=()
  while IFS= read -r line; do DEV_NAMES+=("$line"); done < <(echo "$DEVICES_RESPONSE" | jq -r '.devices[].name')
  while IFS= read -r line; do DEV_IDS+=("$line");   done < <(echo "$DEVICES_RESPONSE" | jq -r '.devices[].id')

  echo ""
  echo "  Available Devices"
  echo "  ─────────────────"
  for i in "${!DEV_NAMES[@]}"; do
    ACTIVE_MARKER=$(echo "$DEVICES_RESPONSE" | jq -r --argjson idx "$i" '.devices[$idx].is_active | if . then " ◀ active" else "" end')
    printf "  %3d) %s%s\n" $(( i + 1 )) "${DEV_NAMES[$i]}" "$ACTIVE_MARKER"
  done
  echo ""

  DEV_CHOICE=""
  while true; do
    printf "  Select a device [1-${#DEV_NAMES[@]}] (auto-selects 1 in 10s): " >&2
    DEV_CHOICE=$(python3 -c "
import sys, select
ready = select.select([sys.stdin], [], [], 10)[0]
if ready:
    print(sys.stdin.readline().strip())
else:
    print('', file=sys.stderr)
    print('  No selection made — defaulting to #1.', file=sys.stderr)
    print('1')
" 2>/dev/tty || echo "1")
    if [[ "$DEV_CHOICE" =~ ^[0-9]+$ ]] && (( DEV_CHOICE >= 1 && DEV_CHOICE <= ${#DEV_NAMES[@]} )); then
      break
    fi
    echo "  Invalid choice. Please enter a number between 1 and ${#DEV_NAMES[@]}." >&2
  done

  DEVICE_ID="${DEV_IDS[$((DEV_CHOICE - 1))]}"
  DEVICE_NAME="${DEV_NAMES[$((DEV_CHOICE - 1))]}"
  echo ""
fi

echo "[play_playlist.sh] Playing on device: \"$DEVICE_NAME\"" >&2

# ── Start playback ────────────────────────────────────────────────────────────
PLAY_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --request PUT \
  --url "https://api.spotify.com/v1/me/player/play?device_id=${DEVICE_ID}" \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"context_uri\": \"${SELECTED_URI}\"}")

if [[ "$PLAY_RESPONSE" == "204" || "$PLAY_RESPONSE" == "200" ]]; then
  echo "[play_playlist.sh] ▶  Now playing \"$SELECTED_NAME\"!" >&2
else
  echo "[play_playlist.sh] ERROR: Playback request failed (HTTP $PLAY_RESPONSE)." >&2
  echo "[play_playlist.sh]        Make sure Spotify is open and you have Spotify Premium." >&2
  exit 1
fi
