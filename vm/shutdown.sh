#!/bin/bash
# Shutdown script: si la VM fue expropiada (Spot), avisa por mail.
# GCP da ~30 segundos antes de apagarla; alcanza para un curl.

META=http://metadata.google.internal/computeMetadata/v1/instance
meta() { curl -sf -H "Metadata-Flavor: Google" "$META/$1"; }

[ "$(meta preempted)" = "TRUE" ] || exit 0

DIR="$(meta attributes/bucket-dir)/$(meta attributes/wf-dir)"
[ -f "$DIR/.env" ] || exit 0
set -a; . "$DIR/.env"; set +a
[ -f "$MAIL_PASS_FILE" ] && [ -f "$MAIL_TO_FILE" ] || exit 0

PARA=$(grep -v '^#' "$MAIL_TO_FILE" | sed '/^[[:space:]]*$/d')
RCPT=""
for d in $PARA; do RCPT="$RCPT --mail-rcpt $d"; done

M=$(mktemp)
printf "From: %s\nTo: %s\nSubject: [WF%s grupo %s] VM expropiada\n\nGCP expropio la VM %s.\nLo hecho esta en los checkpoints del bucket: relanzar con vm/lanzar.sh %s y retoma.\n" \
  "$MAIL_FROM" "$(echo $PARA | sed 's/ /, /g')" "$EXPERIMENTO" "$GRUPO" "$(meta name)" "$GRUPO" > "$M"

curl -s --max-time 20 --ssl-reqd --url smtps://smtp.gmail.com:465 \
  --mail-from "$MAIL_FROM" $RCPT \
  --user "$MAIL_FROM:$(head -1 "$MAIL_PASS_FILE" | tr -d '[:space:]')" -T "$M"
rm -f "$M"
