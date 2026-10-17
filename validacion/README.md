# ¿Qué tan confiable es el score con el que comparamos?

Análisis del esquema de validación de `635_workflow_senior.R` (main, b36cd2a) contra los resultados que
ya estaban en el bucket: 70 corridas de brazos del grupo B con la clase real de 202107, la BO de WF9600 y
135 envíos a Kaggle. Todo se corrió en desktop-jr; nada se entrenó en la Mac.

**Resumen**

1. **El ruido del mes de testing es tan grande como el de la semilla, y hoy no lo medimos.**
   - Una diferencia pareada entre dos brazos con la misma semilla se mueve con un sd de 4,1 M solo por
     cuáles clientes cayeron en 202107. Es lo mismo que el ruido entre semillas (sd de 3 a 5 M).
   - El Wilcoxon entre semillas solo ve la segunda fuente.
   - "E2 le gana a E0" da p = 0,010 con Wilcoxon. Con las dos fuentes de ruido el IC 95 % de la diferencia
     es [−1,3; +6,6] M y P(E2 > E0) = 0,92.
   - E4−E0 da parecido: [−2,0; +7,7], P = 0,89.
   - Son ventajas probables, no probadas.
2. **La meseta es mejor métrica que el máximo de la curva.**
   - Con el máximo la relación señal/ruido de E2−E0 es 0,17; con la meseta, 0,66. Para E4−E0, 0,33 contra
     0,92.
   - El máximo además es optimista: queda entre 10 y 12 M por encima de la meseta, porque el corte se
     elige mirando la respuesta.
   - El corte del máximo es inestable. Para una misma corrida, el bootstrap lo ubica entre 9.660 y 14.853
     envíos.
3. **El public de Kaggle no sirve para elegir entre corridas parecidas.**
   - Partimos 202107 al azar en 30/70, como el LB. La correlación de Spearman entre "public" y "private"
     de las 70 corridas es 0,12, y la mejor del public es la mejor del private en el 38 % de los casos.
   - Por semilla, el public acierta el signo de E2−E0 en el 61 % de las particiones. Promediando 20
     semillas, en el 90 %.
   - Con el public real (202109) pasa lo mismo: acierta el signo de E2−E0 en 1 de 3 semillas, mientras
     que 202107 da E2 > E0 en las 3.
4. **La BO ordena bien en grueso, pero elige entre configuraciones indistinguibles.**
   - Reentrenamos las 50 configuraciones de WF9600 y las medimos en 202107. La Spearman entre la AUC de la
     BO (202105) y la meseta en 202107 es 0,75.
   - La elegida queda 5.ª de 50: 584,4 M contra 601,7 M de la mejor (regret 17 M). Descontando el sesgo
     del ganador (~7 M), la pérdida real es de ~10 M: más que las diferencias entre brazos (~3 M).
   - Optimizar la ganancia en 202105 en lugar de la AUC no ayuda (Spearman 0,74; la elegida cae 17.ª).
   - Lo que más separa a 202107 de la AUC en 202105 es `feature_fraction`: las 4 mejores en 202107 tienen
     entre 0,05 y 0,25, y la elegida tiene 0,85.
5. **Hay un solo leakage, y no toca 202107.** Canaritos hace early stopping en 202105, que en el grupo B
   es el mes de validación de la BO. 202107 queda limpio como holdout.

---

## 1. El esquema actual

| | Grupo A (Kaggle) | Grupo B (202107 con la clase real) |
|---|---|---|
| training de la BO | 201901–202105 | 201901–202103 |
| gap | 202106 | 202104 |
| validación de la BO | 202107 | 202105 |
| final train | 201901–202107 | 201901–202105 |
| se predice | 202109: public 30 % / private 70 % | 202107 entero |

- **Undersampling.** En el training de la BO entran todas las BAJA+1/BAJA+2 y el 20 % de los CONTINUA
  (`training_pct 0.2`, `azar` con la semilla del pipeline). La validación es el mes completo. El final
  train usa `FT_UNDERSAMPLING`: 1 por defecto, 0.2 en todos los brazos.
- **Positivos.** Para entrenar, BAJA+1 y BAJA+2. Para la ganancia solo cuenta BAJA+2:
  +975.000 por acierto y −25.000 por error.
