# Experimento de brazos v3 (grupo B)

¿El **FE evolutivo** (PR 8) mejora el modelo final? Se mide con el workflow
entero contra la clase real de 202107 (grupo B), varias semillas del
pipeline y, en cada semilla, todos los brazos con todo lo demás igual.

| Brazo | Experimento | Qué cambia | Pregunta |
|---|---|---|---|
| E0 | WF9920 | `GA_MODO=nada` | la base de la cátedra, con canaritos |
| E5 | WF9925 | `GA_MODO=nada`, `CN_RUN=0` | la base sin canaritos (el evolutivo los apaga) |
| E6 | WF9926 | `GA_MODO=evolutivo`, pasa (`X * 1`) lo que tiene importancia, hijos en el resto | el evolutivo |
| E7 | WF9927 | E6 con `EV_SELECCION=azar` | ¿sirve la importancia para elegir qué pasa y quién se reproduce? |
| E8 | WF9928 | E6 con `EV_MIN_HIJOS=1` (sin copias) | ¿sirve que lo bueno pase igual (`X * 1`)? |
| E9 | WF9929 | E0 con `FT_ALFA=0.95` | pesos temporales 0,95^k en el final train |

Comparaciones fijadas antes de correr (`analizar_brazos.R`):

- **E6 − E5**: lo que aporta el evolutivo, los dos sin canaritos.
- **E6 − E0**: el evolutivo contra la base de la cátedra.
- **E6 − E7**: si da lo mismo, la importancia no sirve para seleccionar.
- **E6 − E8**: lo que aporta el clon.
- **E5 − E0**: lo que cambia por no correr canaritos (para leer E6 − E0).
- **E9 − E0**: los pesos alfa, solos.

**Métrica:** la **meseta** de cada corrida (promedio de los 9 cortes de 8.000
a 12.000 de `ganancia_202107.txt`, también en `ganancia_meseta.txt`),
pareada por semilla, con **Wilcoxon de rangos con signo** y Holm sobre las 6
comparaciones. El máximo de la curva (la métrica de la clase, última fila,
en `ganancia_maximo.txt`) sale como secundaria: el PR 9 (`validacion/`)
mostró que es optimista en 10–12 M y tiene unas 4 veces peor señal/ruido. Con n semillas el p más chico
posible es 2/2^n: hacen falta al menos 6 (0,031); con 10, 0,002. Las 10 por
defecto: 100213, 271211, 100313, 353161, 100613, 487757, 100913, 641371,
101113 y 823541. Más semillas: `SEMILLAS="..."`.

Lo que no se compara está fijo en todos los brazos: HT fija (`HT_FIJO`, la BO
de WF9600; la importancia del evolutivo sale del LightGBM de canaritos), final
train de 3 semillas con el 20% de los CONTINUA, sin mail y sin Kaggle. Ojo:
esa BO se hizo con el dataset después de canaritos (~450 columnas); en E5–E8
el modelo ve ~1.100–1.200.

## Experimentos rápidos ("locos")

Para probar una idea en minutos antes de gastar una cola entera, en el `.env`
de un brazo nuevo:

```
EV_GENERACIONES=3
FT_SEMILLAS_N=1
```

y `SEMILLAS="100213 271211 100313"`. Si algo se ve, recién ahí 10 semillas.

## RAM

El dataset del grupo B pesa ~50 GB en memoria. El evolutivo no lo agranda:
la población queda fija en las columnas iniciales y cada original muerta se
borra apenas la calcula la última fórmula que la usa. La cola anota la RAM
usada cada minuto en `ram_<corrida>.tsv` y el máximo en `cola.log` y en
`analisis.txt`. Igual conviene mirar `htop` en la primera corrida de cada
brazo nuevo.

## Antecedente: brazos v2 (2026-10-13)

La genética de gramEvol (una fórmula ganadora por ronda) no le ganó a sortear
fórmulas: E1 − E2 −1,58 M (gana 5 de 10, p 0,32), y el control dejó pasar 2
de 30 rondas, lo que se espera por azar. Eso, más lo de la clase, es lo que
llevó a la v3. Los resultados quedan en `exp/brazos_v2/analisis.txt`.

## Archivos

- `E0.env`, `E5.env` a `E9.env`: los brazos. Revisar `BUCKET_DIR`,
  `DATASET_PATH` y `HT_FIJO`.
- `correr_brazos.sh`: la cola, semillas × brazos. Corre todos los brazos de
  cada semilla seguidos (si se corta a mitad, lo terminado ya está pareado),
  saltea lo que tiene `TERMINADO` y relanza lo que falló, que retoma desde
  sus checkpoints (el evolutivo, desde la última generación terminada).
- `analizar_brazos.R`: Wilcoxon apareado sobre la meseta (principal) y el máximo, el
  evolutivo generación por generación (población, originales vivas,
  generadas, profundidad, % de importancia de las generadas, fórmulas
  nacidas) y cuántas generadas usa el modelo final.

## Cómo correrlo

En una VM con el bucket montado, con el repo copiado en
`/home/ds/buckets/b1/wf635v3`. La cola corre como `ds`, dueña del bucket, y
se lanza desde un usuario con sudo para que apague al terminar:

```bash
cd /tmp
nohup setsid bash -c 'sudo -u ds -H bash /home/ds/buckets/b1/wf635v3/brazos/correr_brazos.sh; sudo poweroff' > ~/cola_brazos.log 2>&1 < /dev/null &
```

Una sola corrida de prueba, sin apagar:

```bash
cd /tmp
sudo -u ds -H env SEMILLAS=100213 BRAZOS=E6 bash /home/ds/buckets/b1/wf635v3/brazos/correr_brazos.sh
```

Todo queda en `exp/brazos_v3/`: `cola.log`, `WF992x_s<semilla>.log`,
`analisis.txt` (se actualiza después de cada corrida), `brazos.csv`,
`evolutivo.csv`, `tiempos.tsv` y `ram_*.tsv`. Para frenar al terminar la
corrida en curso: `touch /home/ds/buckets/b1/exp/brazos_v3/PARAR`.
