# Construye 635_WorkFlow_01_senior_final.ipynb a partir del z635 (que no se toca).
# Cada reemplazo verifica el texto original de la celda antes de cambiarla.
import json, sys, copy

SRC, DST = sys.argv[1], sys.argv[2]
nb = json.load(open(SRC, encoding="utf-8"))
cells = nb["cells"]

def src(i):
    return "".join(cells[i]["source"])

def code(text):
    return {"cell_type": "code", "metadata": {}, "execution_count": None,
            "outputs": [], "source": text.strip("\n").splitlines(keepends=True)}

def md(text):
    return {"cell_type": "markdown", "metadata": {},
            "source": text.strip("\n").splitlines(keepends=True)}

def replace(i, must_contain, new_text):
    assert must_contain in src(i), f"celda {i} no contiene {must_contain!r}"
    cells[i]["source"] = new_text.strip("\n").splitlines(keepends=True)

inserts = {}   # indice original -> celdas a insertar DESPUES de esa celda

# ---------------------------------------------------------------- parametros
replace(11, "PARAM$semilla_primigenia <- 102191", r'''
PARAM <- list()
PARAM$semilla_primigenia <- 100213

PARAM$experimento <- 9700
PARAM$dataset <- "analistasr_competencia_2026.csv.gz"

# "kaggle"   : grupo A, predice 202109 y sube a Kaggle
# "backtest" : misma receta corrida dos meses atras (linea de tiempo del grupo B),
#              predice 202107 y mide la ganancia real de cada modelo del semillerio.
#              Es la corrida que dice si la receta es buena.
PARAM$modo <- "kaggle"

if (!(PARAM$modo %in% c("kaggle", "backtest"))) stop("PARAM$modo tiene que ser kaggle o backtest")

# en backtest la carpeta es otra, para no mezclar con la corrida de Kaggle
if (PARAM$modo == "backtest") PARAM$experimento <- PARAM$experimento + 1
''')

# ---------------------------------------------------------------- CA y DR
# sin cambios: ningun equipo 2026 midio alternativas en el dataset senior

