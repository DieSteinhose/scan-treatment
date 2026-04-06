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
LOCK_FILE="${LOCK_FILE:-/tmp/scan_processing.lock}"
TRIGGERED_FILE="${TRIGGERED_FILE:-/tmp/scan_triggered}"
SCANNING_FILE="${SCANNING_FILE:-/tmp/scan_escl_active}"
STATUS_FILE="${STATUS_FILE:-/tmp/scan_last_result}"

respond() {
    local code="$1" body="$2"
    printf "HTTP/1.1 %s\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n%s\n" \
        "$code" "$body"
}

# Trigger an eSCL scan and save the result to WATCH_DIR.
# Runs silently – all feedback goes to stderr (scan.sh log), not stdout (HTTP response).
# $1 = color mode (Grayscale8 | RGB24)
# $2 = DPI
# $3 = destination filename (without path)
escl_scan() {
    local color_mode="$1" dpi="$2" filename="$3"
    touch "$SCANNING_FILE"

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
        echo "[$(date '+%H:%M:%S')] [HTTP] eSCL: failed to create scan job – printer off or not ready?" >&2
        rm -f "$SCANNING_FILE"
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
        echo "[$(date '+%H:%M:%S')] [HTTP] eSCL: document download failed (HTTP ${http_code:-timeout})" >&2
        rm -f "$SCANNING_FILE"
        return 1
    fi

    echo "[$(date '+%H:%M:%S')] [HTTP] eSCL: scan saved as ${filename}" >&2
    rm -f "$SCANNING_FILE"
    return 0
}

# Determine next available filename for multi-page batches.
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

    /status|/status/)
        # Derive state from flag files
        if [[ -f "$TRIGGERED_FILE" ]]; then
            state="processing"
        elif [[ -f "$LOCK_FILE" ]]; then
            state="collecting"
        elif [[ -f "$SCANNING_FILE" ]]; then
            state="scanning"
        else
            state="idle"
        fi

        # Count pages in current batch and detect mode
        bw_pages=$(find "${WATCH_DIR%/}" -maxdepth 1 \
            -name "${SW_PATTERN}-${MULTI_PATTERN}*.pdf" 2>/dev/null | wc -l | tr -d ' ')
        color_pages=$(find "${WATCH_DIR%/}" -maxdepth 1 \
            -name "scan-color-${MULTI_PATTERN}*.pdf" 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$bw_pages" -gt 0 ]]; then
            mode="bw"
            pages=$bw_pages
        elif [[ "$color_pages" -gt 0 ]]; then
            mode="color"
            pages=$color_pages
        else
            mode="null"
            pages=0
        fi

        # Read last processing result
        last_result="null"
        last_time="null"
        if [[ -f "$STATUS_FILE" ]]; then
            read -r last_result last_time < "$STATUS_FILE"
        fi

        printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
        printf '{"state":"%s","mode":"%s","pages":%s,"last_result":"%s","last_time":"%s"}\n' \
            "$state" "$mode" "$pages" "$last_result" "$last_time"
        ;;

    /trigger|/trigger/)
        touch "${TRIGGER_FILE:-/tmp/scan_trigger}"
        respond "200 OK" "Triggered!"
        echo "[$(date '+%H:%M:%S')] [HTTP] Trigger received" >&2
        ;;

    /health|/health/)
        respond "200 OK" "OK"
        ;;

    # ── eSCL endpoints – respond immediately, scan runs in background ──────────
    /scan/single/bw|/scan/single/bw/)
        if [[ -z "$PRINTER_IP" ]]; then
            respond "503 Service Unavailable" "PRINTER_IP is not configured."
        else
            filename="${SW_PATTERN}-$(date +%s).pdf"
            respond "202 Accepted" "Scanning (B&W ${ESCL_BW_DPI}dpi) → ${filename}"
            escl_scan "Grayscale8" "$ESCL_BW_DPI" "$filename" </dev/null >/dev/null &
        fi
        ;;

    /scan/single/color|/scan/single/color/)
        if [[ -z "$PRINTER_IP" ]]; then
            respond "503 Service Unavailable" "PRINTER_IP is not configured."
        else
            filename="scan-color-$(date +%s).pdf"
            respond "202 Accepted" "Scanning (color ${ESCL_COLOR_DPI}dpi) → ${filename}"
            escl_scan "RGB24" "$ESCL_COLOR_DPI" "$filename" </dev/null >/dev/null &
        fi
        ;;

    /scan/multi/next|/scan/multi/next/)
        if [[ -z "$PRINTER_IP" ]]; then
            respond "503 Service Unavailable" "PRINTER_IP is not configured."
        else
            # Continue the current batch in whatever mode was started
            bw_count=$(find "${WATCH_DIR%/}" -maxdepth 1 \
                -name "${SW_PATTERN}-${MULTI_PATTERN}*.pdf" 2>/dev/null | wc -l | tr -d ' ')
            color_count=$(find "${WATCH_DIR%/}" -maxdepth 1 \
                -name "scan-color-${MULTI_PATTERN}*.pdf" 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$bw_count" -gt 0 ]]; then
                filename=$(next_multi_filename "${SW_PATTERN}-${MULTI_PATTERN}")
                respond "202 Accepted" "Scanning (B&W ${ESCL_BW_DPI}dpi) → ${filename}"
                escl_scan "Grayscale8" "$ESCL_BW_DPI" "$filename" </dev/null >/dev/null &
            elif [[ "$color_count" -gt 0 ]]; then
                filename=$(next_multi_filename "scan-color-${MULTI_PATTERN}")
                respond "202 Accepted" "Scanning (color ${ESCL_COLOR_DPI}dpi) → ${filename}"
                escl_scan "RGB24" "$ESCL_COLOR_DPI" "$filename" </dev/null >/dev/null &
            else
                respond "409 Conflict" "No active batch found. Start one with /scan/multi/bw or /scan/multi/color."
            fi
        fi
        ;;

    /scan/multi/bw|/scan/multi/bw/)
        if [[ -z "$PRINTER_IP" ]]; then
            respond "503 Service Unavailable" "PRINTER_IP is not configured."
        else
            filename=$(next_multi_filename "${SW_PATTERN}-${MULTI_PATTERN}")
            respond "202 Accepted" "Scanning (B&W ${ESCL_BW_DPI}dpi) → ${filename}"
            escl_scan "Grayscale8" "$ESCL_BW_DPI" "$filename" </dev/null >/dev/null &
        fi
        ;;

    /scan/multi/color|/scan/multi/color/)
        if [[ -z "$PRINTER_IP" ]]; then
            respond "503 Service Unavailable" "PRINTER_IP is not configured."
        else
            filename=$(next_multi_filename "scan-color-${MULTI_PATTERN}")
            respond "202 Accepted" "Scanning (color ${ESCL_COLOR_DPI}dpi) → ${filename}"
            escl_scan "RGB24" "$ESCL_COLOR_DPI" "$filename" </dev/null >/dev/null &
        fi
        ;;

    *)
        respond "404 Not Found" "Not found. Available endpoints:
  /trigger             – start multi-page processing
  /health              – health check
  /status              – current scan state (JSON)
  /scan/single/bw      – scan one B&W page and process immediately
  /scan/single/color   – scan one color page and process immediately
  /scan/multi/bw       – add a B&W page to the current multi-page batch
  /scan/multi/color    – add a color page to the current multi-page batch
  /scan/multi/next     – add a page in the same mode as the current batch"
        echo "[$(date '+%H:%M:%S')] [HTTP] 404 – unknown path: $path" >&2
        ;;
esac
