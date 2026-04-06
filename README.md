# scan-treatment

Docker container for automatic scanner PDF processing. Optimizes black & white and color scans and uploads them directly to [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) via API. Multi-page document assembly is triggered via a Home Assistant button.

## How it works

The container watches an input directory using `inotifywait`. When the scanner drops a file, it is processed immediately (single mode) or collected with other pages and processed after a trigger (multi mode).

The `/data` directory is mounted into the container as a bind volume. A typical setup is to back it with an SMB share on the host so the scanner can drop files directly into `/data/import` over the network. Mounting the share on the host is done outside the container. The container only watches the directory.

**Black & white** (`scan-bw*.pdf`): ImageMagick – deskew, normalize, posterize, LZW compression at `BW_DPI` DPI (default: 300)  
**Color** (everything else): Ghostscript – bicubic downsampling to 300 DPI, `/ebook` preset

> Processing settings are optimized for the **HP LaserJet MFP M130fw** at a scan resolution of **600 DPI**. Both pipelines are fully configurable via `BW_DPI`, `BW_PARAMS` and `COLOR_PARAMS` without rebuilding the image.

**Default `BW_PARAMS`** (ImageMagick, parameters between input and output):
```
-chop 5x5 -deskew 60% +repage -strip -interlace Plane -normalize -posterize 3 +dither -compress LZW
```
Full command: `magick -density $BW_DPI <input> $BW_PARAMS <output>`

**Default `COLOR_PARAMS`** (Ghostscript, parameters before `-sOutputFile`):
```
-q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=pdfwrite -dPDFSETTINGS=/ebook -dColorImageDownsampleType=/Bicubic -dColorImageResolution=300 -dGrayImageDownsampleType=/Bicubic -dGrayImageResolution=300 -dFastWebView=false
```
Full command: `gs $COLOR_PARAMS -sOutputFile=<output> <input>`

### Single mode (`DISABLE_MULTI=true`)

Every incoming PDF is processed immediately on arrival. Use this if your printer is capable of producing multi-page PDFs natively — in that case the entire multi-page document arrives as a single file and no merging or trigger is needed. Home Assistant integration and the `/trigger` endpoint can be ignored entirely in this mode.

### Multi mode (default, `DISABLE_MULTI=false`)

Use this if your printer creates one separate PDF per scanned page and cannot combine them into a single file itself. The first incoming scan starts a collection phase. Additional pages keep arriving as individual files. Once the Home Assistant button fires the trigger (or `BUTTON_PAUSE` seconds elapse), all collected PDFs are merged, processed, and uploaded to Paperless.

```
Scan page 1 → scan page 2 → ... → HA button → merge → process → upload to Paperless
```

## Quick start

```bash
docker run -d \
  -v /path/to/data:/data \
  -p 8080:8080 \
  -e PAPERLESS_URL=http://paperless:8000 \
  -e PAPERLESS_TOKEN=your-api-token \
  scan-treatment:latest
```

## Configuration

All settings are controlled via environment variables.

