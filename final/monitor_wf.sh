#!/bin/bash
# Monitor del final training de WF9703. Corre como ds en la VM, aparte de R.
# Cada 5 min agrega a exp/WF9703/monitor.txt: CPU y RAM de R, memoria libre,
# modelos grabados, el modelo en curso y hace cuanto empezo.
# Si un modelo pasa ALERTA_MIN minutos, manda un mail (una vez por modelo).
EXP=WF9703
B=/home/ds/buckets/b1
DIR=$B/exp/$EXP
LOG=$HOME/log_$EXP.txt
OUT=$HOME/monitor_$EXP.txt
ALERTA_MIN=90
set -a; . <(tr -d '\r' < $B/wf635fin/B/.env); set +a

mail() {
  local para rcpt="" m
  para=$(grep -v '^#' "$MAIL_TO_FILE" | sed '/^[[:space:]]*$/d')
  for d in $para; do rcpt="$rcpt --mail-rcpt $d"; done
  m=$(mktemp)
  printf "From: %s\nTo: %s\nSubject: [%s] %s\n\n%s\n" "$MAIL_FROM" "$(echo $para | sed 's/ /, /g')" "$EXP" "$1" "$2" > "$m"
  curl -s --max-time 30 --ssl-reqd --url smtps://smtp.gmail.com:465 --mail-from "$MAIL_FROM" $rcpt \
    --user "$MAIL_FROM:$(head -1 "$MAIL_PASS_FILE" | tr -d '[:space:]')" -T "$m"
  rm -f "$m"
}

ALERTADO=""
while true; do
  PID=$(pgrep -f "exec/R .*635_workflow_senior.R" | head -1)
  AHORA=$(date -u +%s)
  ULT=$(grep -h " modelo " "$LOG" 2>/dev/null | tail -1)
  EN_CURSO=""; MIN=""
  if echo "$ULT" | grep -q " inicio"; then
    EN_CURSO=$(echo "$ULT" | awk '{print $4}')
    T0=$(date -u -d "$(echo "$ULT" | awk '{print $1" "$2}')" +%s)
    MIN=$(( (AHORA - T0) / 60 ))
  fi
  {
    echo "=== $(date -u +%FT%TZ)"
    if [ -n "$PID" ]; then echo "R: pid $PID  $(ps -o pcpu=,rss=,etime= -p $PID | awk '{printf "cpu %s%%  ram %.0f GB  vivo %s", $1, $2/1048576, $3}')"
    else echo "R: NO ESTA CORRIENDO"; fi
    echo "memoria disponible: $(free -g | awk '/Mem:/ {print $7}') GB"
    echo "modelos grabados: $(ls $DIR/modelos 2>/dev/null | wc -l)"
    grep -h " modelo .* fin" "$LOG" 2>/dev/null | tail -1 | sed 's/^/ultimo terminado: /'
    [ -n "$EN_CURSO" ] && echo "en curso: modelo $EN_CURSO desde hace $MIN min"
    grep -h "train's auc" "$LOG" 2>/dev/null | tail -1 | sed 's/^/ultima iteracion (stdout con buffer): /'
  } >> "$OUT"
  cp "$OUT" "$DIR/monitor.txt"

  if [ -n "$EN_CURSO" ] && [ "$MIN" -gt "$ALERTA_MIN" ] && [ "$ALERTADO" != "$EN_CURSO" ]; then
    mail "modelo $EN_CURSO lleva $MIN min" "El modelo $EN_CURSO del final training lleva $MIN minutos (los normales tardan ~45). Ver $DIR/monitor.txt"
    ALERTADO=$EN_CURSO
  fi
  if [ -z "$PID" ]; then
    [ -f "$DIR/TERMINADO" ] && mail "termino" "WF9703 termino. Resultados en $DIR (eval_*.txt, grafico_*.png)" \
                            || mail "R no esta corriendo" "R no esta corriendo y no hay TERMINADO. Ver $LOG"
    break
  fi
  sleep 300
done