# ---------------------------------------------------------------- formulas al azar
inserts[44] = [
    md(r'''
#### FE intra-mes: formulas al azar

Experimento colaborativo #7: agregar formulas sorteadas de la gramatica `v1 op v2` o `(v1 op v2) op v3` suma ~3 M (E2 − E0 +2,85 M, 16 de 20 semillas, p 0,010; 30 formulas +3,41 M); buscarlas con un algoritmo genetico no le gana al azar.
<br>Se crean antes del FE historico, como en E2, asi que reciben lags, deltas y tendencias como cualquier campo.
'''),
    code(r'''
PARAM$FE_formulas$run <- TRUE
PARAM$FE_formulas$cantidad <- 30
PARAM$FE_formulas$semilla <- PARAM$semilla_primigenia
# meses donde se verifica que la formula no sea constante (solo training, sin clase)
PARAM$FE_formulas$meses_chequeo <- c(202101)
'''),
    code(r'''
# evalua una formula sobre una tabla; NULL si falla o si es constante
evaluar_formula <- function(formula, tabla) {
  v <- tryCatch(eval(parse(text= formula)[[1]], envir= tabla), error= function(e) NULL)
  if (is.null(v) || length(v) != nrow(tabla)) return(NULL)
  v <- as.numeric(v)
  v[is.infinite(v)] <- NA
  v[is.nan(v)] <- 0
  if (length(unique(v[!is.na(v)])) < 2) return(NULL)
  v
}

# formulas al azar de la misma gramatica del experimento #7
# (mitad de 2 campos, mitad de 3), distintas y no constantes en la muestra.
# Usa su propia semilla y deja el RNG de R como estaba
sortear_formulas <- function(n, vars, semilla, muestra) {
  rng <- if (exists(".Random.seed", envir= globalenv())) get(".Random.seed", envir= globalenv())
  set.seed(semilla, kind = "L'Ecuyer-CMRG")
  ops <- c(" + ", " - ", " * ", " / ")
  f <- character(0)
  intentos <- 0
  while (length(f) < n && intentos < 100 * n) {
    intentos <- intentos + 1
    v <- sample(vars, 3, replace= TRUE)
    o <- sample(ops, 2, replace= TRUE)
    cand <- if (runif(1) < 0.5) paste0(v[1], o[1], v[2]) else paste0("(", v[1], o[1], v[2], ")", o[2], v[3])
    if (!(cand %in% f) && !is.null(evaluar_formula(cand, muestra))) f <- c(f, cand)
  }
  if (!is.null(rng)) assign(".Random.seed", rng, envir= globalenv())
  f
}

AgregarFormulasAzar <- function() {
  cat( "inicio AgregarFormulasAzar()\n")
  numericas <- names(dataset)[sapply(dataset, is.numeric)]
  vars <- setdiff(numericas, c("numero_de_cliente", "foto_mes"))
  muestra <- dataset[foto_mes %in% PARAM$FE_formulas$meses_chequeo]

  formulas <- sortear_formulas(PARAM$FE_formulas$cantidad, vars,
    PARAM$FE_formulas$semilla, muestra)
  rm(muestra)

  tb_formulas <- data.table(
    nombre= sprintf("form_%02d", seq_along(formulas)),
    formula= formulas)

  for (i in seq_len(nrow(tb_formulas)))
    set(dataset, j= tb_formulas$nombre[i],
      value= evaluar_formula(tb_formulas$formula[i], dataset))

  fwrite(tb_formulas, file= "formulas.txt", sep= "\t")
  cat( "fin AgregarFormulasAzar()\n")
  tb_formulas
}
'''),
    code(r'''
if (PARAM$FE_formulas$run) {
  tb_formulas <- AgregarFormulasAzar()
  print(tb_formulas)
}
'''),
    code(r'''
# AgregarVariables_IntraMes deja foto_mes_formato_fecha como Date cuando el
#  dataset no tiene cantidad_total_transacciones. Los ratios del FE historico
#  no pueden dividir fechas: paso a numeric, que es lo que el modelo ya veia
#  (data.matrix convierte la fecha en dias)
if ("foto_mes_formato_fecha" %in% colnames(dataset))
  dataset[, foto_mes_formato_fecha := as.numeric(foto_mes_formato_fecha)]
'''),
]

# ---------------------------------------------------------------- FE historico
replace(52, "PARAM$FE_hist$Tendencias$ventana <- 6", r'''
# parametros de Feature Engineering Historico de Tendencias
# Experimento colaborativo #4 (grupo B): ventana de 9 meses con tendencia y ratios
#  le gana a 6 meses en 9 de 9 semillas (p 0,004) y a 6 meses sin ratios (p 0,010)
PARAM$FE_hist$Tendencias$run <- TRUE
PARAM$FE_hist$Tendencias$ventana <- 9
PARAM$FE_hist$Tendencias$tendencia <- TRUE
PARAM$FE_hist$Tendencias$minimo <- FALSE
PARAM$FE_hist$Tendencias$maximo <- FALSE
PARAM$FE_hist$Tendencias$promedio <- FALSE
PARAM$FE_hist$Tendencias$ratioavg <- TRUE
PARAM$FE_hist$Tendencias$ratiomax <- TRUE
''')

t53 = src(53).replace("# 6 meses de historia", "# meses de historia")
t53 = t53.replace("setorder(dataset, numero_de_cliente, foto_mes)\n",
    "setorder(dataset, numero_de_cliente, foto_mes)\n\n"
    "# TendenciaYmuchomas agrega columnas con := adentro de una funcion: si el\n"
    "#  data.table se queda sin lugares reservados para columnas, las nuevas quedan\n"
    "#  en una copia local y se pierden sin error. Reservo el lugar antes, afuera\n"
    "setalloccol(dataset, ncol(dataset) + 6 * length(cols_lagueables) + 100)\n", 1)
