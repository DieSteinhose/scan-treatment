# scan-treatment

Docker container for automatic scanner PDF processing. Optimizes black & white and color scans and uploads them directly to [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) via API. Multi-page document assembly is triggered via a Home Assistant button.

## How it works

The container watches an input directory using `inotifywait`. When the scanner drops a file, it is processed immediately (single mode) or collected with other pages and processed after a trigger (multi mode).

**Black & white** (`scan-bw*.pdf`): ImageMagick – deskew, normalize, posterize, LZW compression  
**Color** (everything else): Ghostscript – bicubic downsampling to 300 DPI, `/ebook` preset

> Processing settings are optimized for the **HP LaserJet MFP M130fw** at a scan resolution of **600 DPI**. Other scanners or resolutions may require tuning of the ImageMagick/Ghostscript parameters. If the results are insufficient for your device, feel free to fork this repository and adjust the parameters in `scan.sh` to fit your needs.

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
    image: scan-treatment:latest
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - /mnt/scanner:/data
    environment:
      PAPERLESS_URL: http://paperless-ngx:8000
      PAPERLESS_TOKEN: your-api-token
      BUTTON_PAUSE: "600"
      TG_API_KEY: "123456:ABC..."   # optional
      TG_CHAT_ID: "123456789"       # optional
```

## Unraid

Open the Unraid terminal and run:

```bash
wget -O /boot/config/plugins/dockerMan/templates-user/scan-treatment.xml \
  https://raw.githubusercontent.com/DieSteinhose/scan-treatment/main/unraid-template.xml
```

Then go to **Docker → Add Container** and select `scan-treatment` from the template list.

## Build

Pre-built images are available from the GitHub Container Registry:

```bash
docker pull ghcr.io/DieSteinhose/scan-treatment:latest
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
