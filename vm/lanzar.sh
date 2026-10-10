#!/bin/bash
# Crea la VM de un grupo desde un template de la catedra y lanza el workflow.
#
#   vm/lanzar.sh A        (o B)
#
# Sube 635_workflow_senior.R y .env.<grupo> al bucket (gs://$BUCKET/wf635/<grupo>/)
# y crea la VM con vm/startup.sh y vm/shutdown.sh. Relanzar despues de una
# expropiacion es correr lo mismo: el script retoma desde los checkpoints.
set -euo pipefail
cd "$(dirname "$0")/.."

G=$(echo "${1:?uso: vm/lanzar.sh A|B}" | tr '[:lower:]' '[:upper:]')
[ "$G" = "A" ] || [ "$G" = "B" ] || { echo "el grupo es A o B"; exit 1; }

[ -f vm/vm.env ] || { echo "falta vm/vm.env (copiar vm/vm.env.example y completarlo)"; exit 1; }
. vm/vm.env
for v in PROJECT REGION ZONE TEMPLATE BUCKET BUCKET_DIR_VM VM_PREFIJO AUTO_DELETE; do
  [ -n "${!v:-}" ] || { echo "falta $v en vm/vm.env"; exit 1; }
done

ENVF=".env.$G"
[ -f "$ENVF" ] || { echo "falta $ENVF (copiar .env.example y completarlo)"; exit 1; }
grep -q "^GRUPO=$G\$" "$ENVF" || { echo "$ENVF no dice GRUPO=$G"; exit 1; }

# cuota global de vCPUs del proyecto
read LIMITE USO < <(gcloud compute project-info describe --project "$PROJECT" \
  --flatten=quotas --filter="quotas.metric=CPUS_ALL_REGIONS" \
  --format="value(quotas.limit,quotas.usage)")
VCPU=$(gcloud compute instance-templates describe "$TEMPLATE" --region "$REGION" --project "$PROJECT" \
  --format="value(properties.machineType)" | cut -d- -f3)
echo "cuota CPUS_ALL_REGIONS: usadas ${USO%.*} de ${LIMITE%.*}; el template $TEMPLATE pide $VCPU"
if [ $(( ${USO%.*} + VCPU )) -gt ${LIMITE%.*} ]; then
  echo "NO ENTRA en la cuota: apagar otra VM o usar un template mas chico"; exit 1
fi

DIR="wf635/$G"
NOMBRE="$VM_PREFIJO-$(echo "$G" | tr '[:upper:]' '[:lower:]')"

# en Windows los archivos pueden quedar con CRLF, que rompe bash y el .env en la VM
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
for f in 635_workflow_senior.R "$ENVF" vm/startup.sh vm/shutdown.sh; do
  tr -d '\r' < "$f" > "$TMP/$(basename "$f")"
done

gsutil cp "$TMP/635_workflow_senior.R" "gs://$BUCKET/$DIR/635_workflow_senior.R"
gsutil cp "$TMP/$ENVF" "gs://$BUCKET/$DIR/.env"

gcloud compute instances create "$NOMBRE" --project "$PROJECT" --zone "$ZONE" \
  --source-instance-template "projects/$PROJECT/regions/$REGION/instanceTemplates/$TEMPLATE" \
  --metadata-from-file startup-script="$TMP/startup.sh",shutdown-script="$TMP/shutdown.sh" \
  --metadata wf-dir="$DIR",bucket-dir="$BUCKET_DIR_VM",auto-delete="$AUTO_DELETE",proyecto="$PROJECT"

echo
echo "VM $NOMBRE creada. Log:  gsutil cat gs://$BUCKET/$DIR/log.txt | tail"