replace(53, "ventana = PARAM$FE_hist$Tendencias$ventana, # 6 meses de historia", t53 + r'''

# verifico que cada campo tenga su historia completa
sufijos <- c(
  if (PARAM$FE_hist$Tendencias$tendencia) "_tend",
  if (PARAM$FE_hist$Tendencias$minimo) "_min",
  if (PARAM$FE_hist$Tendencias$maximo) "_max",
  if (PARAM$FE_hist$Tendencias$promedio) "_avg",
  if (PARAM$FE_hist$Tendencias$ratioavg) "_ratioavg",
  if (PARAM$FE_hist$Tendencias$ratiomax) "_ratiomax")
if (PARAM$FE_hist$Tendencias$run)
  for (s in paste0(sufijos, PARAM$FE_hist$Tendencias$ventana)) {
    faltan <- setdiff(paste0(cols_lagueables, s), colnames(dataset))
    if (length(faltan)) stop("faltan ", length(faltan), " columnas ", s)
  }
cat("FE historico completo:", length(cols_lagueables), "campos x", length(sufijos), "\n")
''')

# ---------------------------------------------------------------- FE random forest
replace(59, "PARAM$FE_rf$arbolitos= 20", src(59).replace(
    "# Estos CUATRO parametros son los que se deben modificar",
    "# Experimento colaborativo #6 (grupo B): sin Random Forest se gana lo mismo\n"
    "#  (+1,7 M, p 0,557) con menos columnas y corridas mas rapidas\n"
    "PARAM$FE_rf$activar <- FALSE\n\n"
    "# Estos CUATRO parametros son los que se deben modificar"))

replace(60, "AgregaVarRandomForest()", r'''
# Feature Engineering agregando variables de Random Forest
if (PARAM$FE_rf$activar) {
  AgregaVarRandomForest()
} else {
  cat("Sin Feature Engineering de Random Forest\n")
}
''')

# ---------------------------------------------------------------- canaritos
replace(67, "PARAM$CN$ratio <- 0.2", src(67).replace(
    "# Estos DOS parametros son los que se deben modificar",
    "# Experimento colaborativo #7 (workflow 635, 12 semillas): sacar canaritos\n"
    "#  suma +4,56 M, gana 12 de 12, Holm 0,003\n"
    "PARAM$CN$run <- FALSE\n\n"
    "# Estos DOS parametros son los que se deben modificar"))

replace(68, "tb_importancia <- CanaritosAsesinos(", r'''
# la llamada a Canaritos Asesinos
if (PARAM$CN$run) {
  tb_importancia <- CanaritosAsesinos(
    canaritos_ratio = PARAM$CN$ratio,
    canaritos_desvios = PARAM$CN$desvios,
    canaritos_semilla = PARAM$semilla_primigenia
  )
} else {
  cat("Sin canaritos\n")
}
''')

replace(69, 'file="canaritos.txt"', r'''
# grabo la importancia, ver el archivo directamente en la carpeta
if (PARAM$CN$run) {
  fwrite( tb_importancia,
    file="canaritos.txt",
    sep="\t"
  )
}
''')

inserts[70] = [code(r'''
# tamaño del dataset antes de modelar: el final train arma una matriz
#  de numeric de un tamaño parecido, hay que tener ese lugar libre en RAM
cat("columnas:", ncol(dataset), " filas:", nrow(dataset),
  " GB en memoria:", round(as.numeric(object.size(dataset)) / 2^30, 1), "\n")
''')]

