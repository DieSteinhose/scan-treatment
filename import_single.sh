#!/bin/bash

#CONFIG

TARGET=/data/import/
PROCESSED=/data/export/

red=`tput setaf 1`
green=`tput setaf 2`
reset=`tput sgr0`

echo "Maintainer: Ollie Spila"
echo "Version: 3.1.0 - 21.03.2024 - SINGLE"



if [ "$FTP_UPLOAD" == "true" ]
then
        ftp-upload --passive -h $FTP_HOST -u $FTP_USER --password $FTP_PASSWORD $PROCESSED*.pdf && echo "Gegebenfalls nachträger Upload nach neustart" \
        && curl -X POST -H 'Content-Type: application/json' -d '{"chat_id": $"'"$TG_CHAT_ID"'", "text": "SINGLE: Das Programm wurde neugestartet, gegebenfalls verbleibende Dokumente wurden nachträglich Hochgeladen", "disable_notification": true}' https://api.telegram.org/bot$TG_API_KEY/sendMessage
        echo "FTP-Upload aktiviert"

else
        echo "FTP-Upload nicht aktiviert"
fi
#&& rm "$PROCESSED*.pdf" \ Baustelle

# Suchst nach neuer Datei im Zielordner, close_write wartet bis eine Datei zuende geschrieben ist. Da der Drucker wärend desssen er scannt schon die Datei schreibt.
inotifywait -m -e close_write --format "%f" $TARGET \
        | while read FILENAME
                do
                        sleep 2

                        # Erstellt variable DATE mit den inhalt des Datums + Uhrzeit
                        printf -v DATE '%(%Y-%m-%d_%H-%M-%S_)T' -1

                        if [[ "$FILENAME" == scan-sw*.pdf ]]

                        then
                                # Optimiert die eingehende PDF und speichert die in export Ordner

                                # Schwarzweiss
                                magick -density 300 "$TARGET$FILENAME" -chop 5x5 -deskew 60% +repage -strip -interlace Plane -normalize -posterize 3 +dither -compress LZW "$PROCESSED$DATE$FILENAME" \
                                && echo SINGLE: "${green}PDF verarbeitung in SW erfolgreich abgeschlossen${reset}"

                        else
                                # Farbe
                                ghostscript -q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=pdfwrite -dPDFSETTINGS=/ebook -dColorImageDownsampleType=/Bicubic -dColorImageResolution=300 -dGrayImageDownsampleType=/Bicubic -dGrayImageResolution=300 -sOutputFile="$PROCESSED$DATE$FILENAME" "$TARGET$FILENAME" \
                                && echo SINGLE: "${green}PDF verarbeitung in Farbe erfolgreich abgeschlossen${reset}" \

                        fi

                        # Löscht das Original
                        rm "$TARGET/$FILENAME" && echo SINGLE: ${green}Original erfolgreich gelöscht${reset}

                        if [ "$FTP_UPLOAD" == "true" ]
                        then

                                echo SINGLE: "${green}Starte nun Upload${reset}"

                                # Verbindet sich mit dem Server im Lemgo und versucht die verarbeitete Datei hochzuladen
                                if ftp-upload --passive -h $FTP_HOST -u $FTP_USER --password $FTP_PASSWORD "$PROCESSED$DATE$FILENAME"

                                # Sendet per Telegram die erfolgreiche Nachricht
                                then
                                curl -X POST -H 'Content-Type: application/json' -d '{"chat_id": "'"$TG_CHAT_ID"'", "text": "Ein neuer Upload ist verfügbar!", "disable_notification": true}' https://api.telegram.org/bot$TG_API_KEY/sendMessage
                                rm "$PROCESSED/$DATE$FILENAME" && echo "SINGLE: Verarbeite Datei enfernt"
                                echo "SINGLE: ${green}Upload erfolgreich, beginne die Suche nach neuem Scan${reset}"

                                # Wenn der Upload nicht erfolgreich ist wird ein erneuter Versuch gestartet und per Telegram über den Fehlschalg berichtet
                                else
                                        echo "SINGLE: ${red}FTP Upload nicht erfolgreich, warte $FAIL_PAUSE Sekunden bis ich es erneut versuche${reset}"

                                        curl -X POST \
                                        -H 'Content-Type: application/json' \
                                        -d '{"chat_id": "'"$TG_CHAT_ID"'", "text": "**FEHLER:** Upload aus Bünde Fehlgeschlagen, versuche erneuten Upload..", "disable_notification": true}' \
                                        https://api.telegram.org/bot$TG_API_KEY/sendMessage

                                        sleep $FAIL_PAUSE

                                        # Versuche erneut die Datei hochzuladen, solange der erste befehl hinter dem backslash nicht erfolgreich war, werden alle folgenden befehle ingoriert und ein neuer versuche wird gestartet
                                        until ftp-upload --passive -h $FTP_HOST -u $FTP_USER --password $FTP_PASSWORD "$PROCESSED$DATE$FILENAME" \
                                        && curl -X POST -H 'Content-Type: application/json' -d '{"chat_id": "'"$TG_CHAT_ID"'", "text": "Nachträglicher Upload erfolgreich, alles wieder im Lot", "disable_notification": true}' https://api.telegram.org/bot$TG_API_KEY/sendMessage \
                                        && echo "SINGLE: ${green}Upload nach mehren versuchen erfolgreich" \
                                        && rm "$PROCESSED/$DATE$FILENAME" \
                                        && echo "SINGLE: ${green}Verarbeite Datei enfernt, suche wieder nach neuen Scans${reset}"

                                        do
                                        echo "SINGLE: ${red}FTP Upload wieder nicht erfolgreich, warte $FAIL_PAUSE Sekunden${reset}"
                                        sleep $FAIL_PAUSE
                                        done
                                fi

                        else
                                echo "Datei liegt, für die Abholung durch Paperless, bereit."
                        fi


                done