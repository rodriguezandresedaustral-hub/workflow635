#!/bin/bash
# Startup script de la VM (corre como root en cada arranque).
# Lo instala vm/lanzar.sh en el template; no se usa a mano.
#
# 1. hace lo mismo que el startup de los templates de la catedra (gcloud config)
# 2. espera a ver el bucket montado (lo monta la imagen labo-family)
# 3. corre el workflow si no termino; retoma solo desde los checkpoints
# 4. al salir R, por lo que sea, espera 30 min y baja el grupo a 0, asi no se
#    recrea. Solo una expropiacion (que no pasa por aca) hace que se recree.

META=http://metadata.google.internal/computeMetadata/v1/instance
meta() { curl -sf -H "Metadata-Flavor: Google" "$META/$1"; }

PROYECTO=$(meta attributes/proyecto)
MIG=$(meta attributes/mig)
ZONA=$(meta zone | awk -F/ '{print $NF}')
sudo -u ds gcloud config set project "$PROYECTO"

B=$(meta attributes/bucket-dir)
DIR="$B/$(meta attributes/wf-dir)"

for i in $(seq 120); do [ -f "$DIR/.env" ] && break; sleep 5; done
if [ ! -f "$DIR/.env" ]; then
  # sin .env no hay mail: queda en el serial port. Se baja el grupo para no
  # dejar la VM prendida cobrando
  echo "startup: no veo $DIR/.env despues de 10 min: el bucket no esta montado. Bajo el grupo a 0"
  gcloud compute instance-groups managed resize "$MIG" --zone "$ZONA" --project "$PROYECTO" --size 0
  exit 1
fi

set -a; . "$DIR/.env"; set +a
FIN="$B/exp/WF$EXPERIMENTO/TERMINADO"

mail() {   # mail <titulo> <cuerpo>
  [ -f "$MAIL_PASS_FILE" ] && [ -f "$MAIL_TO_FILE" ] || return 0
  local para rcpt="" m
  para=$(grep -v '^#' "$MAIL_TO_FILE" | sed '/^[[:space:]]*$/d')
  for d in $para; do rcpt="$rcpt --mail-rcpt $d"; done
  m=$(mktemp)
  printf "From: %s\nTo: %s\nSubject: [WF%s grupo %s] %s\n\n%s\n" \
    "$MAIL_FROM" "$(echo $para | sed 's/ /, /g')" "$EXPERIMENTO" "$GRUPO" "$1" "$2" > "$m"
  curl -s --max-time 30 --ssl-reqd --url smtps://smtp.gmail.com:465 \
    --mail-from "$MAIL_FROM" $rcpt \
    --user "$MAIL_FROM:$(head -1 "$MAIL_PASS_FILE" | tr -d '[:space:]')" -T "$m"
  rm -f "$m"
}

if [ ! -f "$FIN" ]; then
  sudo -u ds -H bash -lc "export PATH=\$HOME/.local/bin:\$PATH; cd '$DIR' && Rscript 635_workflow_senior.R .env >> log.txt 2>&1"
  RC=$?
  # rc 1 = error que R ya aviso por mail. Otro rc sin TERMINADO = R murio sin
  # poder avisar (por ejemplo, sin memoria): aviso aca.
  if [ ! -f "$FIN" ] && [ "$RC" != "1" ]; then
    mail "R termino sin terminar (codigo $RC)" \
      "Rscript salio con codigo $RC y sin TERMINADO. Probable falta de memoria. Ver $DIR/log.txt. La VM se apaga en 30 min y no se recrea."
  fi
fi

if [ "$(meta attributes/apagar-al-terminar)" = "1" ]; then
  sleep 1800
  gcloud compute instance-groups managed resize "$MIG" --zone "$ZONA" --project "$PROYECTO" --size 0
fi
