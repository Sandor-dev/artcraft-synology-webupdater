# ArtCraft Synology Web Updater

Simple scripts to install and update the **web versions** of the free open-source [ArtCraft apps](https://github.com/orgs/storytold/repositories) (PhotoCraft, PdfCraft, LightCraft, etc.) on a Synology NAS (or any Linux system).

These apps are static WebAssembly builds served by nginx. No paid zip files required — everything is downloaded directly from the official GitHub releases.

## Scripts

| Script | Purpose |
|--------|---------|
| `install-artcraft.sh` | One-time installer: creates folders, downloads all apps, downloads logo, generates `index.html` + `docker-compose.yml`, sets permissions, and optionally starts the stack |
| `update-artcraft.sh` | Updates existing apps to the latest web release (no backups) |

## Requirements

- `curl`
- Either `unzip` **or** `python3` / `python` (the scripts fall back to Python automatically)
- Docker + Docker Compose (recommended; the installer can start the stack for you)

On Synology you can get `unzip` via Entware (`opkg install unzip`) or just rely on the built-in Python.

## Quick Start

### 1. Install

```bash
# Edit the configuration section at the top of the script first!
nano install-artcraft.sh

chmod +x install-artcraft.sh
./install-artcraft.sh
```

Important settings in the script:
- `INSTALL_DIR` — where to put the files (default: `/volume2/docker/artcraft`)
- `HOST_PORT` — port to expose (default: `4100`)
- `APPS_TO_INSTALL` — `"all"` (default) or a space-separated list
- `START_DOCKER=1` — set to 1 (default) to automatically start the container

After installation open `http://YOUR_NAS_IP:4100/` in a browser.

### 2. Update later

```bash
# Update all installed apps
./update-artcraft.sh

# Update only specific apps
./update-artcraft.sh pdfcraft photocraft

# Dry-run (shows what would happen)
./update-artcraft.sh --dry-run
```

The updater overwrites old files (no backups are created).

## Docker Compose

The installer generates a simple `docker-compose.yml` that uses the official `nginx` image and mounts the `public` folder read-only. You can also start/stop it manually:

```bash
cd /volume2/docker/artcraft
docker compose up -d
docker compose logs -f
docker compose down
```

## Notes

- Only the **web** builds (`*-web-*.zip`) are downloaded.
- The scripts work on any Linux system, not just Synology.
- Inspired by the excellent guides on [mariushosting.com](https://mariushosting.com/), but fully automated and free.

## License

MIT
