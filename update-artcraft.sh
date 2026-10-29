#!/bin/bash
#
# ArtCraft Web Apps Updater for Synology NAS / Linux
# Downloads the latest *-web-*.zip from GitHub (storytold org) and replaces the content
# of the corresponding folder under the ArtCraft public directory.
#
# Usage:
#   ./update-artcraft.sh                  # update all existing apps
#   ./update-artcraft.sh pdfcraft         # update only one app
#   ./update-artcraft.sh pdfcraft photocraft
#   ./update-artcraft.sh --dry-run        # show what would be done
#   ./update-artcraft.sh --no-backup      # skip backup
#
# Requirements: curl, and either unzip or python3/python

set -euo pipefail

# ======================== CONFIGURATION ========================
BASE_DIR="${BASE_DIR:-/volume2/docker/artcraft/public}"
TEMP_BASE="${TEMP_BASE:-/tmp/artcraft-update}"
ORG="storytold"
# ===============================================================

DRY_RUN=0
DO_BACKUP=1

KNOWN_APPS=(
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

# Extract zip using unzip or Python fallback
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

  log "  Neither unzip nor python is available!"
  log "  Install unzip (e.g. via Entware: opkg install unzip) or ensure Python is present."
  return 1
}

# Parse arguments
APPS_TO_UPDATE=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --no-backup) DO_BACKUP=0; shift ;;
    --backup) DO_BACKUP=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--no-backup] [app1 app2 ...]"
      echo "Default: update all existing apps found under $BASE_DIR"
      exit 0
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      APPS_TO_UPDATE+=("$1")
      shift
      ;;
  esac
done

# Auto-detect existing apps if none specified
if [[ ${#APPS_TO_UPDATE[@]} -eq 0 ]]; then
  log "No apps specified, scanning $BASE_DIR for existing ones..."
  if [[ ! -d "$BASE_DIR" ]]; then
    die "BASE_DIR does not exist: $BASE_DIR"
  fi
  for app in "${KNOWN_APPS[@]}"; do
    if [[ -d "$BASE_DIR/$app" ]]; then
      APPS_TO_UPDATE+=("$app")
    fi
  done
  if [[ ${#APPS_TO_UPDATE[@]} -eq 0 ]]; then
    die "No known ArtCraft app folders found under $BASE_DIR."
  fi
fi

log "Apps to update: ${APPS_TO_UPDATE[*]}"
[[ $DRY_RUN -eq 1 ]] && log "DRY-RUN mode – no changes will be made."

get_web_zip_url() {
  local app="$1"
  local api="https://api.github.com/repos/${ORG}/${app}/releases/latest"
  local json
  json=$(curl -fsSL --retry 3 --retry-delay 2 "$api") || die "Failed to fetch release info: $api"

  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r '.assets[] | select(.name | test("-web-.*\\.zip$")) | .browser_download_url' | head -1
  else
    echo "$json" | grep -oE '"browser_download_url":\s*"[^"]*-web-[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)".*/\1/'
  fi
}

update_app() {
  local app="$1"
  local target_dir="$BASE_DIR/$app"
  local tmp_dir="$TEMP_BASE/$app"
  local zip_file="$tmp_dir/${app}-web.zip"

  log "=== Updating $app ==="

  if [[ ! -d "$target_dir" ]]; then
    log "  Folder does not exist: $target_dir – skipping."
    return 0
  fi

  local zip_url
  zip_url=$(get_web_zip_url "$app") || die "Failed to get download URL for $app"
  if [[ -z "$zip_url" || "$zip_url" == "null" ]]; then
    log "  No web zip found in latest release for $app. Skipping."
    return 0
  fi

  log "  Downloading: $zip_url"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "  [dry-run] Would download, clear $target_dir and extract."
    return 0
  fi

  mkdir -p "$tmp_dir"
  rm -rf "$tmp_dir"/*
  curl -fL --retry 3 -o "$zip_file" "$zip_url" || die "Download failed: $zip_url"

  # Backup
  if [[ $DO_BACKUP -eq 1 ]]; then
    local backup="$BASE_DIR/${app}.backup.$(date +%Y%m%d-%H%M%S)"
    log "  Backup: $backup"
    cp -a "$target_dir" "$backup" || log "  Warning: backup failed partially."
  fi

  # Clear old content (keep the folder itself)
  log "  Removing old files from $target_dir"
  find "$target_dir" -mindepth 1 -delete 2>/dev/null || rm -rf "$target_dir"/*

  # Extract
  log "  Extracting..."
  extract_zip "$zip_file" "$tmp_dir" || die "Extraction failed"

  # Find the inner folder (usually app-web-version/)
  local inner
  inner=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d ! -name ".*" | head -1)
  if [[ -z "$inner" ]]; then
    die "Could not find inner folder inside the zip for $app"
  fi

  log "  Inner folder: $(basename "$inner")"
  cp -a "$inner"/. "$target_dir/" || die "Copy failed"

  # Cleanup
  rm -rf "$tmp_dir"
  log "  $app updated successfully."
}

# Main
mkdir -p "$TEMP_BASE"
for app in "${APPS_TO_UPDATE[@]}"; do
  update_app "$app" || log "Error while updating $app, continuing with the rest."
done

log "Done."
log "Open the apps in your browser and check Help → About to verify the new version."
log "If something doesn't start, check the Docker container logs or the folder contents."
