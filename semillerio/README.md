# semillerio

El modelo que elegimos como entrega final: el pipeline de FE con
hiperparámetros fijos (sin BO) y un semillerío grande, ensamblado con las
semillas de los dos.

| | |
|---|---|
| Entrega final | `KAF4_s144_10500.csv`: 144 modelos, corte en 10.500 envíos |
| Public | **457,331** (en 11.000: 455,164) |
| Semillas | 271211 353161 487757 641371 823541 100213 100313 100613 100913 101113 |
| Modelos | 271211 con 36, cada una de las otras 9 con 12 |

## Qué hace `semillerio.R`

1. Meses rotos a NA (los campos que en 201904, 201905, 201910, 202006, etc.
   vienen en cero).
2. Deflación por IPC de todas las variables monetarias.
3. FE intra mes: `ctrx_quarter` normalizado por antigüedad, transacciones del
   trimestre, `mpayroll / edad` y las combinaciones Visa + Master (`vm_*`,
   `vmr_*`).
4. FE histórico: lags 1 y 2, deltas 1 y 2 y la tendencia de 6 meses.
5. Variables de random forest: 20 árboles de 16 hojas entrenados en
   202101 – 202103; cada hoja es una variable 0/1.
6. Canaritos (ratio 0.2, mediana + 2 desvíos) para podar.
7. Final train con pesos temporales (0.5 el mes más viejo, 1.0 el más
   nuevo) y N semillas. La predicción es el promedio.

Hiperparámetros fijos: 1004 iteraciones, 2035 hojas, learning rate 0.0238,
feature fraction 0.417, min sum hessian 0.171.

## Correr

Todo por variables de entorno (los defaults están en el encabezado del script):

```bash
# final: entrena 201901-202107, predice 202109, deja los cortes en kaggle/
SEMILLA=353161 SEMILLERIO=12 EXPERIMENTO=9921 Rscript semillerio/semillerio.R

# backtest: entrena hasta 202105, predice 202107 y graba ganancias_semillas.txt
MODO=backtest SEMILLA=271211 SEMILLERIO=10 EXPERIMENTO=9907 Rscript semillerio/semillerio.R

# ablaciones
MODO=backtest LAGS=0 SEMILLA=271211 SEMILLERIO=10 EXPERIMENTO=9911 Rscript semillerio/semillerio.R
MODO=backtest CANARITOS=0 SEMILLA=271211 SEMILLERIO=10 EXPERIMENTO=9912 Rscript semillerio/semillerio.R
```

Necesita más de 150 GB de RAM (sumando swap) por el FE histórico. Graba un
modelo por semilla en `modelos/`; si la máquina se corta, se relanza igual y
sigue desde el último.

Para juntar varias corridas:

```bash
Rscript semillerio/ensamblar_semillas.R /home/ds/buckets/b1/exp/F4 \
  /home/ds/buckets/b1/exp/WF9905 /home/ds/buckets/b1/exp/WF9921 ...
```

Promedia todas las `prob_<i>` juntas, así cada modelo pesa lo mismo (no cada
corrida, como `ensamblar.R`).

## Replicar la entrega final (KAF4)

Son 10 corridas de `semillerio.R` en modo final, una por semilla, que solo
cambian la semilla primigenia y la cantidad de modelos:

| Experimento | Semilla | Modelos |
|---|---|---|
| 9905 | 271211 | 36 |
| 9921 | 353161 | 12 |
| 9922 | 487757 | 12 |
| 9923 | 641371 | 12 |
| 9924 | 823541 | 12 |
| 9925 | 100213 | 12 |
| 9926 | 100313 | 12 |
| 9927 | 100613 | 12 |
| 9928 | 100913 | 12 |
| 9929 | 101113 | 12 |

```bash
cd workflow635
export THREADS=32   # las corridas originales usaron 32 hilos

SEMILLA=271211 SEMILLERIO=36 EXPERIMENTO=9905 Rscript semillerio/semillerio.R
SEMILLA=353161 SEMILLERIO=12 EXPERIMENTO=9921 Rscript semillerio/semillerio.R
SEMILLA=487757 SEMILLERIO=12 EXPERIMENTO=9922 Rscript semillerio/semillerio.R
SEMILLA=641371 SEMILLERIO=12 EXPERIMENTO=9923 Rscript semillerio/semillerio.R
SEMILLA=823541 SEMILLERIO=12 EXPERIMENTO=9924 Rscript semillerio/semillerio.R
SEMILLA=100213 SEMILLERIO=12 EXPERIMENTO=9925 Rscript semillerio/semillerio.R
SEMILLA=100313 SEMILLERIO=12 EXPERIMENTO=9926 Rscript semillerio/semillerio.R
SEMILLA=100613 SEMILLERIO=12 EXPERIMENTO=9927 Rscript semillerio/semillerio.R
SEMILLA=100913 SEMILLERIO=12 EXPERIMENTO=9928 Rscript semillerio/semillerio.R
SEMILLA=101113 SEMILLERIO=12 EXPERIMENTO=9929 Rscript semillerio/semillerio.R

E=/home/ds/buckets/b1/exp
Rscript semillerio/ensamblar_semillas.R $E/F4 \
  $E/WF9905 $E/WF9921 $E/WF9922 $E/WF9923 $E/WF9924 \
  $E/WF9925 $E/WF9926 $E/WF9927 $E/WF9928 $E/WF9929
```

Las corridas son independientes, se pueden repartir en varias máquinas (cada
una tarda varias horas). La entrega es `$E/F4/kaggle/KAF4_s144_10500.csv`.

## Backtest (predice 202107, 10 semillas)

Las tres corridas usan las mismas 10 semillas, así que se comparan de a pares.

| | Semillerío, meseta | en 10.000 | en 10.500 | Semillas que le ganan a la base |
|---|---|---|---|---|
| Base | **621,4 M** | 620,0 M | 619,5 M | |
| Sin lags (solo deltas) | 617,3 M | 606,0 M | | 4/10 en meseta, 0/10 en 10.000 |
| Sin canaritos | 600,8 M | | | 0/10 |

- La base llega a 622,8 M en 10.207 envíos. Las semillas solas van de 605,6 M
  a 625,9 M en la meseta: el semillerío está arriba de casi todas.
- Sacar los lags pierde poco en la meseta (−4,1 M en promedio) pero cerca de
  10.000 envíos pierde siempre (−8,5 M). Se quedan.
- Sacar los canaritos pierde en todas las semillas (−18,5 M en la meseta).
  Se quedan.

## Kaggle (public)

| Envío | Modelos | 10.500 | 11.000 |
|---|---|---|---|
| KAF2 | 44 | 461,248 | 458,831 |
| KAF3 | | 457,748 | |
| **KAF4** (solo nuestras semillas) | 144 | **457,331** | 455,164 |

KAF2 tiene semillas que no son las nuestras, por eso no la usamos. Entre KAF3
y KAF4 la diferencia en el public es chica; nos quedamos con la de más
modelos, que debería ser la más estable en el private.
