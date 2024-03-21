#!/bin/bash

# Starte fuer Single PDFs

./import_multi.sh &

# Starte fuer Multi PDFs

./import_single.sh &

# Starte Dash Button Service

amazon-dash --root-allowed && echo Amazon Dash Service wurde gestartet