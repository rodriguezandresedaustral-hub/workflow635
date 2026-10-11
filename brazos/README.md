# Experimento de brazos (grupo B)

¿Las variables de la genética mejoran el **modelo final**? El fitness es un
LightGBM chico sobre una muestra sin lags, así que no alcanza con que ganen en
la búsqueda: hay que pasarlas por el workflow entero y medir contra la clase
real. Una corrida en el LB público no sirve para esto: el público es el 30%
de 202109 y el desvío de la diferencia entre dos corridas ronda los 7 M.

Por eso: grupo B (ganancia real en 202107), varias semillas del pipeline y,
en cada semilla, tres brazos con todo lo demás igual.

| Brazo | Experimento | `GA_MODO` | Pregunta |
|---|---|---|---|
| E0 | WF9900 | `nada` | la base, sin FE genético |
| E1 | WF9901 | `genetica` + `GA_FORZAR=1` | ¿las 3 ganadoras de la genética mejoran el modelo final? |
| E2 | WF9902 | `azar` | ¿3 fórmulas cualquiera de la misma gramática hacen lo mismo? |

- **E1 − E0** es lo que aporta la genética.
- **E1 − E2** es lo que aporta *buscar*: si no es positivo, la búsqueda no
  sirve y alcanza con sortear fórmulas.
- E1 fuerza las ganadoras para medirlas siempre, pero registra el veredicto
  del control: se ve si las semillas donde el control dijo "sí" son las que
  ganan.
- Semillas: 100213, 100313, 100613, 100913, 101113 y 570991. Con Wilcoxon
  pareado hacen falta al menos 6 para poder llegar a p < 0,05 (el p más chico
  posible con 6 es 2/64 = 0,031).
- Métrica: `ganancia_meseta.txt`, el promedio de la ganancia en 202107 en los
  9 cortes fijos de 8.000 a 12.000 envíos.

Para que entre en un par de días de VM, lo que no se compara está fijo en los
tres brazos:

- **HT fija** (`HT_FIJO`): la mejor fila del `BO_log.txt` de una corrida base
  del grupo B; no se corre la BO. Los `.env` apuntan a la nuestra
  (`exp/WF9600`, z635 grupo B con 30 iteraciones). En otro bucket hay que
  apuntar a un `BO_log.txt` propio, o dejarla vacía y que cada corrida haga su
  BO (mucho más lento).
- **Final train** de 3 semillas (`FT_SEMILLAS_N=3`) con el 20% de los
  CONTINUA (`FT_UNDERSAMPLING=0.2`), como entrenó la BO.
- Sin mail (`MAIL_TO_FILE=/dev/null`) y sin Kaggle.

## Archivos

- `E0.env`, `E1.env`, `E2.env`: los tres brazos. Revisar `BUCKET_DIR`,
  `DATASET_PATH` y `HT_FIJO`.
- `correr_brazos.sh`: la cola, semillas × brazos. Corre los tres brazos de
  cada semilla seguidos (si se corta a mitad, lo terminado ya está pareado),
  saltea lo que tiene `TERMINADO` y relanza lo que falló, que retoma desde sus
  checkpoints.
- `analizar_brazos.R`: la comparación pareada. Tabla por semilla, diferencias
  con IC bootstrap de la media y Wilcoxon exacto, la genética ronda por ronda
  (búsqueda, umbral de 2 desvíos, control, puesto en la importancia) y las
  fórmulas al azar de E2.

## Cómo correrlo

En una VM con el bucket montado (no Spot: una corrida tarda horas y la cola,
más de un día), con el repo copiado en `/home/ds/buckets/b1/wf635v2`. La cola
corre como `ds`, dueña del bucket: en las VM de la cátedra los demás usuarios
no pueden leerlo, y `ds` no puede apagar la VM. Por eso se lanza desde un
usuario con sudo, envuelta en un `bash -c` que apaga al terminar:

```bash
cd /tmp
nohup setsid bash -c 'sudo -u ds -H bash /home/ds/buckets/b1/wf635v2/brazos/correr_brazos.sh; sudo poweroff' > ~/cola_brazos.log 2>&1 < /dev/null &
```

Para una sola corrida de prueba, sin apagar:

```bash
cd /tmp
sudo -u ds -H env SEMILLAS=100213 BRAZOS=E0 bash /home/ds/buckets/b1/wf635v2/brazos/correr_brazos.sh
```

Todo queda en `exp/brazos_v2/`:

- `cola.log`: avance de la cola.
- `WF990x_s<semilla>.log`: el log de cada corrida.
- `analisis.txt`: la comparación, que se actualiza después de cada corrida.
- `brazos.csv`, `genetica.csv`, `tiempos.tsv`: los datos.

Para frenar al terminar la corrida en curso:
`touch /home/ds/buckets/b1/exp/brazos_v2/PARAR`.

Opcionales de la cola (con `sudo -u ds -H env VAR=... bash ...`):
`SEMILLAS="..."`, `BRAZOS="..."`, `REINTENTOS=1` y `BORRAR_CHECKPOINTS=1`
(default: borra los `.fst` de `checkpoints/` de cada corrida terminada).
