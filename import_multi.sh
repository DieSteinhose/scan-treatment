#!/bin/bash

#CONFIG

TARGET=/data/import_multi/
PROCESSED=/data/export/
MERGE_NAME=export_multi.pdf

red=`tput setaf 1`
green=`tput setaf 2`
reset=`tput sgr0`


wait_file() {
  local file="$1"; shift
  local wait_seconds="${1:-10}"; shift # 10 seconds as default timeout

  until test $((wait_seconds--)) -eq 0 -o -e "$file" ; do sleep 1; done

  ((++wait_seconds))
}

echo "Maintainer: Ollie Spila"
echo "Version: 3.0.0 - 14.04.2022 - MULTI"

# Changelog

# 1.0.1
# Fix: PDF Reihenfolge korrigiert


#rm button-pressed.txt || echo "${green}Dies ist normal, es ist eine bereiniung der button-pressed.txt${reset}"

if [ "$FTP_UPLOAD" == "true" ]
then
        ftp-upload --passive -h $FTP_HOST -u $FTP_USER --password $FTP_PASSWORD $PROCESSED*.pdf && echo "Gegebenfalls nachträger Upload nach neustart" \
        && curl -X POST -H 'Content-Type: application/json' -d '{"chat_id": "'"$TG_CHAT_ID"'", "text": "MULTI: Das Programm wurde neugestartet, gegebenfalls verbleibende Dokumente wurden nachträglich Hochgeladen", "disable_notification": true}' https://api.telegram.org/bot$TG_API_KEY/sendMessage
fi