# ---------------------------------------------------------------- training strategy
replace(74, "PARAM$trainingstrategy$validate <- c(202107)", r'''
# Sin cambios respecto del z635: la evidencia del experimento #5 es del
#  dataset junior y sus dos grupos se contradicen
meses_hasta <- function(ultimo) {
  todos <- c(201901:201912, 202001:202012, 202101:202109)
  todos[todos <= ultimo]
}

if (PARAM$modo == "kaggle") {
  PARAM$trainingstrategy$validate <- c(202107)
  PARAM$trainingstrategy$training <- meses_hasta(202105)
} else {
  # backtest: la misma linea de tiempo corrida dos meses atras
  PARAM$trainingstrategy$validate <- c(202105)
  PARAM$trainingstrategy$training <- meses_hasta(202103)
}

PARAM$trainingstrategy$training_pct <- 0.2


PARAM$trainingstrategy$positivos <- c( "BAJA+1", "BAJA+2")
''')

# ---------------------------------------------------------------- final train
replace(98, "PARAM$trainingstrategy$final_train <- c(", r'''
if (PARAM$modo == "kaggle") {
  PARAM$trainingstrategy$final_train <- meses_hasta(202107)
} else {
  PARAM$trainingstrategy$final_train <- meses_hasta(202105)
}

dataset[, fold_final_train := foto_mes %in% PARAM$trainingstrategy$final_train ]

# creo el dfinal_train en formato  LightGBM
dfinal_train <- lgb.Dataset(
  data= data.matrix(dataset[fold_final_train == TRUE, campos_buenos, with= FALSE]),
  label= dataset[fold_final_train == TRUE, clase01],
  free_raw_data= TRUE
)

nrow( dfinal_train) # verifico el tamaño
''')

replace(103, "PARAM$FT$semillerio <- 10", r'''
# 30 modelos: alcanza para ver la dispersion entre semillas y para el ensamble.
#  Cada modelo se graba en ./modelos: si se corta, retoma; con 20 ya se puede evaluar
PARAM$FT$semillerio <- 30  # cantidad de semillas
''')

# ---------------------------------------------------------------- scoring
replace(110, "PARAM$trainingstrategy$future <- c(202109)", r'''
if (PARAM$modo == "kaggle") {
  PARAM$trainingstrategy$future <- c(202109)
} else {
  PARAM$trainingstrategy$future <- c(202107)
}

dfuture <- dataset[ foto_mes %in% PARAM$trainingstrategy$future ]
''')

replace(113, "tb_prediccion[, prob := prob /length(PARAM$FT$semillas) ]", src(113) + r'''

# ensamble alternativo: promedio del ranking de cada modelo
#  (1 = el mas probable de ese modelo). Se graba al lado, no se usa para el submit
cols_prob <- paste0("prob_", seq(length(PARAM$FT$semillas)))
tb_prediccion[, rank_prom := rowMeans(
  as.data.table(lapply(.SD, function(p) frank(-p, ties.method= "average")))),
  .SDcols = cols_prob ]
''')