- **La BO maximiza AUC, no ganancia.** `EstimarGanancia_AUC_lightgbm` devuelve la AUC en el mes de
  validación con `num_iterations` fijo, sin early stopping. Son 20 puntos LHS y 30 de EI con kriging.
  `BO_log.txt` guarda solo la AUC, así que ninguna corrida registró la ganancia de las configuraciones
  que evaluó la BO.
- **Transferencia al final train.** Los hiperparámetros, incluido `num_iterations`, pasan tal cual de un
  training de 27 meses (B) a uno de 29, con otro undersampling si `FT_UNDERSAMPLING` ≠ 0.2.
- **Score de una corrida del grupo B.** Ordena 202107 por probabilidad y hace la suma acumulada de la
  ganancia. Escribe la ganancia en los cortes 8000, 8500, …, 12000, la **meseta** (promedio de esos 9
  cortes, `ganancia_meseta.txt`) y el **máximo** de la curva con sus envíos.
- **Grupo A.** Sube los 9 cortes a Kaggle. El public es el 30 % de 202109: una BAJA+2 de más o de menos en
  el public mueve el score unos 3,25 M (975.000 / 0,3).
- **Lo que mira cada paso.**

  | Paso | Mes | Qué mira |
  |---|---|---|
  | Lags y tendencias | — | Solo el pasado (`shift`, ventanas hacia atrás) |
  | Catastrophe analysis | — | Pone NA en meses rotos (método MachineLearning); no interpola con meses futuros |
  | Drift | — | Deflación con un índice exógeno |
  | FE_rf | entrena 202101–202103 | Árboles para crear variables |
  | Canaritos | entrena 202101–202103 | Selección de variables |
  | Canaritos | valida en **202105** | Early stopping sobre la meseta de ganancia (top 500), en los dos grupos |

## 2. Qué medimos y qué dio

Scripts en esta carpeta; cómo correrlos, al final.

### 2.1 Ruido entre semillas y elección de la métrica (`curvas_202107.R`)

202107 tiene 164.479 clientes y **1.304 BAJA+2** (0,79 %).

Media entre semillas de la ganancia en 202107 (millones; detalle en `resultados/curvas_202107.txt`):

| brazo | n | meseta | sd | máximo | sd | máximo − meseta | envíos del máximo (mediana [mín; máx]) |
|---|---|---|---|---|---|---|---|
| E0 (9900) | 20 | 583,19 | 4,37 | 594,89 | 4,60 | 11,70 | 12984 [10123; 16215] |
| E1 (9901) | 10 | 584,41 | 3,04 | 596,53 | 3,94 | 12,12 | 12135 [10503; 14873] |
| E2 (9902) | 20 | 586,04 | 4,03 | 595,83 | 5,53 | 9,79 | 12362 [8931; 15797] |
| E3 (9903) | 10 | 582,83 | 3,94 | 594,85 | 3,52 | 12,02 | 13667 [10392; 15435] |
| E4 (9904) | 10 | 585,81 | 2,72 | 596,90 | 3,16 | 11,09 | 12393 [10551; 14095] |

Diferencias pareadas por semilla contra E0, con tres métricas posibles:

| | métrica | media | sd | media/sd | gana | p Wilcoxon |
|---|---|---|---|---|---|---|
| E2−E0 | **meseta** | 2,85 | 4,29 | **0,66** | 16/20 | 0,010 |
| E2−E0 | máximo | 0,95 | 5,56 | 0,17 | 14/20 | 0,43 |
| E2−E0 | corte 10000 | 1,80 | 5,72 | 0,31 | 14/20 | 0,19 |
| E4−E0 | **meseta** | 3,12 | 3,40 | **0,92** | 7/10 | 0,037 |
| E4−E0 | máximo | 1,78 | 5,37 | 0,33 | 6/10 | 0,38 |
| E1−E0 | meseta | 1,72 | 3,03 | 0,57 | 7/10 | 0,11 |
| E3−E0 | meseta | 0,14 | 4,98 | 0,03 | 6/10 | 0,87 |

- Con el mismo número de semillas, la meseta detecta una diferencia que el máximo y un corte fijo no
  ven.
- El máximo agrega el ruido de dónde cae el pico. En 202107 el pico cae entre 8.931 y 16.215 envíos según
  la corrida, con mediana 12.538.