| Variable | Default | Description |
|---|---|---|
| `WATCH_DIR` | `/data/import/` | Directory watched for incoming scans |
| `EXPORT_DIR` | `/data/export/` | Output directory when Paperless is not configured |
| `SW_PATTERN` | `scan-bw` | Filename prefix identifying B&W scans |
| `MULTI_PATTERN` | `multi` | Substring identifying multi-page scans |
| `DISABLE_MULTI` | `false` | `true` = ignore `MULTI_PATTERN`, process every file immediately |
| `BW_DPI` | `300` | DPI density for ImageMagick B&W processing |
| `BW_PARAMS` | *(see below)* | ImageMagick parameters for B&W processing |
| `COLOR_PARAMS` | *(see below)* | Ghostscript parameters for color processing |
| `PAPERLESS_URL` | – | Base URL of your Paperless-ngx instance |
| `PAPERLESS_TOKEN` | – | API token – found in the Django admin panel (`/admin`) under **Tokens** |
| `HTTP_PORT` | `8080` | Port for the HTTP trigger endpoint |
| `BUTTON_PAUSE` | `1800` | Seconds to wait for trigger before auto-proceeding |
| `FAIL_PAUSE` | `60` | Seconds between Paperless upload retries |
| `TG_API_KEY` | – | Telegram bot token (optional) |
| `TG_CHAT_ID` | – | Telegram chat ID (optional) |
| `TG_NOTIFY_SUCCESS` | `false` | `true` = also send Telegram notification on successful uploads |
| `PRINTER_NOTIFY` | `false` | `true` = update the matching scan job's display name in the printer menu after each multi-page batch |
| `PRINTER_IP` | – | Printer IP address (required when `PRINTER_NOTIFY=true` or using `/scan/*` endpoints) |
| `PRINTER_USER` | – | Optional filter: only update jobs whose display name contains this string. Useful when multiple containers share one printer. |
| `ESCL_BW_DPI` | `600` | DPI for B&W scans via `/scan/single/bw` and `/scan/multi/bw` |
| `ESCL_COLOR_DPI` | `600` | DPI for color scans via `/scan/single/color` and `/scan/multi/color` |
| `TZ` | `Europe/Berlin` | Timezone for log timestamps and output filenames (e.g. `Europe/London`, `America/New_York`) |

## HTTP endpoints

All endpoints accept GET and POST. The container exposes them on `HTTP_PORT` (default `8080`).

| Path | Description |
|---|---|
| `/trigger` | Start multi-page processing |
| `/health` | Health check, returns `200 OK` |
| `/scan/single/bw` | Scan one B&W page and process immediately |
| `/scan/single/color` | Scan one color page and process immediately |
| `/scan/multi/bw` | Add a B&W page to the current multi-page batch |
| `/scan/multi/color` | Add a color page to the current multi-page batch |
| `/scan/multi/next` | Add a page in the same mode as the current batch (auto-detects B&W or color) |

The `/scan/*` endpoints require `PRINTER_IP` to be set and eSCL to be enabled on the printer (HP EWS → Networking → eSCL (AirPrint Scan): enabled). They trigger the scan directly via the printer's eSCL API, save the resulting PDF to `WATCH_DIR`, and let the existing processing pipeline handle it — no SMB share or physical button press needed.

```bash
# trigger manually
curl http://<host>:8080/trigger

# scan single B&W page and upload to Paperless
curl http://<host>:8080/scan/single/bw

# add a page to a multi-page batch, then trigger processing
curl http://<host>:8080/scan/multi/bw
curl http://<host>:8080/scan/multi/bw
curl http://<host>:8080/trigger
```

**Example: Home Assistant buttons**

```yaml
# configuration.yaml
rest_command:
  scan_trigger:
    url: http://192.168.1.x:8080/trigger
    method: POST
  scan_single_bw:
    url: http://192.168.1.x:8080/scan/single/bw
    method: POST
  scan_multi_bw:
    url: http://192.168.1.x:8080/scan/multi/bw
    method: POST
  scan_multi_color:
    url: http://192.168.1.x:8080/scan/multi/color
    method: POST
```

```yaml
# automation / button action
action: rest_command.scan_single_bw
```

## Filename convention

The scanner profile name determines both the processing mode and the pipeline. Configure your scanner to use these prefixes:

| Scanner profile / filename | Mode | Pipeline |
|---|---|---|
| `scan-bw.pdf`, `scan-bw2.pdf`, ... | Single – process immediately | ImageMagick B&W |
| `scan-color.pdf`, `scan-color2.pdf`, ... | Single – process immediately | Ghostscript color |
| `scan-bw-multi.pdf`, `scan-bw-multi2.pdf`, ... | Multi – collect, wait for trigger, merge | ImageMagick B&W |
| `scan-color-multi.pdf`, `scan-color-multi2.pdf`, ... | Multi – collect, wait for trigger, merge | Ghostscript color |

