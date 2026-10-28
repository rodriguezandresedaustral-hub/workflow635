# Experimentos finales (13 al 26 de octubre)

Todo lo que corrimos después de lo que ya está en `RESULTADOS.md`: los brazos de FE del workflow635 v2, los backtests del final train en 202107, las corridas finales sobre 202109, los ensambles y todos los envíos a Kaggle con su puntaje público y privado.

Ganancias en millones. "Meseta" es el promedio de la ganancia en los cortes 8000 a 12000 (cada 500).

## Archivos

| Archivo | Qué tiene |
|---|---|
| `backtest_202107.csv` | Ganancia por semilla y por corte de los 8 backtests del final train (WF9601-9604, WF9907-9912). La fila `semillerio` es el promedio de probabilidades de las 10 semillas |
| `kaggle_envios.csv` | Los 200 envíos del equipo con fecha, archivo, descripción, public y private |
| `brazos/analisis_dosis.txt` | Brazos E0-E8: meseta por semilla, diferencias pareadas, Wilcoxon con Holm y confirmación con semillas nuevas |
| `brazos/brazos.csv` | Una fila por corrida de brazo (semilla, meseta, máximo, horas) |
| `brazos/genetica.csv` | Fórmulas que encontró la búsqueda genética (E1, E3, E4) por ronda |
| `brazos/ensamble_dosis.txt`, `brazos/ensamble_curvas.csv` | Lo mismo pero ensamblando las semillas de cada brazo |
| `brazos/curva_cortes.*` | Ganancia del ensamble por corte y bootstrap del corte óptimo |
| `brazos/curva_total.txt`, `brazos/curva_total_resumen.csv` | Curva completa de ganancia de cada ensamble vs modelos sueltos |
| `semillerio_tamanio_202105.txt` | Meseta en 202105 según configuración y cantidad de semillas del semillerio |

## 1. Brazos de FE (workflow635 v2, validando en 202107)

Cada brazo es el pipeline base más una cosa. Comparación pareada por semilla.

| Brazo | Qué agrega | Meseta media |
|---|---|---|
| E0 | Base | 582,7 |
| E1 | Fórmulas buscadas con genética (fitness en 6 meses) | 584,4 |
| E2 | 3 fórmulas al azar | 586,0 |
| E3 | Genética con fitness en todos los meses | 582,8 |
| E4 | Genética buscando en el mes de la BO | 585,8 |
| E5 | 10 fórmulas al azar | 581,4 |
| E6 | 30 fórmulas al azar | 586,4 |
| E7 | 100 fórmulas al azar | 585,9 |
| E8 | E6 con final train sin undersampling | 586,1 |

- E2 - E0 = +2,9 con 20 semillas (gana 16 de 20, p = 0,010). E6 - E0 = +3,4 (p = 0,013).
- E6 - E2 no se distingue de cero. Buscar la fórmula con genética no le gana a tirarlas al azar.
- E8 vs E6: -0,4, sin diferencia.
- En el ensamble E6+E8 el corte óptimo da 12000 (bootstrap: p10 10000, p90 14000).

## 2. Backtests del final train (entrena hasta 202105, mide en 202107)

10 semillas por corrida.

| Corrida | Qué cambia | Meseta promedio por semilla | Meseta semillerio | Semillerio en 10500 |
|---|---|---|---|---|
| WF9601 | BO de 60 iteraciones con min_data_in_leaf, lambdas y bagging | 601,5 | 602,7 | 595,5 |
| WF9602 | Mismo espacio, otro óptimo (ff 0,05) | 611,7 | 615,8 | 608,5 |
| WF9603 | Base + min/max/promedio/ratios históricos, con su propia BO | 613,0 | 618,1 | 599,5 |
| WF9604 | FE base con hiperparámetros de BO (~237 hojas, ff 0,19) | 603,1 | 605,6 | 596,5 |
| **WF9907** | **FE base con los hiperparámetros fijos (la config final)** | 612,1 | **621,4** | **619,5** |
| WF9908 | Solo BAJA+2 como positivo | 599,2 | 616,4 | 608,5 |
| WF9911 | Sin lags | 608,0 | 617,3 | 608,5 |
| WF9912 | Sin canaritos | 593,5 | 600,8 | 595,5 |

Hiperparámetros fijos: 1004 iteraciones, 2035 hojas, learning rate 0,0238, feature_fraction 0,417, min_sum_hessian 0,171.

- La config final fue la mejor en semillerio, tanto en meseta como en el corte 10500.
- Sacar canaritos cuesta unos 20 millones; sacar lags, unos 4. Usar solo BAJA+2 como positivo, unos 5.
- Más FE histórico (WF9603) mejora el promedio por semilla pero no el semillerio.

## 3. Corridas finales (entrenan hasta 202107, predicen 202109)

| Corrida | Semillas | Notas |
|---|---|---|
| WF9807 | 8 | Config final. Envío KA9807 |
| WF9808 | 8 | Solo BAJA+2. No se envió |
| WF9901-9904 | 12 c/u | Con semillas de fuera del grupo |
| WF9905 | 36 | Semilla base 271211 |
| WF9921-9929 | 12 c/u | Semillas del grupo |

Ensambles por promedio de probabilidades:

| Ensamble | Modelos |
|---|---|
| KAF1 | 20 (WF9903 + WF9807) |
| KAF2 | 44 |
| KAF3 | 56 |
| KAF4 | 144 (el que elegimos) |
| KAENS_KAF4_WF9704 | KAF4 50/50 por rank con WF9704 |

## 4. Kaggle: público vs privado

Mejor público de cada familia y su privado, y el mejor privado de la familia:

| Familia | Mejor público (corte) | Su privado | Mejor privado (corte) |
|---|---|---|---|
| KAENS_KAF4_WF9704 | 440,164 (11000) | 497,072 | 497,072 (11000) |
| KA9520_s9 | 445,248 | 482,036 | 490,143 (11000) |
| KA9704_s14 | 433,998 | 480,429 | 486,786 (11000) |
| KAENS6 | | | 486,572 |
| **KAF4_s144** | **457,331 (10500)** | **479,000** | 486,357 (11000) |
| KA9912_s271211_s3 | | | 486,215 |
| KA9551_s9 | 464,998 (8000) | 470,715 | 485,822 |
| KAF3_s56 | 457,748 | 484,536 | |
| KAF2_s44 | 461,248 | 483,036 | |
| KA9807_s8 | 453,664 | 482,000 | |
| KAF1_s20 | 454,998 | 472,143 | 480,250 |

Nuestra elección final fue KAF4_s144_10500: 457,331 en público y 479,000 en privado. El 464,998 de KA9551 nos dejaba segundos en el público; en el privado terminamos alrededor del octavo puesto.

- Spearman entre público y privado sobre los 200 envíos: **0,012**. El público no sirvió para elegir.
- En el privado el corte 11000 fue casi siempre el mejor, más cerca de lo que decía el bootstrap de 202107 (10000 a 14000) que del público.
- El mejor privado fue el ensamble de dos modelos distintos (KAF4 + WF9704): unos 18 millones arriba de KAF4 solo.

## Qué haríamos distinto

1. Elegir modelo y corte con el backtest en 202107 y no con el público.
2. Ensamblar modelos distintos en vez de sumar semillas del mismo modelo: pasar de 20 a 144 semillas dejó el privado entre 472 y 485 sin un patrón claro, mezclar con WF9704 sumó 18.
3. Mandar el corte que sale del backtest (11000-12000) en lugar del que gana en el público.