- Por eso main ya compara con la meseta (`ganancia_meseta.txt`). El PR 8 (FE evolutivo) usa el máximo y
  conviene que pase a la meseta.

Ganancia media de las 70 corridas en cada corte fijo:

| envíos | 8000 | 9000 | 10000 | 11000 | 12000 |
|---|---|---|---|---|---|
| ganancia (M) | 576,7 | 582,6 | 585,5 | 587,7 | 588,4 |

- En 202107 la curva todavía sube a los 12.000 envíos, así que la ventana 8000–12000 queda a la izquierda
  del óptimo. Para *comparar* brazos no importa.
- Para *elegir el corte del envío final* no hay que copiar el de 202107: el public de 202109 tiene el
  pico entre 9.000 y 10.500, y el modelo final se entrena con 2 meses más.

### 2.2 Ruido de muestreo del mes de testing (bootstrap de clientes)

- Remuestreamos los clientes de 202107 con pesos Poisson(1), 500 réplicas, con los mismos pesos para
  todas las corridas en cada réplica: el bootstrap queda pareado.
- **Una corrida sola.**
  - E0 con la semilla 100213 tiene meseta 586,3 M, con IC 95 % [527,9; 647,8] (sd 28,9).
  - El sd de la meseta es parecido en todas las corridas, unos 29 M.
  - Esto es lo que se movería el número si el "mes de testing" fuera otra muestra de clientes del
    mismo proceso.
  - Por eso no tiene sentido comparar ganancias absolutas entre experimentos que no comparten mes y
    clientes.
- **Una diferencia entre dos brazos con la misma semilla.** El sd bootstrap es 4,1 M (mediana de 50
  pares), porque gran parte del ruido es común a los dos modelos. Igual es del mismo orden que el ruido
  entre semillas.
- **Diferencia de medias de brazo con las dos fuentes de ruido** (`bootstrap_brazos.R`): en cada
  réplica se remuestrean clientes y semillas.

  | | diferencia | IC solo semillas (t) | IC solo mes | IC semillas + mes | P(dif > 0) |
  |---|---|---|---|---|---|
  | E2−E0 (20 sem.) | +2,85 | [+0,97; +4,73] | [−0,16; +5,40] | **[−1,31; +6,57]** | 0,92 |
  | E4−E0 (10 sem.) | +3,12 | [+1,01; +5,23] | [−0,55; +6,87] | **[−2,04; +7,73]** | 0,89 |
  | E1−E0 (10 sem.) | +1,72 | [−0,15; +3,60] | [−1,83; +5,43] | [−2,58; +6,42] | 0,74 |
  | E3−E0 (10 sem.) | +0,14 | [−2,94; +3,23] | [−3,28; +3,69] | [−4,96; +5,19] | 0,52 |

- Agregar semillas achica solo la primera fuente: con infinitas semillas el IC de E2−E0 seguiría siendo
  el de la columna "solo mes", que cruza el 0.
- Para separar diferencias de unos 3 M hacen falta más clientes, o sea más meses de testing; más
  semillas no alcanzan.
- Ojo: el bootstrap supone que 202107 es una muestra de clientes del mismo proceso. No cubre el cambio de
  mes a mes (202107 → 202109), que probablemente sea más grande.

### 2.3 El public como juez: simulación con 202107 partido 30/70

- 500 particiones al azar de 202107 en 30 % "public" y 70 % "private", cada una re-escalada a la
  población.
- El public y el private son complementarios, como en Kaggle (detalle en `resultados/curvas_202107.txt`).

| | resultado |
|---|---|
| sd del public de una corrida entre particiones | 42 M (meseta) |
| Spearman public vs private entre las 70 corridas | mediana 0,12 [p5 −0,06; p95 0,28] |
| la mejor del public es la mejor del private | 38 % de las particiones (puesto mediano en el private: 10 de 70) |
| signo de E2−E0, por semilla | el public acierta el 61 % |
| signo de E2−E0, promedio de 20 semillas | acierta el 90 % (sd de la diferencia en el public 2,1 M) |
| signo de E4−E0, promedio de 10 semillas | acierta el 86 % |

- Las 70 corridas están en un rango de unos 15 M. El public, con 30 % de los clientes (unas 390 BAJA+2),
  mueve cada corrida ±42 M.