**Page numbering:** The first scan has no number suffix (e.g. `scan-bw-multi.pdf`), subsequent pages increment numerically (e.g. `scan-bw-multi2.pdf`, `scan-bw-multi3.pdf`, ...). All common numbering schemes are supported – no suffix, `1`, `2`, `10` as well as zero-padded `0001`, `0002`, `0010`. Pages are always merged in natural numeric order (8 → 9 → 10 → 11), not lexicographic order (which would incorrectly produce 1 → 10 → 11 → 2 → 3).

**Detection logic:**
- Multi is detected by substring match: filename contains `MULTI_PATTERN` (`multi` by default)
- B&W is detected by prefix match: filename starts with `SW_PATTERN` (`scan-bw` by default)
- Both checks are independent, so `scan-bw-multi` correctly triggers multi mode **and** B&W processing.

## docker-compose example

```yaml
services:
  scan-treatment:
    image: ghcr.io/diesteinhose/scan-treatment:latest
    container_name: scan-treatment
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - /mnt/scanner:/data
    environment:
      TZ: Europe/Berlin
      PAPERLESS_URL: http://paperless-ngx:8000
      PAPERLESS_TOKEN: your-api-token
      DISABLE_MULTI: "false"
      SW_PATTERN: scan-bw
      MULTI_PATTERN: multi
      BUTTON_PAUSE: "1800"
      BW_DPI: "300"
      # BW_PARAMS: "-chop 5x5 ..."     # optional: override ImageMagick parameters
      # COLOR_PARAMS: "-q ..."          # optional: override Ghostscript parameters
      # TG_API_KEY: "123456:ABC..."     # optional: Telegram bot token
      # TG_CHAT_ID: "123456789"         # optional: Telegram chat ID
      # TG_NOTIFY_SUCCESS: "false"      # optional: notify on successful uploads
      # PRINTER_NOTIFY: "true"          # optional: update printer scan-menu on batch completion
      # PRINTER_IP: "192.168.1.x"       # optional: printer IP (required when PRINTER_NOTIFY=true)
      # PRINTER_USER: "Alice"            # optional: filter to only update jobs with this name
```

## Unraid

Open the Unraid terminal and run:

```bash
wget -O /boot/config/plugins/dockerMan/templates-user/scan-treatment.xml \
  https://raw.githubusercontent.com/diesteinhose/scan-treatment/main/unraid-template.xml
```

Then go to **Docker → Add Container** and select `scan-treatment` from the template list.

## Build

Pre-built images are available from the GitHub Container Registry:

```bash
docker pull ghcr.io/diesteinhose/scan-treatment:latest
```

Or build locally:

```bash
docker build -t scan-treatment .
```

## Notes

- Without `PAPERLESS_URL` and `PAPERLESS_TOKEN`, processed files are kept in `EXPORT_DIR` and not uploaded.
- Failed Paperless uploads are retried indefinitely every `FAIL_PAUSE` seconds.
- Telegram notifications are fully optional. Nothing is sent if `TG_API_KEY` is unset.
- In multi mode, only one batch runs at a time. Files arriving during an active batch are automatically added to the current stack.
- Printer notifications (`PRINTER_NOTIFY=true`) work only in multi mode. The scan job's display name in the printer's scan menu reflects the current state:
  | State | Display |
  |---|---|
  | Collecting pages | `My Scan Job [scan 2]` |
  | Processing after trigger | `My Scan Job [proc...]` |
  | Done | `My Scan Job [OK 14:32]` or `[ERR 14:32]` |
  | Done, but next batch already collecting | `My Scan Job [OK scan 1]`, `[OK scan 2]`, ... |
  | 60 minutes after completion | `My Scan Job` (suffix cleared) |

  If pages for a new batch arrive while the previous one is still processing, the completion notification combines both states: `[OK scan N]` shows that the previous batch succeeded and N pages are already queued for the next one. Further pages increment the count. Once the trigger fires for the new batch, the display transitions to `[proc...]` as normal. Status suffixes are also cleared on every container start. Tested with HP LaserJet MFP M130fw via the HP EWS web interface.
