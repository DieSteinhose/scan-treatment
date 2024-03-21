## SMB Freigaben

nach /data/

docker run --rm -it  printers2paperless:latest -v "$(pwd)"/target:/app


Idee:
1) try adding -compress JPG -quality 80 ( or whatever quality you want for the jpg). I do not know if this will work.
bzw: try -compress JPEG


Evenutell /etc/ImageMagick-6/delegates.xml anpassen damit imagemagick/convert gs umwandlungen direkt vornimmt, spart ein schritt


## Interesannte Commands

 pdfimages -list scan-sw.pdf


# Fehler beim umwandeln von Scan zu convert pdf
https://github.com/ImageMagick/ImageMagick/issues/2070


magick -density 600 -quality 20 -compress jpeg ROHDATEI.pdf -strip -interlace Plane -sampling-factor 4:2:0 -normalize -gamma 0.8,0.8,0.8 +dither -posterize 3 BEARBEITET.pdf

-quality 60 -compress jpeg

## Optimiert
magick -density 300 IMPORT.pdf -strip -interlace Plane -normalize -gamma 0.8,0.8,0.8 +dither -posterize 3 -compress LZW EXPORT.pdf

### Optimiet für SW
magick -density 300 scan-sw.pdf -strip -interlace Plane -normalize -posterize 3 +dither -compress LZW export.pdf

Für Farbe Suboptimal

## Ideen für Farbig
gswin64c.exe -sOutputFile=out.pdf -dNOPAUSE -dBATCH ^-sDEVICE=pdfwrite -dPDFSETTINGS=/prepress -c "<< /ColorACSImageDict << /VSamples [ 1 1 1 1 ] /HSamples [ 1 1 1 1 ] /QFactor 0.08 /Blend 1 >> /ColorImageDownsampleType /Bicubic /ColorConversionStrategy /LeaveColorUnchanged >> setdistillerparams" -f in1.pdf

### Origig
ghostscript -q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=pdfwrite -dPDFSETTINGS=/ebook -dColorImageDownsampleType=/Bicubic -dColorImageResolution=300 -dGrayImageDownsampleType=/Bicubic -dGrayImageResolution=300 -sOutputFile="$PROCESSED$DATE$FILENAME" "$TARGET$FILENAME"

# Optimiert (vorerst) für Farbig (gleiche wie Orig)

ghostscript -q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=pdfwrite -dPDFSETTINGS=/ebook -dColorImageDownsampleType=/Bicubic -dColorImageResolution=300 -dGrayImageDownsampleType=/Bicubic -dGrayImageResolution=300 -sOutputFile="$PROCESSED$DATE$FILENAME" "$TARGET$FILENAME" \


## Testing Farbig (TODO)
Hat ganz gute ergebnisse, posterize könnte man noch anpassen

magick -density 300 scan-farbe.pdf -strip -interlace Plane -gamma 0.7,0.7,0.7 -posterize 8 -compress JPEG -quality 20% fine-tuning-EXPORT-mit_dithering-mit_inter_plane-post_8-gamma_0.7-ohne_normalize_in_jpg-20.pdf


magick source.jpg -strip -interlace Plane -sampling-factor 4:2:0 -quality 20% result.jpg


## Image mit ImageMagick7
dpokidov/imagemagick:latest-ubuntu


## TODO
- Wenn Container startet und in export noch dateien sind, diese bei Start hochladen (Done)
- Amazon Dash button support in Container hinzufügen (Done)
- Sobald die Verarbeitung anfängt, die Datein in einen neuen Verzeichnis schieben, um direkt den nächsten Scan zu ermöglichen