- Entre corridas parecidas el public ordena casi al azar. Sirve para ver diferencias grandes (otro
  modelo, otra estrategia de corte), no para elegir entre semillas ni entre brazos con 1–3 M de
  diferencia.
- Subir el ensamble que mejor dio en el public es, sobre todo, overfitting al public.

### 2.4 Public real (A, 202109) contra 202107 (B), mismo brazo y misma semilla (`comparar_public.R`)

E0A/E2A del grupo A contra E0/E2 del grupo B, con 3 semillas del pipeline (meseta en millones):

| semilla | E0 public | E0 202107 | E2 public | E2 202107 | E2−E0 public | E2−E0 202107 |
|---|---|---|---|---|---|---|
| 100213 | 447,19 | 586,33 | 449,27 | 590,11 | +2,07 | +3,78 |
| 100313 | 447,65 | 581,44 | 442,21 | 587,67 | −5,44 | +6,22 |
| 271211 | 435,29 | 580,67 | 431,69 | 584,00 | −3,60 | +3,33 |

- 202107 dice que E2 le gana a E0 en las 3 semillas. El public, en 1 de 3.
- Entre las 6 corridas, la correlación public vs 202107 es 0,48. Lo que comparten es sobre todo el
  efecto de la semilla del pipeline: 271211 es la peor en los dos.
- Con este ruido (§2.3), un public más bajo para E2 no contradice a 202107.
- Los envíos del máximo tampoco se trasladan: 9000–10500 en el public contra 8900–14000 en 202107.

### 2.5 ¿La BO elige bien? (`reevaluar_bo.R` + `analizar_reevaluacion.R`)

Reentrenamos las 50 configuraciones de `BO_log.txt` de WF9600 sobre el dataset con FE y canaritos de una
corrida E0 de main (WF9950_s100213, con los checkpoints). Usamos 2 semillas (100213 y 271211) y 3 vistas:

| Vista | Training | Gap | Mide en | Undersampling |
|---|---|---|---|---|
| V03 | 201901–202101 | 202102 | 202103 | 0,2 |
| V05 | 201901–202103 | 202104 | 202105 (= la BO del grupo B) | 0,2 |
| T07 | 201901–202105 | 202106 | 202107 (= el final train de los brazos) | 0,2 |

Son 300 modelos, unas 6 h en desktop-jr. V03 está algo contaminada, porque FE_rf y canaritos entrenan con
202101–202103. Salidas en `resultados/reevaluacion_bo.txt`, `resultados/detalle_bo.txt` y los dos CSV.

**La semilla no es el problema.** Para una misma configuración, la Spearman de la meseta entre las dos
semillas es 0,90–0,94 y el sd medio es de 4,5–6,5 M. Entre configuraciones la meseta cambia unos 180–270 M.
El orden lo deciden los hiperparámetros.

**Qué criterio de validación predice mejor la meseta en 202107** (promedio de las 2 semillas):

| Criterio | Spearman vs T07 | Puesto en T07 de la elegida | Regret (M) | Media T07 del top 5 |
|---|---|---|---|---|
| AUC de la BO original (202105, 1 semilla) | 0,75 | 5 | 17,3 | 582,4 |
| AUC 202105 (V05, 2 semillas) | 0,75 | 7 | 21,7 | 577,0 |
| Meseta 202105 (V05) | 0,74 | 17 | 30,5 | 582,4 |
| Máximo 202105 (V05) | 0,74 | 8 | 22,8 | 575,0 |
| AUC 202103 (V03) | 0,80 | 7 | 21,7 | 577,4 |
| Meseta 202103 (V03) | 0,82 | 7 | 21,7 | 577,2 |
| Meseta promedio 202103 + 202105 | 0,80 | 7 | 21,7 | 577,6 |
| AUC 202107 (techo: el propio mes) | 0,89 | 7 | 21,7 | 583,8 |

La meseta de 202107 va de 329,7 a 601,7 M, con mediana 561,9 M.

- **El orden grueso se transfiere.** La AUC de la BO separa bien las configuraciones malas de las
  buenas: con Spearman 0,75, las 7 primeras de la BO están todas por encima de la mediana salvo una. En
  promedio dan 575,7 M, contra 588,6 M de las 7 mejores de verdad.
