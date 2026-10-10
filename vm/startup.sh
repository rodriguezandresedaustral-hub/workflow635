#!/bin/bash
# Startup script de la VM (corre como root en cada arranque).
# Lo instala vm/lanzar.sh; no se usa a mano.
#
# 1. hace lo mismo que el startup de los templates de la catedra (gcloud config)
# 2. espera a ver el bucket montado (lo monta la imagen labo-family)
# 3. corre el workflow si no termino; retoma solo desde los checkpoints
# 4. si auto-delete=1: espera 30 min y borra la VM (termine bien o con error)

META=http://metadata.google.internal/computeMetadata/v1/instance
meta() { curl -sf -H "Metadata-Flavor: Google" "$META/$1"; }

PROYECTO=$(meta attributes/proyecto)
sudo -u ds gcloud config set project "$PROYECTO"

B=$(meta attributes/bucket-dir)
DIR="$B/$(meta attributes/wf-dir)"

for i in $(seq 120); do [ -f "$DIR/.env" ] && break; sleep 5; done
if [ ! -f "$DIR/.env" ]; then
  echo "startup: no veo $DIR/.env despues de 10 min: el bucket no esta montado"
  exit 1
fi

EXP=$(grep -E '^EXPERIMENTO=' "$DIR/.env" | cut -d= -f2 | tr -d '[:space:]')
FIN="$B/exp/WF$EXP/TERMINADO"

if [ ! -f "$FIN" ]; then
  sudo -u ds -H bash -lc "export PATH=\$HOME/.local/bin:\$PATH; cd '$DIR' && Rscript 635_workflow_senior.R .env >> log.txt 2>&1"
fi

if [ "$(meta attributes/auto-delete)" = "1" ]; then
  sleep 1800
  NOMBRE=$(meta name)
  ZONA=$(meta zone | awk -F/ '{print $NF}')
  gcloud compute instances delete "$NOMBRE" --zone "$ZONA" --project "$PROYECTO" --quiet
fi
