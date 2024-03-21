FROM dpokidov/imagemagick:latest-ubuntu

# Veraltete ImageMagick in ubuntu 20.04 version
# FROM ubuntu:20.04

ENV FAIL_PAUSE=60 \
    BUTTON_PAUSE=1800

RUN apt update && apt install -y poppler-utils inotify-tools ftp-upload curl libncurses6 htop nano python3 python3-pip tcpdump

RUN pip3 install amazon-dash && python3 -m amazon_dash.install

# Nicht über apt installieren: ghostscript

COPY . /app

COPY amazon-dash.yml /etc

WORKDIR /app

RUN mkdir /data && mkdir /data/import_multi && mkdir /data/import && mkdir /data/export

ENTRYPOINT ["/app/entrypoint.sh"]