# ---------------------------------------------------------------- evaluacion (backtest)
inserts[115] = [
    md(r'''
#### Evaluacion del semillerio (solo backtest)

Ganancia real en 202107 de cada modelo y del ensamble. La **meseta** es el promedio de la ganancia en los cortes 8.000, 8.500, …, 12.000, la misma metrica de los experimentos colaborativos #6 y #7, para poder comparar:
<br>modelo suelto en 202107: entre 582 y 587 M de media; ensamble: entre 589 y 593 M.
'''),
    code(r'''
PARAM$eval$cortes <- seq(8000, 12000, by = 500)
PARAM$eval$gan_acierto <- 975000
PARAM$eval$gan_error <- -25000

# ganancia en cada corte de un vector de puntajes (mayor = mas probable)
ganancia_cortes <- function(score, clase) {
  gan <- ifelse(clase == "BAJA+2", PARAM$eval$gan_acierto, PARAM$eval$gan_error)
  acum <- cumsum(gan[order(-score)])
  acum[PARAM$eval$cortes]
}

if (PARAM$modo == "backtest") {
  clase <- dfuture$clase_ternaria
  stopifnot(all(tb_prediccion$numero_de_cliente == dfuture$numero_de_cliente))

  # un modelo por fila
  tb_eval <- rbindlist(lapply(seq(length(PARAM$FT$semillas)), function(i) {
    g <- ganancia_cortes(tb_prediccion[[paste0("prob_", i)]], clase)
    data.table(modelo= i, semilla= PARAM$FT$semillas[i],
      meseta= mean(g), maximo= max(g), corte_max= PARAM$eval$cortes[which.max(g)][1])
  }))

  # los dos ensambles
  g_prob <- ganancia_cortes(tb_prediccion$prob, clase)
  g_rank <- ganancia_cortes(-tb_prediccion$rank_prom, clase)

  # ensamble de los primeros k modelos: muestra donde satura
  tb_k <- rbindlist(lapply(seq(length(PARAM$FT$semillas)), function(k) {
    p <- rowMeans(as.matrix(tb_prediccion[, paste0("prob_", seq(k)), with= FALSE]))
    data.table(k= k, meseta_ensamble= mean(ganancia_cortes(p, clase)))
  }))

  m <- tb_eval$meseta
  ic <- if (length(m) > 1) t.test(m)$conf.int else c(NA, NA)

  cat("\nModelos sueltos (", length(m), "):  meseta media", round(mean(m) / 1e6, 2),
    "M  desvio", round(sd(m) / 1e6, 2),
    "M  IC95 [", round(ic[1] / 1e6, 2), ";", round(ic[2] / 1e6, 2), "]\n")
  cat("Ensamble promedio de probabilidades: meseta", round(mean(g_prob) / 1e6, 2),
    "M  maximo", round(max(g_prob) / 1e6, 2), "M en", PARAM$eval$cortes[which.max(g_prob)], "\n")
  cat("Ensamble promedio de rankings:       meseta", round(mean(g_rank) / 1e6, 2),
    "M  maximo", round(max(g_rank) / 1e6, 2), "M en", PARAM$eval$cortes[which.max(g_rank)], "\n")

  fwrite(tb_eval, file= "eval_modelos.txt", sep= "\t")
  fwrite(tb_k, file= "eval_ensamble_k.txt", sep= "\t")
  fwrite(data.table(corte= PARAM$eval$cortes, ganancia_prob= g_prob, ganancia_rank= g_rank),
    file= "eval_ensamble_cortes.txt", sep= "\t")

  PARAM$out$eval <- list(
    meseta_modelo_media= mean(m), meseta_modelo_sd= sd(m),
    meseta_ensamble_prob= mean(g_prob), meseta_ensamble_rank= mean(g_rank))
}
'''),
    md(r'''
#### Graficos de la evaluacion (solo backtest)

Se graban en la carpeta del experimento y se muestran aca.
1. **Curva de ganancia por envios** (6.000 a 16.000): cada modelo en gris, los dos ensambles en color. Dice donde esta la meseta y que corte conviene.
2. **Meseta de cada modelo** contra los ensambles y las bandas de referencia de los experimentos colaborativos.
3. **Ensamble de los primeros k modelos**: desde cuantos modelos deja de mejorar.
'''),
    code(r'''
# dibuja en un png de la carpeta del experimento y tambien en el notebook
graficar <- function(archivo, dibujo) {
  png(archivo, width= 1200, height= 700, res= 110)
  dibujo()
  dev.off()
  dibujo()
}

if (PARAM$modo == "backtest") {
  cortes_curva <- seq(6000, 16000, by = 250)
  gan_curva <- function(score) {
    gan <- ifelse(clase == "BAJA+2", PARAM$eval$gan_acierto, PARAM$eval$gan_error)
    cumsum(gan[order(-score)])[cortes_curva] / 1e6
  }

  curvas_modelos <- sapply(seq(length(PARAM$FT$semillas)),
    function(i) gan_curva(tb_prediccion[[paste0("prob_", i)]]))
  curva_prob <- gan_curva(tb_prediccion$prob)
  curva_rank <- gan_curva(-tb_prediccion$rank_prom)

  tb_curva <- data.table(envios= cortes_curva, ensamble_prob= curva_prob,
    ensamble_rank= curva_rank, modelo_media= rowMeans(curvas_modelos))
  fwrite(tb_curva, file= "eval_curva.txt", sep= "\t")

  mejor <- tb_curva[which.max(ensamble_prob)]
  cat("Ensamble (probabilidades): maximo", round(mejor$ensamble_prob, 1), "M en", mejor$envios,
    "envios. Cortes a menos de 1 % del maximo:",
    paste(range(tb_curva[ensamble_prob >= 0.99 * mejor$ensamble_prob, envios]), collapse= " a "), "\n")

  graficar("grafico_curva_ganancia.png", function() {
    matplot(cortes_curva, curvas_modelos, type= "l", lty= 1, col= "grey80",
      xlab= "envios", ylab= "ganancia en 202107 (M)",
      main= paste0("WF", PARAM$experimento, " - ganancia por envios"),
      ylim= range(c(curvas_modelos, curva_prob, curva_rank)))
    rect(min(PARAM$eval$cortes), par("usr")[3], max(PARAM$eval$cortes), par("usr")[4],
      col= adjustcolor("gold", 0.15), border= NA)
    lines(cortes_curva, curva_prob, col= "red", lwd= 3)
    lines(cortes_curva, curva_rank, col= "blue", lwd= 2, lty= 2)
    abline(v= 11000, lty= 3)
    legend("bottomright", bty= "n",
      legend= c("cada modelo", "ensamble probabilidades", "ensamble rankings",
                "zona de la meseta", "11.000"),
      col= c("grey70", "red", "blue", "gold", "black"),
      lty= c(1, 1, 2, NA, 3), lwd= c(1, 3, 2, NA, 1), pch= c(NA, NA, NA, 15, NA))
  })

  graficar("grafico_meseta_modelos.png", function() {
    stripchart(tb_eval$meseta / 1e6, method= "jitter", vertical= TRUE, pch= 19,
      col= "grey40", ylab= "meseta 8.000-12.000 en 202107 (M)",
      main= "Meseta de cada modelo del semillerio",
      ylim= range(c(tb_eval$meseta / 1e6, mean(g_prob) / 1e6, mean(g_rank) / 1e6, 580, 595)))
    rect(0, 582, 2, 587, col= adjustcolor("grey", 0.25), border= NA)
    rect(0, 589, 2, 593, col= adjustcolor("orange", 0.20), border= NA)
    abline(h= mean(tb_eval$meseta) / 1e6, col= "grey40", lty= 2)
    abline(h= mean(g_prob) / 1e6, col= "red", lwd= 2)
    abline(h= mean(g_rank) / 1e6, col= "blue", lwd= 2, lty= 2)
    legend("topleft", bty= "n",
      legend= c("media de los modelos", "ensamble probabilidades", "ensamble rankings",
                "referencia modelo suelto (582-587)", "referencia ensamble (589-593)"),
      col= c("grey40", "red", "blue", "grey", "orange"),
      lty= c(2, 1, 2, NA, NA), lwd= c(1, 2, 2, NA, NA), pch= c(NA, NA, NA, 15, 15))
  })

  graficar("grafico_ensamble_k.png", function() {
    plot(tb_k$k, tb_k$meseta_ensamble / 1e6, type= "b", pch= 19,
      xlab= "modelos en el ensamble (los primeros k)", ylab= "meseta en 202107 (M)",
      main= "Ensamble de los primeros k modelos")
    abline(h= mean(tb_eval$meseta) / 1e6, col= "grey40", lty= 2)
  })
}
'''),
]

