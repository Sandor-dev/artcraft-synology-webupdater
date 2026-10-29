#!/bin/bash
#
# ArtCraft Web Apps Installer for Synology NAS
# Creates the folder structure, downloads the latest web builds of selected ArtCraft apps,
# generates a docker-compose.yml (nginx), and optionally starts the stack.
#
# Usage:
#   1. Edit the CONFIGURATION section below
#   2. chmod +x install-artcraft.sh
#   3. ./install-artcraft.sh
#
# Requirements: curl, and either unzip or python3/python
# Docker Compose is optional (only needed if you want the script to start the stack)

set -euo pipefail

# ======================== CONFIGURATION ========================
# Change these values before running

# Where to install ArtCraft (the public folder will be created inside)
INSTALL_DIR="/volume2/docker/artcraft"

# Host port that will be mapped to the nginx container
HOST_PORT=4100

# Your NAS local IP (used in NGINX_HOST environment variable)
# Leave empty to auto-detect (best effort)
NAS_IP=""

# Which apps to install (space-separated)
# Available: photocraft vectorcraft filmcraft lightcraft pdfcraft effectcraft
#            designcraft figcraft wordcraft soundcraft deckcraft cadcraft gridcraft
APPS_TO_INSTALL="photocraft pdfcraft lightcraft vectorcraft"

# Set to 1 if you want the script to run "docker compose up -d" at the end
START_DOCKER=0

# Temporary download location
TEMP_BASE="/tmp/artcraft-install"
# ===============================================================

ORG="storytold"
PUBLIC_DIR="$INSTALL_DIR/public"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { log "ERROR: $*"; exit 1; }

extract_zip() {
  local zip_file="$1"
  local dest="$2"

  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$zip_file" -d "$dest" && return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import zipfile, sys
with zipfile.ZipFile(sys.argv[1]) as zf:
    zf.extractall(sys.argv[2])
' "$zip_file" "$dest" && return 0
  elif command -v python >/dev/null 2>&1; then
    python -c '
import zipfile, sys
with zipfile.ZipFile(sys.argv[1]) as zf:
    zf.extractall(sys.argv[2])
' "$zip_file" "$dest" && return 0
  fi

  log "Neither unzip nor python is available!"
  return 1
}

get_web_zip_url() {
  local app="$1"
  local api="https://api.github.com/repos/${ORG}/${app}/releases/latest"
  local json
  json=$(curl -fsSL --retry 3 --retry-delay 2 "$api") || return 1

  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r '.assets[] | select(.name | test("-web-.*\\.zip$")) | .browser_download_url' | head -1
  else
    echo "$json" | grep -oE '"browser_download_url":\s*"[^"]*-web-[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/'
  fi
}

detect_ip() {
  if [[ -n "$NAS_IP" ]]; then
    echo "$NAS_IP"
    return
  fi
  # Best-effort local IP detection
  ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1 || \
  hostname -I 2>/dev/null | awk '{print $1}' || \
  echo "YOUR_NAS_IP"
}

install_app() {
  local app="$1"
  local target_dir="$PUBLIC_DIR/$app"
  local tmp_dir="$TEMP_BASE/$app"
  local zip_file="$tmp_dir/${app}-web.zip"

  log "=== Installing $app ==="

  local zip_url
  zip_url=$(get_web_zip_url "$app") || { log "  Failed to get URL for $app, skipping."; return 0; }
  if [[ -z "$zip_url" || "$zip_url" == "null" ]]; then
    log "  No web zip found for $app. Skipping."
    return 0
  fi

  log "  Downloading: $zip_url"
  mkdir -p "$tmp_dir"
  curl -fL --retry 3 -o "$zip_file" "$zip_url" || { log "  Download failed for $app"; return 1; }

  mkdir -p "$target_dir"
  extract_zip "$zip_file" "$tmp_dir" || { log "  Extraction failed for $app"; return 1; }

  local inner
  inner=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d ! -name ".*" | head -1)
  if [[ -z "$inner" ]]; then
    log "  Could not find inner folder for $app"
    return 1
  fi

  cp -a "$inner"/. "$target_dir/"
  rm -rf "$tmp_dir"
  log "  $app installed to $target_dir"
}

# --- Main ---
log "ArtCraft Installer starting..."
log "Install directory: $INSTALL_DIR"
log "Public directory:  $PUBLIC_DIR"
log "Host port:         $HOST_PORT"
log "Apps:              $APPS_TO_INSTALL"

mkdir -p "$PUBLIC_DIR"
mkdir -p "$TEMP_BASE"

# Create a simple index.html that lists the apps
cat > "$PUBLIC_DIR/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>ArtCraft Apps</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 800px; margin: 2rem auto; padding: 0 1rem; }
    h1 { color: #333; }
    ul { list-style: none; padding: 0; }
    li { margin: 0.5rem 0; }
    a { display: inline-block; padding: 0.5rem 1rem; background: #0066cc; color: white; text-decoration: none; border-radius: 4px; }
    a:hover { background: #0052a3; }
  </style>
</head>
<body>
  <h1>ArtCraft Apps</h1>
  <ul>
EOF

for app in $APPS_TO_INSTALL; do
  install_app "$app"
  # Add link to index
  echo "    <li><a href=\"$app/\">$app</a></li>" >> "$PUBLIC_DIR/index.html"
done

cat >> "$PUBLIC_DIR/index.html" << 'EOF'
  </ul>
</body>
</html>
EOF

log "Created index.html with links to installed apps."

# Generate docker-compose.yml
DETECTED_IP=$(detect_ip)
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

cat > "$COMPOSE_FILE" << EOF
services:
  artcraft:
    image: nginx
    container_name: ArtCraft
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    ports:
      - "${HOST_PORT}:80"
    environment:
      NGINX_HOST: ${DETECTED_IP}:${HOST_PORT}
      NGINX_PORT: 80
    volumes:
      - ${PUBLIC_DIR}:/usr/share/nginx/html:ro
    restart: on-failure:5
EOF

log "Created docker-compose.yml at $COMPOSE_FILE"
log "Access the apps at: http://${DETECTED_IP}:${HOST_PORT}/"

if [[ $START_DOCKER -eq 1 ]]; then
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Starting Docker stack..."
    (cd "$INSTALL_DIR" && docker compose up -d)
    log "Stack started. Check with: docker compose -f $COMPOSE_FILE ps"
  else
    log "Docker Compose not found or not available. Start the stack manually:"
    log "  cd $INSTALL_DIR && docker compose up -d"
  fi
else
  log "To start the stack later, run:"
  log "  cd $INSTALL_DIR && docker compose up -d"
fi

log "Installation finished."
log "You can now use update-artcraft.sh to keep the apps up to date."
