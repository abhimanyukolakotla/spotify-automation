#!/usr/bin/env bash
set -euo pipefail

echo "[get_playlist.sh] Starting playlist fetch..." >&2
echo "[get_playlist.sh] Invoking login.sh to obtain access token..." >&2

ACCESS_TOKEN=$(bash "$(dirname "$0")/login.sh" --token-only)

if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
  echo "[get_playlist.sh] ERROR: Could not obtain access token. Aborting." >&2
  exit 1
fi

echo "[get_playlist.sh] Access token received. Fetching current user profile..." >&2

USER_RESPONSE=$(curl -s --request GET \
  --url https://api.spotify.com/v1/me \
  --header "Authorization: Bearer $ACCESS_TOKEN")

USER_ID=$(echo "$USER_RESPONSE" | jq -r '.id')

if [[ -z "$USER_ID" || "$USER_ID" == "null" ]]; then
  echo "[get_playlist.sh] ERROR: Could not retrieve user ID. Response: $USER_RESPONSE" >&2
  exit 1
fi

echo "[get_playlist.sh] Retrieved user ID: $USER_ID. Fetching playlists..." >&2

PLAYLIST_RESPONSE=$(curl -s --request GET \
  --url "https://api.spotify.com/v1/users/$USER_ID/playlists" \
  --header "Authorization: Bearer $ACCESS_TOKEN")

if [[ -z "$PLAYLIST_RESPONSE" ]]; then
  echo "[get_playlist.sh] ERROR: No response received from Spotify API." >&2
  exit 1
fi

echo "[get_playlist.sh] Playlist data successfully retrieved." >&2

# Pretty-print playlist names and IDs
echo "$PLAYLIST_RESPONSE" | jq -r '.items[] | "\(.name)\t\(.id)"'