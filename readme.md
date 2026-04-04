# scan-treatment

Docker container for automatic scanner PDF processing. Optimizes black & white and color scans and uploads them directly to [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) via API. Multi-page document assembly is triggered via a Home Assistant button.

## How it works

The container watches an input directory using `inotifywait`. When the scanner drops a file, it is processed immediately (single mode) or collected with other pages and processed after a trigger (multi mode).

**Black & white** (`scan-sw*.pdf`): ImageMagick – deskew, normalize, posterize, LZW compression  
**Color** (everything else): Ghostscript – bicubic downsampling to 300 DPI, `/ebook` preset

### Single mode (`DISABLE_MULTI=true`)

Every incoming PDF is processed immediately on arrival. Best suited for printers that natively produce multi-page PDFs. Both ImageMagick and Ghostscript handle multi-page PDFs correctly without any additional merging step.

### Multi mode (default)

The first incoming scan starts a collection phase. Additional pages can keep arriving. Once the Home Assistant button fires the trigger (or `BUTTON_PAUSE` seconds elapse), all collected PDFs are merged, processed, and uploaded to Paperless.

```
Scan page 1 → scan page 2 → ... → HA button → process + upload to Paperless
```

## Quick start

```bash
docker run -d \
  -v /path/to/scans:/data/import \
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
| `SW_PATTERN` | `scan-sw` | Filename prefix identifying B&W scans |
| `DISABLE_MULTI` | `false` | `true` = process each file immediately, no merging |
| `PAPERLESS_URL` | – | Base URL of your Paperless-ngx instance |
| `PAPERLESS_TOKEN` | – | API token (Paperless → Settings → API Token) |
| `HTTP_PORT` | `8080` | Port for the HTTP trigger endpoint |
| `BUTTON_PAUSE` | `1800` | Seconds to wait for trigger before auto-proceeding |
| `FAIL_PAUSE` | `60` | Seconds between Paperless upload retries |
| `TG_API_KEY` | – | Telegram bot token (optional) |
| `TG_CHAT_ID` | – | Telegram chat ID (optional) |

## Home Assistant integration

The container exposes a lightweight HTTP server. A `GET` or `POST` to `/trigger` fires the multi-mode processing.

**`configuration.yaml`**
```yaml
rest_command:
  scan_trigger:
    url: http://192.168.1.x:8080/trigger
    method: POST
```

**Automation / button action**
```yaml
action: rest_command.scan_trigger
```

Available endpoints:

| Path | Description |
|---|---|
| `/trigger` | Fire processing (GET or POST) |
| `/health` | Health check, returns `200 OK` |

## Filename convention

The scan filename determines which processing pipeline is used:

| Filename starts with | Pipeline |
|---|---|
| `scan-sw` (configurable via `SW_PATTERN`) | ImageMagick B&W optimization |
| anything else | Ghostscript color optimization |

## docker-compose example

```yaml
services:
  scan-treatment:
    image: scan-treatment:latest
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - /mnt/scanner/import:/data/import
    environment:
      PAPERLESS_URL: http://paperless-ngx:8000
      PAPERLESS_TOKEN: your-api-token
      BUTTON_PAUSE: "600"
      TG_API_KEY: "123456:ABC..."   # optional
      TG_CHAT_ID: "123456789"       # optional
```

## Build

```bash
docker build -t scan-treatment .
```

## Notes

- Without `PAPERLESS_URL` and `PAPERLESS_TOKEN`, processed files are kept in `EXPORT_DIR` and not uploaded.
- Failed Paperless uploads are retried indefinitely every `FAIL_PAUSE` seconds.
- Telegram notifications are fully optional. Nothing is sent if `TG_API_KEY` is unset.
- In multi mode, only one batch runs at a time. Files arriving during an active batch are automatically added to the current stack.
