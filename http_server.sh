#!/bin/bash
# HTTP handler – called by socat for each incoming connection.
# stdin  = HTTP request from client
# stdout = HTTP response to client

respond() {
    local code="$1" body="$2"
    printf "HTTP/1.1 %s\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n%s\n" \
        "$code" "$body"
}

# Read request line, extract path
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
        ;;
    /health|/health/)
        respond "200 OK" "OK"
        ;;
    *)
        respond "404 Not Found" "Not found. Available endpoints: /trigger  /health"
        ;;
esac
