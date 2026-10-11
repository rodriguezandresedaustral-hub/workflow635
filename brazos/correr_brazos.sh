#!/bin/bash
# ===========================================================================
# Cola de brazos del workflow635 v2 en la VM (grupo B, 202107 con clase real)
#   E0 = sin genetica, E1 = genetica v2 (ganadoras forzadas, el veredicto del
#   control queda registrado), E2 = formulas al azar.
#   Por cada semilla del pipeline corre los tres brazos seguidos: si la cola se
#   corta a mitad, lo que termino ya esta pareado por semilla.
#
# Lanzar desde un usuario con sudo (cada corrida va como ds, duena del bucket):
#   nohup setsid bash brazos/correr_brazos.sh > /dev/null 2>&1 &
# Opcionales:
#   SEMILLAS="100213 100313"  BRAZOS="E0"  REINTENTOS=1
#   APAGAR=1               apaga la VM cuando termina la cola
#   BORRAR_CHECKPOINTS=1   borra los .fst de checkpoints/ de cada corrida TERMINADA
# Para frenar al terminar la corrida en curso: touch $EXP/brazos_v2/PARAR
# Una corrida con TERMINADO se saltea; una que fallo se relanza y retoma desde
# sus checkpoints.
# ===========================================================================
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
EXP=/home/ds/buckets/b1/exp
LOGS=$EXP/brazos_v2
SEMILLAS=${SEMILLAS:-"100213 100313 100613 100913 101113 570991"}
BRAZOS=${BRAZOS:-"E0 E1 E2"}
REINTENTOS=${REINTENTOS:-1}
APAGAR=${APAGAR:-0}
BORRAR_CHECKPOINTS=${BORRAR_CHECKPOINTS:-1}

# el bucket es de ds: la cola corre como ds y, si hace falta, apaga desde afuera
if [ "$(id -un)" != ds ]; then
  sudo -u ds -H env SEMILLAS="$SEMILLAS" BRAZOS="$BRAZOS" REINTENTOS="$REINTENTOS" \
    BORRAR_CHECKPOINTS="$BORRAR_CHECKPOINTS" bash "$DIR/brazos/correr_brazos.sh"
  rc=$?
  [ "$APAGAR" = 1 ] && sudo poweroff
  exit $rc
fi

mkdir -p "$LOGS"
exec 9>/tmp/correr_brazos.lock
flock -n 9 || { echo "ya hay una cola corriendo"; exit 1; }

log() { echo "$(date '+%F %T') | $*" >> "$LOGS/cola.log"; }
VERSION="v2 $(md5sum "$DIR/635_workflow_senior.R" | cut -c1-8)"
[ -f "$LOGS/tiempos.tsv" ] || printf 'corrida\tbrazo\tsemilla\tintento\trc\tminutos\n' > "$LOGS/tiempos.tsv"
log "cola: semillas [$SEMILLAS] brazos [$BRAZOS] script $VERSION"

# paquetes una sola vez, antes de la primera corrida
Rscript -e '
lib <- Sys.getenv("R_LIBS_USER"); dir.create(lib, recursive= TRUE, showWarnings= FALSE)
.libPaths(c(lib, .libPaths()))
p <- c("data.table", "R.utils", "fst", "gramEvol", "lightgbm", "mlrMBO", "DiceKriging",
       "lhs", "lubridate", "mice", "yaml", "Rcpp")
f <- p[!vapply(p, requireNamespace, logical(1), quietly= TRUE)]
if (length(f)) install.packages(f, lib= lib, repos= "https://cloud.r-project.org",
                                Ncpus= parallel::detectCores())
f <- p[!vapply(p, requireNamespace, logical(1), quietly= TRUE)]
if (length(f)) { cat("FALTAN:", f, "\n"); quit(status= 1) }
cat("paquetes OK\n")' >> "$LOGS/paquetes.log" 2>&1 || { log "faltan paquetes: ver paquetes.log"; exit 1; }

for s in $SEMILLAS; do
  for b in $BRAZOS; do
    if [ -f "$LOGS/PARAR" ]; then log "PARAR: freno la cola"; exit 0; fi
    ENV=$DIR/brazos/$b.env
    NUM=$(sed -n 's/^EXPERIMENTO=//p' "$ENV")
    RUN=WF${NUM}_s$s
    if [ -f "$EXP/$RUN/TERMINADO" ]; then log "$RUN ya estaba terminada"; continue; fi
    for intento in $(seq 0 "$REINTENTOS"); do
      log "$RUN arranca (intento $intento, $(free -g | awk '/^Mem/{print $7}') GB libres)"
      t0=$(date +%s)
      ( cd "$DIR" && WF_VERSION="$VERSION" Rscript 635_workflow_senior.R "$ENV" "$s" ) >> "$LOGS/$RUN.log" 2>&1
      rc=$?
      min=$(( ($(date +%s) - t0) / 60 ))
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$RUN" "$b" "$s" "$intento" "$rc" "$min" >> "$LOGS/tiempos.tsv"
      if [ -f "$EXP/$RUN/TERMINADO" ]; then
        log "$RUN TERMINADO en $min min, meseta $(cat "$EXP/$RUN/ganancia_meseta.txt" 2>/dev/null)"
        [ "$BORRAR_CHECKPOINTS" = 1 ] && rm -f "$EXP/$RUN"/checkpoints/*.fst
        break
      fi
      log "$RUN fallo (rc $rc, $min min): ver $LOGS/$RUN.log"
    done
    Rscript "$DIR/brazos/analizar_brazos.R" "$EXP" > "$LOGS/analisis.txt" 2>&1 || log "analizar_brazos.R fallo: ver analisis.txt"
  done
done
log "cola terminada"
