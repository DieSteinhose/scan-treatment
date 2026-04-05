#!/bin/bash
# HTTP handler – called by socat for each incoming connection.
# stdin  = HTTP request from client
# stdout = HTTP response to client

WATCH_DIR="${WATCH_DIR:-/data/import/}"
PRINTER_IP="${PRINTER_IP:-}"
SW_PATTERN="${SW_PATTERN:-scan-bw}"
MULTI_PATTERN="${MULTI_PATTERN:-multi}"
ESCL_BW_DPI="${ESCL_BW_DPI:-600}"
ESCL_COLOR_DPI="${ESCL_COLOR_DPI:-600}"

respond() {
    local code="$1" body="$2"
    printf "HTTP/1.1 %s\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n%s\n" \
        "$code" "$body"
}

# Trigger an eSCL scan and save the result as FILENAME into WATCH_DIR.
# $1 = color mode (Grayscale8 | RGB24)
# $2 = DPI (e.g. 300 or 600)
# $3 = destination filename (without path)
escl_scan() {
    local color_mode="$1" dpi="$2" filename="$3"

    if [[ -z "$PRINTER_IP" ]]; then
        respond "503 Service Unavailable" "PRINTER_IP is not configured."
        return 1
    fi

    # Create eSCL scan job
    local job_uri
    job_uri=$(curl -sf --max-time 15 -X POST \
        -H "Content-Type: text/xml" \
        -d "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<scan:ScanSettings xmlns:scan=\"http://schemas.hp.com/imaging/escl/2011/05/03\"
                   xmlns:pwg=\"http://www.pwg.org/schemas/2010/12/sm\">
  <pwg:Version>2.5</pwg:Version>
  <scan:Intent>Document</scan:Intent>
  <pwg:InputSource>Platen</pwg:InputSource>
  <scan:ColorMode>${color_mode}</scan:ColorMode>
  <scan:XResolution>${dpi}</scan:XResolution>
  <scan:YResolution>${dpi}</scan:YResolution>
  <pwg:DocumentFormat>application/pdf</pwg:DocumentFormat>
</scan:ScanSettings>" \
        -D - \
        "http://${PRINTER_IP}/eSCL/ScanJobs" 2>/dev/null \
        | grep -i '^Location:' | sed 's/[Ll]ocation: *//; s/\r//')

    if [[ -z "$job_uri" ]]; then
        respond "502 Bad Gateway" "eSCL scan job could not be created. Is the printer on and ready?"
        echo "[$(date '+%H:%M:%S')] [HTTP] eSCL: failed to create scan job" >&2
        return 1
    fi

    # Download the scanned document
    local dest="${WATCH_DIR%/}/${filename}"
    local http_code
    http_code=$(curl -sf --max-time 60 \
        "${job_uri}/NextDocument" \
        -o "$dest" \
        -w "%{http_code}" 2>/dev/null)

    if [[ "$http_code" != "200" ]]; then
        rm -f "$dest"
        respond "502 Bad Gateway" "eSCL scan failed or timed out (HTTP ${http_code:-timeout})."
        echo "[$(date '+%H:%M:%S')] [HTTP] eSCL: document download failed (HTTP ${http_code:-timeout})" >&2
        return 1
    fi

    echo "[$(date '+%H:%M:%S')] [HTTP] eSCL: scan saved as ${filename}" >&2
    return 0
}

# Determine next available filename for multi-page batches.
# Returns e.g. scan-bw-multi.pdf for the first page, scan-bw-multi2.pdf for the second, etc.
next_multi_filename() {
    local base="$1"  # e.g. scan-bw-multi  or  scan-color-multi
    local count
    count=$(find "${WATCH_DIR%/}" -maxdepth 1 -name "${base}*.pdf" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$count" -eq 0 ]]; then
        echo "${base}.pdf"
    else
        echo "${base}$(( count + 1 )).pdf"
    fi
}

# ── Read request ───────────────────────────────────────────────────────────────
read -r request
path=$(printf '%s' "$request" | cut -d' ' -f2 | tr -d '\r\n')

# Drain remaining headers
while IFS= read -r -t 2 line; do
    [[ "${line%$'\r'}" == "" ]] && break
done

case "${path%%\?*}" in

    /trigger|/trigger/)
        touch "${TRIGGER_FILE:-/tmp/scan_trigger}"
        respond "200 OK" "Triggered!"
        echo "[$(date '+%H:%M:%S')] [HTTP] Trigger received" >&2
        ;;

    /health|/health/)
        respond "200 OK" "OK"
        ;;

    # ── eSCL single-page endpoints ─────────────────────────────────────────────
    /scan/single/bw|/scan/single/bw/)
        filename="${SW_PATTERN}-$(date +%s).pdf"
        if escl_scan "Grayscale8" "$ESCL_BW_DPI" "$filename"; then
            respond "200 OK" "Scan started: ${filename}"
        fi
        ;;

    /scan/single/color|/scan/single/color/)
        filename="scan-color-$(date +%s).pdf"
        if escl_scan "RGB24" "$ESCL_COLOR_DPI" "$filename"; then
            respond "200 OK" "Scan started: ${filename}"
        fi
        ;;

    # ── eSCL multi-page endpoints ──────────────────────────────────────────────
    /scan/multi/bw|/scan/multi/bw/)
        filename=$(next_multi_filename "${SW_PATTERN}-${MULTI_PATTERN}")
        if escl_scan "Grayscale8" "$ESCL_BW_DPI" "$filename"; then
            respond "200 OK" "Page added: ${filename}"
        fi
        ;;

    /scan/multi/color|/scan/multi/color/)
        filename=$(next_multi_filename "scan-color-${MULTI_PATTERN}")
        if escl_scan "RGB24" "$ESCL_COLOR_DPI" "$filename"; then
            respond "200 OK" "Page added: ${filename}"
        fi
        ;;

    *)
        respond "404 Not Found" "Not found. Available endpoints:
  /trigger             – start multi-page processing
  /health              – health check
  /scan/single/bw      – scan one B&W page and process immediately
  /scan/single/color   – scan one color page and process immediately
  /scan/multi/bw       – add a B&W page to the current multi-page batch
  /scan/multi/color    – add a color page to the current multi-page batch"
        echo "[$(date '+%H:%M:%S')] [HTTP] 404 – unknown path: $path" >&2
        ;;
esac
