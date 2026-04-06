# Changelog

All notable changes to this project will be documented in this file.

## v4.1.0 – 2026-04-06

### eSCL scan endpoints

The container can now trigger scans directly on the printer via the eSCL (AirPrint Scan) protocol — no SMB share, no physical button press required. All scan endpoints are **inactive unless `PRINTER_IP` is set**.

- `GET/POST /scan/single/bw` – scan one B&W page and process it immediately
- `GET/POST /scan/single/color` – scan one color page and process it immediately
- `GET/POST /scan/multi/bw` – add a B&W page to the current multi-page batch
- `GET/POST /scan/multi/color` – add a color page to the current multi-page batch
- `GET/POST /scan/multi/next` – add a page in the same mode as the current batch (auto-detects B&W or color)
- All `/scan/*` endpoints respond with `202 Accepted` immediately; the actual scan runs in the background so Home Assistant `rest_command` calls do not time out
- New env vars `ESCL_BW_DPI` and `ESCL_COLOR_DPI` (default: `600`) to control scan resolution independently from the SMB-based processing pipeline

### Printer scan-menu status display

The printer's own scan job display name can now be used as a status indicator, visible directly in the printer's scan menu.

- Controlled by `PRINTER_NOTIFY=true` (requires `PRINTER_IP`)
- States shown in the job name:

  | State | Display |
  |---|---|
  | Collecting pages | `My Scan Job [scan 2]` |
  | Processing after trigger | `My Scan Job [proc...]` |
  | Done successfully | `My Scan Job [OK 14:32]` |
  | Done with error | `My Scan Job [ERR 14:32]` |
  | Done, but new batch already collecting | `My Scan Job [OK scan 1]`, `[OK scan 2]`, ... |
  | 60 minutes after completion | `My Scan Job` (suffix cleared) |

- Status suffixes are also cleared on every container start
- Uses the HP EWS web form (works immediately post-scan; the LEDM PUT API is locked for ~8 minutes after a scan)
- Optional `PRINTER_USER` filter: only updates jobs whose display name contains this string — useful when multiple containers share one printer

### Status JSON endpoint

- New `GET /status` endpoint for polling from Home Assistant or any other system
- Returns a JSON object with the current state, batch mode, page count, and last processing result:
  ```json
  {"state":"collecting","mode":"bw","pages":3,"last_result":"ok","last_time":"14:32"}
  ```
- States: `idle`, `scanning` (eSCL in progress), `collecting` (multi batch open), `processing` (after trigger)

---

## v4.0.0 – 2026-04-05

Complete rewrite into a single self-contained `scan.sh` script. Single and multi mode are now unified; the HTTP trigger replaces the Amazon Dash button; Paperless-ngx API upload replaces FTP.

### Changes from v3.x

- **Single-file architecture** – `import_single.sh` and `import_multi.sh` merged into one `scan.sh`; `http_server.sh` handles the HTTP layer via socat (no Python or Node.js required)
- **HTTP trigger** – the Amazon Dash button is replaced by a `/trigger` HTTP endpoint, callable from Home Assistant, a browser, or curl
- **Paperless-ngx upload** – FTP upload replaced by direct Paperless API upload; failed uploads are retried indefinitely every `FAIL_PAUSE` seconds
- **Telegram success notifications optional** – previously always sent on success; now controlled by `TG_NOTIFY_SUCCESS` (default: `false`)
- **Configurable processing pipelines** – `BW_PARAMS` (ImageMagick) and `COLOR_PARAMS` (Ghostscript) are fully overridable via environment variables without rebuilding the image
- **Timezone support** – new `TZ` env var controls log timestamps and output filenames
- **SMB upload stability** – waits for incoming files to stop changing size before processing, handling chunked SMB writes correctly
- **Duplicate event deduplication** – uses atomic `mkdir` locks to prevent processing the same file twice when inotifywait fires multiple events
- **Alpine-based image** – smaller footprint, under 50M
- **Unraid template** – ready-to-use community application template

### Carried over from v3.x

- Multi-page batch mode: collect pages, wait for trigger, merge, process, upload
- B&W pipeline (ImageMagick) and color pipeline (Ghostscript)
- File size sanity check: rejects processed files below 100 KB as likely corrupt
- Telegram notifications for both upload failures and successes

---

## v3.1.0 – 2024-03-21

- Added deskew for B&W documents (`-deskew 60%` in ImageMagick parameters)

---

## v3.0.0 – 2024-03-21

First version added to version control, with two separate scripts (`import_single.sh`, `import_multi.sh`).

- Multi-page batch mode triggered by an **Amazon Dash button** (via `amazon-dash`)
- Single-page mode: processes each incoming PDF immediately
- B&W pipeline: ImageMagick with normalize, posterize, LZW compression
- Color pipeline: Ghostscript with bicubic downsampling, `/ebook` preset
- FTP upload of processed documents
- Telegram notifications for upload status
- File size sanity check (rejects files below 100 KB)