# Sucht nach neuer Datei im Zielordner, close_write wartet bis eine Datei zuende geschrieben ist. Da der Drucker wärend desssen er scannt schon die Datei schreibt.
inotifywait -m -e close_write --format "%f" $TARGET \
        | while read FILENAME
                do

                        if [ -z "$(ls -A $TARGET)" ]; then
                                echo "MULTI: ${green}Verzeichnis ist Leer, ich versuche es erneut${reset} (Dies ist normal nach einem Multi-PDF-Erstellung"

                                # rm button-pressed.txt || echo "${green}Dies ist normal, es ist eine bereiniung der button-pressed.txt${reset}"

                        else

                                # Warte auf Dash-Button druck
                                echo "MULTI: ${green}Warte auf Dash Button für maximal $BUTTON_PAUSE Sekunden${reset}"
                                wait_file button-pressed.txt $BUTTON_PAUSE && echo "MULTI: ${green}Der Dash Button wurde gedrückt${reset}"

                                rm button-pressed.txt && echo "MULTI: ${green}Dash-Datei erfolgreich gelöscht!${reset}"

                                # Kombiere PDF Datein
                                pdfunite $(ls -v ${TARGET}*.pdf) ${TARGET}$MERGE_NAME && echo "MULTI: ${green}PDF Datein erfolgreich kombiniert${reset}"

                                sleep 2

                                # Erstellt variable DATE mit den inhalt des Datums + Uhrzeit
                                printf -v DATE '%(%Y-%m-%d_%H-%M-%S_)T' -1

                                if [[ "$FILENAME" == scan-sw*.pdf ]]

                                then

                                        # Optimiert die eingehende PDF und speichert die in export Ordner

                                        # Schwarzweiss
                                        magick -density 300 "${TARGET}$MERGE_NAME" -strip -interlace Plane -normalize -posterize 3 +dither -compress LZW "$PROCESSED$DATE$FILENAME" \
                                        && echo MULTI: "${green}PDF verarbeitung in SW erfolgreich abgeschlossen${reset}"

                                else

                                        # Farbe
                                        ghostscript -q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=pdfwrite -dPDFSETTINGS=/ebook -dColorImageDownsampleType=/Bicubic -dColorImageResolution=300 -dGrayImageDownsampleType=/Bicubic -dGrayImageResolution=300 -sOutputFile="$PROCESSED$DATE$FILENAME" "${TARGET}$MERGE_NAME" \
                                        && echo MULTI: "${green}PDF verarbeitung in Farbe erfolgreich abgeschlossen${reset}" \

                                fi

                                # Lösche die Originale
                                rm -r $TARGET* && echo MULTI: ${green}PDFs im Import-Verzeichnis erfolgreich gelöscht${reset}

                                if [ "$FTP_UPLOAD" == "true" ]
                                then
                        
                                        echo "MULTI: ${green}Starte nun Upload${reset}"
                                fi

                                # Überprüfe ob datei über 100kb groß ist, wenn nicht breche prozess ab und schreibe eine Telegram nachricht
                                actualsize=$(du -k "$PROCESSED$DATE$FILENAME" | cut -f 1)
                                if [ $actualsize -ge 100 ]; then
                                        if [ "$FTP_UPLOAD" == "true" ]
                                        then
                                                # Verbindet sich mit dem Server im Lemgo und versucht die verarbeitete Datei hochzuladen
                                                if ftp-upload --passive -h $FTP_HOST -u $FTP_USER --password $FTP_PASSWORD "$PROCESSED$DATE$FILENAME"

                                                # Sendet per Telegram die erfolgreiche Nachricht
                                                then
                                                curl -X POST -H 'Content-Type: application/json' -d '{"chat_id": "'"$TG_CHAT_ID"'", "text": "Ein neuer Mutli-Upload ist verfügbar!", "disable_notification": true}' https://api.telegram.org/bot$TG_API_KEY/sendMessage
                                                rm "$PROCESSED/$DATE$FILENAME" && echo MULTI: "Verarbeite Datei enfernt"
                                                echo "MULTI: ${green}Upload erfolgreich, beginne die Suche nach neuem Scan${reset}"

                                                # Wenn der Upload nicht erfolgreich ist wird ein erneuter Versuch gestartet und per Telegram über den Fehlschalg berichtet
                                                else
                                                        echo "MULTI: ${red}FTP Upload nicht erfolgreich, warte $FAIL_PAUSE Sekunden bis ich es erneut versuche${reset}"

                                                        curl -X POST \
                                                        -H 'Content-Type: application/json' \
                                                        -d '{"chat_id": "'"$TG_CHAT_ID"'", "text": "**FEHLER:** Mutli-Upload aus Bünde Fehlgeschlagen, versuche erneuten Upload..", "disable_notification": true}' \
                                                        https://api.telegram.org/bot$TG_API_KEY/sendMessage

                                                        sleep $FAIL_PAUSE

                                                        # Versuche erneut die Datei hochzuladen, solange der erste befehl hinter dem backslash nicht erfolgreich war, werden alle folgenden befehle ingoriert und ein neuer versuche wird gestartet
                                                        until ftp-upload --passive -h $FTP_HOST -u $FTP_USER --password $FTP_PASSWORD "$PROCESSED$DATE$FILENAME" \
                                                        && curl -X POST -H 'Content-Type: application/json' -d '{"chat_id": "'"$TG_CHAT_ID"'", "text": "Nachträglicher Multi-Upload erfolgreich, alles wieder im Lot", "disable_notification": true}' https://api.telegram.org/bot$TG_API_KEY/sendMessage \
                                                        && echo "MULTI: ${green}Upload nach mehren versuchen erfolgreich" \
                                                        && rm "$PROCESSED/$DATE$FILENAME" \
                                                        && echo "MULTI: ${green}Verarbeite Datei enfernt, suche wieder nach neuen Scans${reset}"

                                                        do
                                                        echo "MULTI: ${red}FTP Upload wieder nicht erfolgreich, warte $FAIL_PAUSE Sekunden${reset}"
                                                        sleep $FAIL_PAUSE
                                                        done
                                                fi
                                        else
                                                echo "Datei liegt, für die Abholung durch Paperless, bereit."
                                        fi
                                else
                                        echo "MULTI: ${red}Die Datei is korrupt, da die datei unter 100 kilobytes Groß ist${reset}" \
                                        && curl -X POST \
                                        -H 'Content-Type: application/json' \
                                        -d '{"chat_id": "'"$TG_CHAT_ID"'", "text": "**FEHLER:** Kritischer Fehler bei der Multi-PDF, die datei ist korrupt da unter 100kb", "disable_notification": true}' \
                                        https://api.telegram.org/bot$TG_API_KEY/sendMessage
                                fi
                        fi

                done