#!/bin/bash
# scan.sh – Scan processing script (single + multi mode)
# Uploads documents directly to Paperless-ngx via API
# Home Assistant trigger via HTTP GET/POST on /trigger
# HTTP server: socat + http_server.sh (no Python required)
VERSION="4.0.0"

# ── Configuration (overridable via ENV) ────────────────────────────────────────
WATCH_DIR="${WATCH_DIR:-/data/import/}"
EXPORT_DIR="${EXPORT_DIR:-/data/export/}"
HTTP_PORT="${HTTP_PORT:-8080}"
BUTTON_PAUSE="${BUTTON_PAUSE:-1800}"      # seconds to wait for trigger before timeout
FAIL_PAUSE="${FAIL_PAUSE:-60}"           # seconds between Paperless upload retries
SW_PATTERN="${SW_PATTERN:-scan-bw}"      # filename prefix identifying B&W scans (single: scan-bw*, multi: scan-bw-multi*)
MULTI_PATTERN="${MULTI_PATTERN:-multi}"  # substring identifying multi-page scans (matches scan-bw-multi*, scan-color-multi*)
DISABLE_MULTI="${DISABLE_MULTI:-false}"  # true = treat every file as single, ignore MULTI_PATTERN
PAPERLESS_URL="${PAPERLESS_URL:-}"
PAPERLESS_TOKEN="${PAPERLESS_TOKEN:-}"
TG_API_KEY="${TG_API_KEY:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"

MERGE_NAME=".merge_tmp.pdf"
TRIGGER_FILE="/tmp/scan_trigger"
LOCK_FILE="/tmp/scan_processing.lock"
HTTP_PID=""

# ── Colors ─────────────────────────────────────────────────────────────────────
red=$(tput setaf 1 2>/dev/null || printf '')
green=$(tput setaf 2 2>/dev/null || printf '')
yellow=$(tput setaf 3 2>/dev/null || printf '')
reset=$(tput sgr0 2>/dev/null || printf '')

