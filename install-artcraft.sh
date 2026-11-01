#!/bin/bash
#
# ArtCraft Web Apps Installer for Synology NAS
# Creates the folder structure, downloads the latest web builds of ArtCraft apps,
# generates a nice index.html + docker-compose.yml (nginx), and optionally starts the stack.
#
# Usage:
#   1. Edit the CONFIGURATION section below
#   2. chmod +x install-artcraft.sh
#   3. ./install-artcraft.sh
#
# Requirements: curl, and either unzip or python3/python

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
# Set to "all" to install every known app
APPS_TO_INSTALL="all"

# Set to 1 if you want the script to run "docker compose up -d" at the end
START_DOCKER=1

# Temporary download location
TEMP_BASE="/tmp/artcraft-install"
# ===============================================================

ORG="storytold"
PUBLIC_DIR="$INSTALL_DIR/public"

ALL_APPS=(
  photocraft
  vectorcraft
  filmcraft
  lightcraft
  pdfcraft
  effectcraft
  designcraft
  figcraft
  wordcraft
  soundcraft
  deckcraft
  cadcraft
  gridcraft
)

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

# Resolve apps list
if [[ "$APPS_TO_INSTALL" == "all" ]]; then
  APPS=("${ALL_APPS[@]}")
else
  read -ra APPS <<< "$APPS_TO_INSTALL"
fi
log "Apps to install: ${APPS[*]}"

mkdir -p "$PUBLIC_DIR"
mkdir -p "$TEMP_BASE"
mkdir -p "$PUBLIC_DIR/icons"

# Download project logo
LOGO_URL="https://raw.githubusercontent.com/Sandor-dev/artcraft-synology-webupdater/main/project.png"
log "Downloading project logo..."
if curl -fsSL -o "$PUBLIC_DIR/icons/grok.png" "$LOGO_URL"; then
  log "  Logo saved to $PUBLIC_DIR/icons/grok.png"
else
  log "  Warning: could not download logo (will continue without it)"
fi

# Download official app icons
download_app_icons() {
  log "Downloading app icons..."
  local icon_base="https://raw.githubusercontent.com/storytold"
  for app in "${ALL_APPS[@]}"; do
    local icon_url="${icon_base}/${app}/main/assets/app-icon/${app}-1024.png"
    local dest="$PUBLIC_DIR/icons/${app}.png"
    if curl -fsSL -o "$dest" "$icon_url" 2>/dev/null; then
      log "  ${app}.png"
    else
      # Fallback: try hicolor 256
      icon_url="${icon_base}/${app}/main/assets/app-icon/hicolor/256x256/apps/ai.storyteller.${app}.png"
      if curl -fsSL -o "$dest" "$icon_url" 2>/dev/null; then
        log "  ${app}.png (256)"
      else
        log "  Warning: no icon for $app"
      fi
    fi
  done
}
download_app_icons