# ---------------------------------------------------------------- puntajes de Kaggle
inserts[118] = [
    md(r'''
#### Puntajes publicos de Kaggle (solo modo kaggle)

Correr esta celda unos minutos despues de los submits, cuando Kaggle ya los puntuo.
<br>Ojo: el publico es ~30 % de 202109; en los experimentos #4, #6 y #7 la semilla movio el publico 12-18 M y el orden de los brazos cambio. **Sirve para ver que los archivos esten bien, no para elegir el corte**: el corte sale del backtest.
'''),
    code(r'''
if (PARAM$modo == "kaggle") {
  salida <- system(paste("kaggle competitions submissions -c", PARAM$kaggle$competencia, "-v"),
    intern= TRUE)
  tb_kaggle <- fread(text= paste(salida, collapse= "\n"))
  tb_kaggle <- tb_kaggle[fileName %like% paste0("^KA", PARAM$experimento, "_")]
  tb_kaggle[, envios := as.integer(sub(".*_([0-9]+)\\.csv$", "\\1", fileName))]
  tb_kaggle[, publico := suppressWarnings(as.numeric(publicScore))]
  setorder(tb_kaggle, envios)
  print(tb_kaggle[, list(fileName, envios, status, publico)])
  fwrite(tb_kaggle, file= "kaggle_puntajes.txt", sep= "\t")

  if (any(!is.na(tb_kaggle$publico)))
    graficar("grafico_kaggle_publico.png", function() {
      plot(tb_kaggle$envios, tb_kaggle$publico, type= "b", pch= 19,
        xlab= "envios", ylab= "puntaje publico",
        main= paste0("WF", PARAM$experimento, " - Kaggle publico (30 % de 202109)"))
      abline(v= 11000, lty= 3)
    })
}
'''),
]

