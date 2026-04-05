FROM alpine:3.23

ENV FAIL_PAUSE=60 \
    BUTTON_PAUSE=1800 \
    HTTP_PORT=8080 \
    WATCH_DIR=/data/import/ \
    EXPORT_DIR=/data/export/ \
    DISABLE_MULTI=false \
    SW_PATTERN=scan-bw \
    MULTI_PATTERN=multi \
    PAPERLESS_URL= \
    PAPERLESS_TOKEN= \
    TG_NOTIFY_SUCCESS=false

RUN apk add --no-cache \
    bash \
    imagemagick \
    imagemagick-pdf \
    ghostscript \
    ghostscript-fonts \
    poppler-utils \
    inotify-tools \
    curl \
    socat \
    ncurses \
    htop \
    nano

COPY scan.sh http_server.sh entrypoint.sh /app/

WORKDIR /app

RUN chmod +x /app/scan.sh /app/http_server.sh /app/entrypoint.sh \
    && mkdir -p /data/import /data/export

EXPOSE ${HTTP_PORT}

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -qO- http://localhost:${HTTP_PORT}/health || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
