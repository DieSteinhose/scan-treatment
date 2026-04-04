FROM dpokidov/imagemagick:latest-ubuntu

# Nicht über apt installieren: ghostscript (kommt aus dem Base-Image)

ENV FAIL_PAUSE=60 \
    BUTTON_PAUSE=1800 \
    HTTP_PORT=8080 \
    WATCH_DIR=/data/import/ \
    EXPORT_DIR=/data/export/ \
    DISABLE_MULTI=false \
    SW_PATTERN=scan-sw \
    PAPERLESS_URL= \
    PAPERLESS_TOKEN=

RUN apt-get update && apt-get install -y \
    poppler-utils \
    inotify-tools \
    curl \
    socat \
    libncurses6 \
    htop \
    nano \
    && rm -rf /var/lib/apt/lists/*

COPY scan.sh http_server.sh entrypoint.sh /app/

WORKDIR /app

RUN chmod +x /app/scan.sh /app/http_server.sh /app/entrypoint.sh \
    && mkdir -p /data/import /data/export

EXPOSE ${HTTP_PORT}

ENTRYPOINT ["/app/entrypoint.sh"]