- **La elección final es casi una lotería entre las ~10 primeras.**
  - De las 7 mejores AUC, en 202107 la 4.ª (config 4) queda 2.ª y la 7.ª queda 34.ª.
  - Ningún criterio acierta la mejor de 202107 (config 24), ni siquiera la AUC del propio 202107.
  - Parte del regret de 17 M es ruido. Por la semilla, la config 24 le gana a la 1 por 13,0 y 21,6 M.
  - Pero si las 10 primeras fueran iguales, la mejor medida en 202107 saldría ~7 M arriba solo por ruido
    de semilla, sin contar el ruido de mes de §2.2.
- **Optimizar ganancia en lugar de AUC no ayuda.** La meseta de 202105 correlaciona igual que la AUC
  (0,74 contra 0,75) y su elegida cae 17.ª. En 202105 la curva alcanza el máximo cerca de los 7.800
  envíos, contra 11.650 en 202107, así que la meseta 8000–12000 mide en 202105 otra parte de la curva.
  La AUC no depende del corte y es menos ruidosa.
- **Validar en otro mes mejora poco.** V03, o el promedio de V03 y V05, sube la Spearman de 0,75 a
  0,80–0,82, pero elige la misma configuración. No justifica duplicar el costo de la BO.
- **`feature_fraction` es donde 202105 y 202107 no coinciden.**

  | Hiperparámetro | Spearman con la meseta T07 | Spearman con la AUC V05 |
  |---|---|---|
  | `feature_fraction` | −0,16 | +0,20 |
  | `num_leaves` | +0,53 | +0,35 |
  | `learning_rate` | −0,51 | −0,35 |
  | `num_iterations` | +0,48 | +0,66 |

  - La mejor en 202107 (config 24) tiene `feature_fraction` 0,05, que es el piso del rango, con 1000
    árboles, 1782 hojas y `learning_rate` 0,023.
  - Las siguientes tres tienen 0,25, 0,09 y 0,07. La elegida por la BO, 5.ª, tiene 0,85.
  - Con meses más lejanos, columnas más aleatorias generalizan mejor que lo que premia la AUC del mes de
    validación.
  - `num_iterations` está en el techo o cerca (947 a 1023 árboles, techo 2^10) en 4 de las 5 mejores de
    202107. El techo se puede subir
    con `BO_TECHO_LOG2_ITERACIONES`.

## 3. Riesgos

| # | Riesgo | Evidencia | Gravedad |
|---|---|---|---|
| 1 | Concluir con Wilcoxon entre semillas sobre un solo mes de testing | §2.2: IC con mes incluido cruza 0 para E2 y E4 | **alta**: hoy es la regla de decisión |
| 2 | Elegir con el public (semillas, ensambles, corte) | §2.3 y §2.4: Spearman 0,12; signo al azar por semilla | **alta** |
| 3 | Usar el máximo de la curva como métrica (PR 8) | §2.1: señal/ruido 4 veces peor; optimista en 10–12 M | media |
| 4 | La BO elige entre top‑AUC indistinguibles y premia `feature_fraction` alto; pegada al techo de árboles | §2.5: regret ~10–17 M en 202107, puesto 5 de 50 | media: el orden grueso sirve (Spearman 0,75), la elección fina no |
| 5 | Leakage de selección: canaritos hace early stopping en 202105 = validate de la BO del grupo B (`PARAM$CN$train$validation`) | código | baja: infla la AUC de la BO, no toca 202107 ni 202109 |
| 6 | Reutilizar 202107 para elegir *y* reportar (elegir el brazo que más dio en 202107 y reportar esa ganancia) | selección entre 5 brazos | media: el ganador está sesgado para arriba unos M |
| 7 | Transferir `num_iterations` de un training con undersampling 0,2 a un final train con `FT_UNDERSAMPLING=1` (el default) | código | media si se usa el default; los brazos usan 0,2 y no aplica |
| 8 | Undersampling y ganancia | código | **no es un riesgo**: el corte es por cantidad de envíos y el mes evaluado es completo; el undersampling cambia el modelo pero no sesga la medición |
| 9 | Lags, tendencias, CA, drift | código | sin leakage: todo mira hacia atrás o es exógeno; FE_rf y canaritos entrenan en 202101–202103, que está dentro del training en los dos grupos |

## 4. Qué cambia en este PR y qué proponemos

**En este PR** (solo agrega `validacion/`, no toca el workflow):