# ---------------------------------------------------------------- kaggle
k = src(118)
assert "PARAM$kaggle$cortes <- seq(8000, 12000, by = 500)" in k
k = k.replace("PARAM$kaggle$cortes <- seq(8000, 12000, by = 500)",
    "# centrados en 11.000: el optimo en 202107 esta entre 11.000 y 12.000 y 202109\n"
    "#  tiene ~18 % menos bajas (experimentos #4, #6 y #7). El envio final elegido es 11.000\n"
    "PARAM$kaggle$cortes <- seq(9000, 13000, by = 500)")
k = k.replace('dir.create("kaggle")\n', 'dir.create("kaggle", showWarnings= FALSE)\n')
k = k.replace("for (envios in PARAM$kaggle$cortes) {",
              "if (PARAM$modo == \"kaggle\")\nfor (envios in PARAM$kaggle$cortes) {")
replace(118, "PARAM$kaggle$competencia", k)

# ---------------------------------------------------------------- titulo
replace(0, "# 9 WorkFlow Analista Senior", r'''
# 9 WorkFlow Analista Senior — corrida final (grupo A)

Copia del `z635_WorkFlow_01_senior.ipynb` de la catedra con las decisiones de los experimentos colaborativos 2026. Cambios respecto del z635:

| Etapa | Cambio | Experimento |
|---|---|---|
| Parametros | semilla 100213, `PARAM$modo` kaggle / backtest | — |
| FE intra-mes | + 30 formulas al azar, antes del FE historico | #7 |
| FE historico | ventana 9, tendencia + ratioavg + ratiomax | #4 grupo B |
| FE random forest | apagado | #6 grupo B |
| Canaritos | apagado | #7 (workflow 635) |
| Final training | semillerio de 30 | — |
| Scoring | se agrega el ensamble por promedio de rankings (no se sube) | #7 grupo B |
| Evaluacion | ganancia real por modelo y del ensamble (solo backtest) | — |
| Kaggle | cortes 9.000 a 13.000; el elegido es 11.000 | #4, #6, #7 |

Todo lo demas (CA, drifting, training strategy, BO, final train) queda como en el z635.
''')

# ---------------------------------------------------------------- armado
new_cells = []
for i, c in enumerate(cells):
    c = copy.deepcopy(c)
    if c["cell_type"] == "code":
        c["outputs"] = []
        c["execution_count"] = None
    new_cells.append(c)
    new_cells.extend(inserts.get(i, []))
nb["cells"] = new_cells
json.dump(nb, open(DST, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("celdas:", len(new_cells))