# ── Logging ────────────────────────────────────────────────────────────────────
log()      { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok()   { log "${green}$*${reset}"; }
log_err()  { log "${red}ERROR: $*${reset}" >&2; }
log_warn() { log "${yellow}WARN: $*${reset}"; }

# ── Telegram notifications (optional) ─────────────────────────────────────────
tg_send() {
    [[ -z "$TG_API_KEY" || -z "$TG_CHAT_ID" ]] && return 0
    local text="$1"
    curl -sf -X POST \
        -H 'Content-Type: application/json' \
        -d "{\"chat_id\": \"$TG_CHAT_ID\", \"text\": \"$text\", \"disable_notification\": true}" \
        "https://api.telegram.org/bot${TG_API_KEY}/sendMessage" > /dev/null || true
}

# ── Paperless upload ───────────────────────────────────────────────────────────
upload_to_paperless() {
    local file="$1"

    if [[ -z "$PAPERLESS_URL" || -z "$PAPERLESS_TOKEN" ]]; then
        log_warn "Paperless not configured – file remains in $EXPORT_DIR"
        return 0
    fi

    log "Uploading '$(basename "$file")' to Paperless..."
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: Token $PAPERLESS_TOKEN" \
        -F "document=@${file}" \
        "${PAPERLESS_URL%/}/api/documents/post_document/")

    if [[ "$http_code" =~ ^2 ]]; then
        log_ok "Paperless upload successful (HTTP $http_code)"
        rm -f "$file"
        return 0
    else
        log_err "Paperless upload failed (HTTP $http_code)"
        return 1
    fi
}

upload_to_paperless_with_retry() {
    local file="$1"
    local attempt=0
    until upload_to_paperless "$file"; do
        attempt=$((attempt + 1))
        if [[ $attempt -eq 1 ]]; then
            tg_send "ERROR: Paperless upload failed – retrying every ${FAIL_PAUSE}s until successful."
        fi
        log_warn "Retrying in $FAIL_PAUSE seconds (attempt $attempt)..."
        sleep "$FAIL_PAUSE"
    done
    tg_send "Document successfully uploaded to Paperless!"
}

# ── PDF processing ─────────────────────────────────────────────────────────────
process_bw() {
    local input="$1" output="$2"
    log "Processing: black & white"
    magick -density 300 "$input" \
        -chop 5x5 -deskew 60% +repage \
        -strip -interlace Plane -normalize \
        -posterize 3 +dither -compress LZW \
        "$output" \
    && log_ok "B&W processing complete"
}

process_color() {
    local input="$1" output="$2"
    log "Processing: color"
    ghostscript -q -dNOPAUSE -dBATCH -dSAFER \
        -sDEVICE=pdfwrite -dPDFSETTINGS=/ebook \
        -dColorImageDownsampleType=/Bicubic -dColorImageResolution=300 \
        -dGrayImageDownsampleType=/Bicubic -dGrayImageResolution=300 \
        -sOutputFile="$output" "$input" \
    && log_ok "Color processing complete"
}

# Selects B&W or color processing based on filename prefix
process_pdf() {
    local input="$1" output="$2"
    if [[ "$(basename "$input")" == ${SW_PATTERN}* ]]; then
        process_bw "$input" "$output"
    else
        process_color "$input" "$output"
    fi
}

# ── File size sanity check ─────────────────────────────────────────────────────
check_file_size() {
    local file="$1" min_kb="${2:-100}"
    local size
    size=$(du -k "$file" | cut -f1)
    if [[ $size -lt $min_kb ]]; then
        log_err "File is only ${size}KB (< ${min_kb}KB) – possibly corrupt!"
        tg_send "ERROR: Processed file is only ${size}KB – possibly corrupt!"
        return 1
    fi
    log "File size: ${size}KB – OK"
    return 0
}

# ── PDF merge ──────────────────────────────────────────────────────────────────
merge_pdfs() {
    local dir="$1" output="$2"
    local pdf_files=()

    # Collect all PDFs except the internal merge temp file, sorted naturally
    while IFS= read -r -d '' f; do
        [[ "$(basename "$f")" != "$MERGE_NAME" ]] && pdf_files+=("$f")
    done < <(find "$dir" -maxdepth 1 -name "*.pdf" -print0 | sort -zV)

    if [[ ${#pdf_files[@]} -eq 0 ]]; then
        log_err "No PDF files found to merge"
        return 1
    fi

    log "Merging ${#pdf_files[@]} file(s)..."

    if [[ ${#pdf_files[@]} -eq 1 ]]; then
        cp "${pdf_files[0]}" "$output"
    else
        pdfunite "${pdf_files[@]}" "$output"
    fi

    log_ok "${#pdf_files[@]} PDF(s) merged successfully"
}

# ── Wait for Home Assistant trigger ───────────────────────────────────────────
wait_for_trigger() {
    log "Waiting for Home Assistant trigger (max. ${BUTTON_PAUSE}s) – URL: http://<host>:${HTTP_PORT}/trigger"
    local waited=0
    while [[ $waited -lt $BUTTON_PAUSE ]]; do
        if [[ -f "$TRIGGER_FILE" ]]; then
            rm -f "$TRIGGER_FILE"
            log_ok "Trigger received – starting processing"
            return 0
        fi
        sleep 1
        (( waited++ )) || true
    done
    log_warn "Timeout after ${BUTTON_PAUSE}s – proceeding automatically"
    return 0
}

# ── Multi mode: collect pages, wait for trigger, then process ─────────────────
process_batch() {
    local first_filename="$1"
    local timestamp output_file merge_tmp

    wait_for_trigger

    # Bail out if the directory is now empty (e.g. after a restart)
    if [[ -z "$(find "$WATCH_DIR" -maxdepth 1 -name "*.pdf" -not -name "$MERGE_NAME" 2>/dev/null)" ]]; then
        log_warn "Watch directory empty – nothing to process"
        rm -f "$LOCK_FILE"
        return 0
    fi

    printf -v timestamp '%(%Y-%m-%d_%H-%M-%S_)T' -1
    merge_tmp="${WATCH_DIR}${MERGE_NAME}"
    output_file="${EXPORT_DIR}${timestamp}${first_filename}"

    if merge_pdfs "$WATCH_DIR" "$merge_tmp"; then
        if process_pdf "$merge_tmp" "$output_file"; then
            # Clean up all source PDFs and the temp merge file
            find "$WATCH_DIR" -maxdepth 1 -name "*.pdf" -delete
            log_ok "Import directory cleaned up"

            if check_file_size "$output_file"; then
                upload_to_paperless_with_retry "$output_file"
            else
                log_err "Skipping upload due to failed size check: $output_file"
            fi
        else
            log_err "PDF processing failed"
            rm -f "$merge_tmp"
        fi
    else
        log_err "Merge failed"
    fi

    rm -f "$LOCK_FILE"
}

# ── Single mode: process each file immediately ─────────────────────────────────
# Also handles multi-page PDFs natively – both magick and ghostscript support them.
process_single() {
    local filename="$1"
    local timestamp output_file

    printf -v timestamp '%(%Y-%m-%d_%H-%M-%S_)T' -1
    output_file="${EXPORT_DIR}${timestamp}${filename}"

    log "Processing: $filename"

    if process_pdf "${WATCH_DIR}${filename}" "$output_file"; then
        rm -f "${WATCH_DIR}${filename}"
        log_ok "Original removed"

        if check_file_size "$output_file"; then
            upload_to_paperless_with_retry "$output_file"
        else
            log_err "Skipping upload due to failed size check: $output_file"
        fi
    else
        log_err "Processing failed: $filename"
    fi
}

# ── HTTP trigger server (for Home Assistant) ───────────────────────────────────
# Uses socat to listen for TCP connections and http_server.sh to handle each one.
start_http_server() {
    log "Starting HTTP trigger server on port $HTTP_PORT..."
    socat TCP-LISTEN:"$HTTP_PORT",reuseaddr,fork \
        EXEC:"/app/http_server.sh",nofork &
    HTTP_PID=$!
    log_ok "HTTP server started via socat (PID: $HTTP_PID)"
    log "Endpoint: GET/POST http://<host>:${HTTP_PORT}/trigger"
}

# ── Cleanup on exit ────────────────────────────────────────────────────────────
cleanup() {
    log "Shutting down..."
    rm -f "$LOCK_FILE" "$TRIGGER_FILE"
    [[ -n "$HTTP_PID" ]] && kill "$HTTP_PID" 2>/dev/null || true
    jobs -p | xargs -r kill 2>/dev/null || true
}

# ── Entry point ────────────────────────────────────────────────────────────────
main() {
    trap cleanup EXIT INT TERM

    log "============================================="
    log "  Scan Treatment v$VERSION"
    log "============================================="
    log "Watch:       $WATCH_DIR"
    log "Export:      $EXPORT_DIR"
    log "B&W pattern:   ${SW_PATTERN}*  (e.g. scan-bw-001.pdf, scan-bw-multi-001.pdf)"
    if [[ "$DISABLE_MULTI" == "true" ]]; then
        log "Multi mode:    disabled (DISABLE_MULTI=true) – every file processed immediately"
    else
        log "Multi pattern: *${MULTI_PATTERN}*  (e.g. scan-bw-multi*, scan-color-multi*)"
        log "Single:        everything else (e.g. scan-bw*, scan-color*)"
    fi
    log "HTTP port:   $HTTP_PORT  (GET/POST /trigger)"
    [[ -n "$PAPERLESS_URL" ]] \
        && log "Paperless: $PAPERLESS_URL" \
        || log_warn "Paperless: not configured – files will remain in $EXPORT_DIR"
    [[ -n "$TG_API_KEY" ]] \
        && log "Telegram:  enabled" \
        || log "Telegram:  disabled"
    log "============================================="

    mkdir -p "$WATCH_DIR" "$EXPORT_DIR"
    rm -f "$LOCK_FILE" "$TRIGGER_FILE"

    # Re-upload any leftover files in export dir from a previous run
    local leftover
    leftover=$(find "$EXPORT_DIR" -maxdepth 1 -name "*.pdf" 2>/dev/null)
    if [[ -n "$leftover" ]]; then
        log_warn "Found leftover files in $EXPORT_DIR – retrying upload..."
        while IFS= read -r file; do
            upload_to_paperless_with_retry "$file"
        done <<< "$leftover"
    fi

    start_http_server

    while true; do
        log "Watching $WATCH_DIR for new scans..."

        while IFS= read -r FILENAME; do
            # Skip the internal merge temp file and non-PDFs
            [[ "$FILENAME" == "$MERGE_NAME" ]] && continue
            [[ "$FILENAME" != *.pdf ]] && continue

            if [[ "$DISABLE_MULTI" != "true" && "$FILENAME" == *"${MULTI_PATTERN}"* ]]; then
                # Multi mode: filename matches MULTI_PATTERN (e.g. scan-multi*.pdf)
                # First matching file starts a background batch job;
                # subsequent files just land in the directory and get merged later.
                if [[ -f "$LOCK_FILE" ]]; then
                    log "Batch in progress – '$FILENAME' added to current stack"
                else
                    touch "$LOCK_FILE"
                    log "New batch started by: $FILENAME"
                    process_batch "$FILENAME" &
                fi
            else
                # Single mode: run in background so the event loop stays responsive
                # while processing or waiting for a Paperless retry.
                process_single "$FILENAME" &
            fi
        done < <(inotifywait -m -e close_write --format "%f" "$WATCH_DIR" 2>/dev/null)

        log_warn "inotifywait exited unexpectedly – restarting in 5 seconds..."
        sleep 5
    done
}

main