# Create the nice index.html
cat > "$PUBLIC_DIR/index.html" << 'INDEXEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ArtCraft Apps</title>
  <style>
    :root {
      --bg: #0f1117;
      --card: #1a1d26;
      --card-hover: #222632;
      --text: #f0f2f5;
      --muted: #9aa0ab;
      --accent: #5b9cff;
      --border: #2a2f3c;
      --radius: 16px;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: var(--bg);
      color: var(--text);
      line-height: 1.5;
    }
    .container {
      max-width: 1140px;
      margin: 0 auto;
      padding: 2.5rem 1.25rem 4rem;
    }
    header {
      text-align: center;
      margin-bottom: 2.8rem;
    }
    .logo {
      display: block;
      margin: 0 auto 18px auto;
      max-width: 72px;
      width: 72px;
      height: 72px;
      border-radius: 16px;
    }
    h1 {
      font-size: 2.2rem;
      font-weight: 650;
      margin: 0 0 0.35rem;
      letter-spacing: -0.025em;
    }
    .subtitle {
      color: var(--muted);
      font-size: 1.05rem;
      margin: 0;
    }
    .base-url {
      margin-top: 1rem;
      font-size: 0.88rem;
      color: var(--muted);
      word-break: break-all;
    }
    .base-url strong {
      color: var(--text);
      font-weight: 550;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
      gap: 1.1rem;
    }
    .card {
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: var(--radius);
      padding: 1.15rem 1.25rem;
      text-decoration: none;
      color: inherit;
      transition: border-color 0.18s, transform 0.18s, background 0.18s;
      display: flex;
      align-items: center;
      gap: 1rem;
    }
    .card:hover {
      border-color: var(--accent);
      background: var(--card-hover);
      transform: translateY(-3px);
    }
    .icon {
      width: 56px;
      height: 56px;
      border-radius: 12px;
      flex-shrink: 0;
      object-fit: cover;
      background: #252a36;
    }
    .info h2 {
      margin: 0 0 0.2rem;
      font-size: 1.12rem;
      font-weight: 600;
    }
    .info p {
      margin: 0;
      font-size: 0.82rem;
      color: var(--muted);
    }
    .info .path {
      margin-top: 0.4rem;
      font-size: 0.75rem;
      color: var(--accent);
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    }
    footer {
      margin-top: 3.2rem;
      text-align: center;
      color: var(--muted);
      font-size: 0.82rem;
      line-height: 1.6;
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <img class="logo" src="icons/grok.png" alt="Grok">
      <h1>ArtCraft Apps</h1>
      <p class="subtitle">Free open-source creative tools, running locally</p>
      <div class="base-url">Base URL: <strong id="base-url">detecting…</strong></div>
    </header>

    <div class="grid" id="apps"></div>

    <footer>
      Powered by ArtCraft web builds • Served from your NAS
    </footer>
  </div>
  <script>
    const apps = [
      { folder: "photocraft",  name: "PhotoCraft",  desc: "Image editor (Photoshop alternative)", icon: "icons/photocraft.png" },
      { folder: "vectorcraft", name: "VectorCraft", desc: "Vector illustration (Illustrator alternative)", icon: "icons/vectorcraft.png" },
      { folder: "filmcraft",   name: "FilmCraft",   desc: "Video editor (Premiere alternative)", icon: "icons/filmcraft.png" },
      { folder: "lightcraft",  name: "LightCraft",  desc: "Photo library & RAW (Lightroom alternative)", icon: "icons/lightcraft.png" },
      { folder: "pdfcraft",    name: "PDFCraft",    desc: "PDF reader & editor (Acrobat alternative)", icon: "icons/pdfcraft.png" },
      { folder: "effectcraft", name: "EffectCraft", desc: "Motion graphics (After Effects alternative)", icon: "icons/effectcraft.png" },
      { folder: "designcraft", name: "DesignCraft", desc: "Page layout (InDesign alternative)", icon: "icons/designcraft.png" },
      { folder: "figcraft",    name: "FigCraft",    desc: "Interface design (Figma alternative)", icon: "icons/figcraft.png" },
      { folder: "wordcraft",   name: "WordCraft",   desc: "Word processor (Word alternative)", icon: "icons/wordcraft.png" },
      { folder: "gridcraft",   name: "GridCraft",   desc: "Spreadsheet (Excel alternative)", icon: "icons/gridcraft.png" },
      { folder: "deckcraft",   name: "DeckCraft",   desc: "Presentations (PowerPoint alternative)", icon: "icons/deckcraft.png" },
      { folder: "cadcraft",    name: "CADCraft",    desc: "CAD & drafting (AutoCAD alternative)", icon: "icons/cadcraft.png" },
      { folder: "soundcraft",  name: "SoundCraft",  desc: "Audio workstation (Pro Tools alternative)", icon: "icons/soundcraft.png" }
    ];

    const base = window.location.origin;
    document.getElementById("base-url").textContent = base;

    const grid = document.getElementById("apps");
    apps.forEach(app => {
      const url = `${base}/${app.folder}/`;
      const card = document.createElement("a");
      card.className = "card";
      card.href = url;
      card.target = "_blank";
      card.rel = "noopener";
      card.innerHTML = `
        <img class="icon" src="${app.icon}" alt="${app.name} icon" loading="lazy">
        <div class="info">
          <h2>${app.name}</h2>
          <p>${app.desc}</p>
          <div class="path">/${app.folder}/</div>
        </div>
      `;
      grid.appendChild(card);
    });
  </script>
</body>
</html>
INDEXEOF

log "Created index.html"

# Placeholder note about icons (user can add real app icons later)
log "Note: Place app icons in $PUBLIC_DIR/icons/ (e.g. photocraft.png) for the cards to show images."
log "A grok.png logo is expected at $PUBLIC_DIR/icons/grok.png (you can copy one there)."

for app in "${APPS[@]}"; do
  install_app "$app"
done

# Fix permissions so nginx (running as non-root) can read the files
log "Fixing permissions for nginx..."
chmod -R a+rX "$PUBLIC_DIR" 2>/dev/null || true
# Also make sure directories are executable
find "$PUBLIC_DIR" -type d -exec chmod a+x {} \; 2>/dev/null || true

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
    log "Docker Compose not found. Start the stack manually:"
    log "  cd $INSTALL_DIR && docker compose up -d"
  fi
else
  log "To start the stack later, run:"
  log "  cd $INSTALL_DIR && docker compose up -d"
fi

log "Installation finished."
log "You can now use update-artcraft.sh to keep the apps up to date."