- `curvas_202107.R`: curva, meseta, máximo y corte de cada corrida del grupo B contra la clase real;
  bootstrap pareado de clientes; public/private simulado; ganancia por corte fijo.
- `bootstrap_brazos.R`: IC de la diferencia de medias entre brazos con ruido de semilla **y** de mes.
  Debería reemplazar al Wilcoxon como regla para decir "el brazo X es mejor".
- `comparar_public.R`: public real (grupo A) contra 202107 (grupo B), mismo brazo y semilla.
- `reevaluar_bo.R`, `analizar_reevaluacion.R` y `detalle_bo.R`: reentrenan las configuraciones de la BO en 202103,
  202105 y 202107 y miden qué criterio de validación predice la ganancia en 202107.
- `resultados/`: las salidas de esta corrida.

**Propuestas** (no implementadas acá; cada una necesita su corrida):

1. **Regla de decisión.** Un brazo gana si el IC 95 % "semillas + mes" de `bootstrap_brazos.R` sobre la
   meseta no cruza 0. Si cruza, se reporta como "probable" con su P(dif > 0). Nada de Wilcoxon solo.
2. **Más de un mes de testing (backtesting).** Correr cada brazo también con un grupo "B−2" que desplaza
   todo dos meses (BO valida 202103, gap 202102, final train hasta 202103, test 202105) y combinar la
   diferencia de las dos vistas. Duplica los clientes de testing, que es lo único que achica el ruido de
   mes. Requiere hacer configurable el mes de validación de canaritos (hoy fijo en 202105, riesgo 5).
3. **202107 como holdout estándar, pero no para elegir el corte del envío final.** Para comparar se usa
   la meseta; el corte final sale del grupo A.
4. **No elegir con el public**: ni semillas, ni ensambles, ni corte entre opciones a menos de ~5 M.
   Si se usa, solo para confirmar diferencias grandes.
5. **BO** (§2.5):
   - Seguir optimizando AUC en 202105. La ganancia en 202105 no predice mejor, y validar en dos meses
     tampoco cambia la elegida.
   - No quedarse con la primera de la BO. Llevar las 5 primeras al final train y promediarlas
     (semillerío de configuraciones). Su media en 202107 (582,4 M) está a la par de la elegida (584,4 M)
     y es mucho menos dependiente de la suerte de cuál salió primera.
   - Probar `feature_fraction` fijo en 0,05–0,25, o bajar el techo del rango, y subir
     `BO_TECHO_LOG2_ITERACIONES` a 11.
   - Medir cualquiera de estos cambios como un brazo más, con la regla 1, y no eligiendo con 202107 lo
     mismo que después se reporta en 202107 (riesgo 6).

## 5. Cómo correr

Los scripts corren en la VM como `ds` (el bucket solo lo lee `ds`), desde `/tmp`.

**Curvas de 202107.** Unos 50 minutos para 70 corridas con B_BOOT=500 y R_PUBLIC=500.

```bash
Rscript validacion/curvas_202107.R /home/ds/buckets/b1/exp/validacion_curvas \
  /home/ds/buckets/b1/datasets/analistasr_competencia_2026.csv.gz '/home/ds/buckets/b1/exp/WF990[0-4]_s*'
```

**Public de Kaggle contra 202107.** El CSV sale de la API de Kaggle (submissions con `pageSize=500`).

```bash
Rscript validacion/comparar_public.R kaggle_subs.csv /home/ds/buckets/b1/exp/brazos_v2/brazos.csv "9910=9900,9912=9902"
```

**Reevaluación de la BO.** Primero hace falta una corrida E0 que conserve `checkpoints/`. Después,
unas 6 h para 50 configuraciones × 3 vistas × 2 semillas en 12 vCPU. Retoma sola si se corta.

```bash
Rscript validacion/reevaluar_bo.R /home/ds/buckets/b1/exp/WF9950_s100213/checkpoints/dataset_canaritos.fst \
  /home/ds/buckets/b1/exp/WF9600/BO_log.txt /home/ds/buckets/b1/exp/validacion_bo
Rscript validacion/analizar_reevaluacion.R /home/ds/buckets/b1/exp/validacion_bo/reevaluacion.csv
Rscript validacion/detalle_bo.R /home/ds/buckets/b1/exp/validacion_bo/reevaluacion.csv
```

Las salidas de esta corrida están en `validacion/resultados/`.
