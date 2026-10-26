# ===========================================================================
# semillerio.R
#
# Pipeline completo para el modelo final con semillerio, sin optimizacion
# bayesiana (los hiperparametros quedan fijos, ver la seccion LightGBM):
#
#   1. meses rotos a NA
#   2. deflacion por IPC de las variables monetarias
#   3. FE intra mes (ctrx normalizado, combinaciones Visa/Master) y
#      formulas al azar
#   4. lags 1 y 2 con sus deltas, tendencia y ratios de VENTANA meses
#   5. variables de hojas de un random forest (con RF=1)
#   6. poda de variables con canaritos
#   7. final train (pesos temporales con PESOS=1) y N semillas; la prediccion es el
#      promedio de las N
#
# Todo se configura con variables de entorno:
#
#   SEMILLA      semilla primigenia, de ella salen las N semillas (271211)
#   SEMILLERIO   cantidad de modelos del semillerio (12)
#   MODO         final:    entrena hasta 202107, predice 202109, cortes para Kaggle
#                backtest: entrena hasta 202105, predice 202107 y calcula la
#                          ganancia de cada semilla y del semillerio
#   EXPERIMENTO  numero de experimento, la carpeta es exp/WF<EXPERIMENTO>
#   LAGS         0 = saca los lags y deja solo los deltas (1)
#   CANARITOS    0 = sin poda de canaritos (1)
#   PESOS        1 = pesos temporales 0.5 -> 1.0 en el final train (0)
#   VENTANA      meses de la tendencia del FE historico (9)
#   RATIOS       1 = agrega ratioavg y ratiomax de la ventana (1)
#   FORMULAS     cantidad de formulas al azar antes del FE historico (30)
#   RF           1 = variables de hojas de random forest (0)
#   THREADS      hilos de LightGBM (todos los nucleos)
#   EXP_DIR      carpeta de experimentos (/home/ds/buckets/b1/exp)
#   DATASET      dataset (/home/ds/datasets/analistasr_competencia_2026.csv.gz)
#
# ejemplo:
#   SEMILLA=271211 SEMILLERIO=12 EXPERIMENTO=9921 Rscript semillerio.R
#
# Los modelos se graban uno por semilla en modelos/; si se corta, relanzar el
# mismo comando retoma desde el ultimo modelo grabado.
# ===========================================================================

format(Sys.time(), "%a %b %d %X %Y")

env <- function(nombre, defecto) {
  v <- Sys.getenv(nombre)
  if (v == "") defecto else v
}

PARAM <- list()
PARAM$semilla_primigenia <- as.integer(env("SEMILLA", "271211"))
PARAM$modo <- env("MODO", "final")
PARAM$experimento <- as.integer(env("EXPERIMENTO", PARAM$semilla_primigenia))
PARAM$lags <- env("LAGS", "1") == "1"
PARAM$canaritos <- env("CANARITOS", "1") == "1"
PARAM$pesos <- env("PESOS", "0") == "1"
PARAM$FE_hist$ventana <- as.integer(env("VENTANA", "9"))
PARAM$FE_hist$ratios <- env("RATIOS", "1") == "1"
PARAM$formulas <- as.integer(env("FORMULAS", "30"))
PARAM$rf <- env("RF", "0") == "1"
PARAM$threads <- as.integer(env("THREADS", parallel::detectCores()))
PARAM$FT$semillerio <- as.integer(env("SEMILLERIO", "12"))
PARAM$dataset <- env("DATASET", "/home/ds/datasets/analistasr_competencia_2026.csv.gz")
PARAM$exp_dir <- env("EXP_DIR", "/home/ds/buckets/b1/exp")

stopifnot(PARAM$modo %in% c("final", "backtest"))

paquetes <- c("data.table", "R.utils", "lubridate", "Rcpp", "lightgbm", "primes", "yaml")
for (p in paquetes) {
  if (!require(p, character.only= TRUE)) {
    install.packages(p)
    library(p, character.only= TRUE)
  }
}

carpeta <- file.path(PARAM$exp_dir, paste0("WF", PARAM$experimento))
dir.create(carpeta, recursive= TRUE, showWarnings= FALSE)
setwd(carpeta)

dataset <- fread(PARAM$dataset)
setorder(dataset, numero_de_cliente, foto_mes)

# ---------------------------------------------------------------------------
# Meses rotos: campos que en esos meses vienen en cero o con basura. Se pasan
# a NA y LightGBM los trata como faltantes.
# ---------------------------------------------------------------------------
meses_rotos <- list(
  active_quarter = 202006,
  internet = 202006,
  mrentabilidad = c(201905, 201910, 202006),
  mrentabilidad_annual = c(201905, 201910, 202006),
  mcomisiones = c(201905, 201910, 202006),
  mactivos_margen = c(201905, 201910, 202006),
  mpasivos_margen = c(201905, 201910, 202006),
  mcuentas_saldo = 202006,
  ctarjeta_debito_transacciones = 202006,
  mautoservicio = 202006,
  ctarjeta_visa_transacciones = 202006,
  mtarjeta_visa_consumo = 202006,
  ctarjeta_master_transacciones = 202006,
  mtarjeta_master_consumo = 202006,
  ctarjeta_visa_debitos_automaticos = 201904,
  mttarjeta_visa_debitos_automaticos = 201904,
  ccajeros_propios_descuentos = c(201910, 202002, 202006, 202009, 202010, 202102),
  mcajeros_propios_descuentos = c(201910, 202002, 202006, 202009, 202010, 202102),
  ctarjeta_visa_descuentos = c(201910, 202002, 202006, 202009, 202010, 202102),
  mtarjeta_visa_descuentos = c(201910, 202002, 202006, 202009, 202010, 202102),
  ctarjeta_master_descuentos = c(201910, 202002, 202006, 202009, 202010, 202102),
  mtarjeta_master_descuentos = c(201910, 202002, 202006, 202009, 202010, 202102),
  ccomisiones_otras = c(201905, 201910, 202006),
  mcomisiones_otras = c(201905, 201910, 202006),
  cextraccion_autoservicio = 202006,
  mextraccion_autoservicio = 202006,
  ccheques_depositados = 202006,
  mcheques_depositados = 202006,
  ccheques_emitidos = 202006,
  mcheques_emitidos = 202006,
  ccheques_depositados_rechazados = 202006,
  mcheques_depositados_rechazados = 202006,
  ccheques_emitidos_rechazados = 202006,
  mcheques_emitidos_rechazados = 202006,
  tcallcenter = 202006,
  ccallcenter_transacciones = 202006,
  thomebanking = 202006,
  chomebanking_transacciones = c(201910, 202006),
  ccajas_transacciones = 202006,
  ccajas_consultas = 202006,
  ccajas_depositos = c(202006, 202105),
  ccajas_extracciones = 202006,
  ccajas_otras = 202006,
  catm_trx = 202006,
  matm = 202006,
  catm_trx_other = 202006,
  matm_other = 202006
)

for (campo in intersect(names(meses_rotos), colnames(dataset)))
  dataset[foto_mes %in% meses_rotos[[campo]], (campo) := NA]

# ---------------------------------------------------------------------------
# Deflacion: lleva los montos a pesos de diciembre 2020 con el IPC
# ---------------------------------------------------------------------------
tb_ipc <- data.table(
  foto_mes = c(
    201901, 201902, 201903, 201904, 201905, 201906,
    201907, 201908, 201909, 201910, 201911, 201912,
    202001, 202002, 202003, 202004, 202005, 202006,
    202007, 202008, 202009, 202010, 202011, 202012,
    202101, 202102, 202103, 202104, 202105, 202106,
    202107, 202108, 202109
  ),
  IPC = c(
    1.9903030878, 1.9174403544, 1.8296186587,
    1.7728862972, 1.7212488323, 1.6776304408,
    1.6431248196, 1.5814483345, 1.4947526791,
    1.4484037589, 1.3913580777, 1.3404220402,
    1.3154288912, 1.2921698342, 1.2472681797,
    1.2300475145, 1.2118694724, 1.1881073259,
    1.1693969743, 1.1375456949, 1.1065619600,
    1.0681100000, 1.0370000000, 1.0000000000,
    0.9680542110, 0.9344152616, 0.8882274350,
    0.8532444140, 0.8251880213, 0.8003763543,
    0.7763107219, 0.7566381305, 0.7289384687
  )
)

campos_monetarios <- grep("^(m|Visa_m|Master_m|vm_m)", colnames(dataset), value= TRUE)
dataset[tb_ipc, on= "foto_mes", (campos_monetarios) := .SD * i.IPC, .SDcols= campos_monetarios]

# ---------------------------------------------------------------------------
# FE intra mes
# ---------------------------------------------------------------------------
presentes <- function(campos) all(campos %in% colnames(dataset))

AgregarVariables_IntraMes <- function(dataset) {
  cat("inicio AgregarVariables_IntraMes()\n")
  gc(verbose= FALSE)

  if (presentes("foto_mes"))
    dataset[, kmes := foto_mes %% 100]

  # los clientes con menos de 3 meses no llegan a juntar un trimestre de
  # transacciones, se escala lo que tienen
  if (presentes("ctrx_quarter"))
    dataset[, ctrx_quarter_normalizado := as.numeric(ctrx_quarter)]

  if (presentes(c("ctrx_quarter", "cliente_antiguedad"))) {
    dataset[cliente_antiguedad == 1, ctrx_quarter_normalizado := ctrx_quarter * 5]
    dataset[cliente_antiguedad == 2, ctrx_quarter_normalizado := ctrx_quarter * 2]
    dataset[cliente_antiguedad == 3, ctrx_quarter_normalizado := ctrx_quarter * 1.2]
  }

  if (presentes("foto_mes"))
    dataset[, foto_mes_formato_fecha := as.Date(paste(substr(foto_mes, 1, 4), substr(foto_mes, 5, 6), "01", sep= "-"))]

  # transacciones del trimestre: el mes y los dos anteriores
  if (presentes("cantidad_total_transacciones")) {
    menos1 <- dataset[, list(numero_de_cliente, foto_mes_formato_fecha, cantidad_total_transacciones)]
    menos2 <- copy(menos1)
    menos1[, foto_mes_formato_fecha := foto_mes_formato_fecha %m-% months(1)]
    menos2[, foto_mes_formato_fecha := foto_mes_formato_fecha %m-% months(2)]
    menos1[, codigo := paste(numero_de_cliente, foto_mes_formato_fecha, sep= "-")]
    menos2[, codigo := paste(numero_de_cliente, foto_mes_formato_fecha, sep= "-")]

    dataset[, codigo := paste(numero_de_cliente, foto_mes_formato_fecha, sep= "-")]
    dataset[menos1, on= "codigo", transaccionesmenos1 := i.cantidad_total_transacciones]
    dataset[menos2, on= "codigo", transaccionesmenos2 := i.cantidad_total_transacciones]

    dataset[, cantidad_total_transacciones_quarter := rowSums(cbind(cantidad_total_transacciones +
      transaccionesmenos1 + transaccionesmenos2), na.rm= TRUE)]

    dataset[, c("codigo", "transaccionesmenos1", "transaccionesmenos2") := NULL]
    rm(menos1, menos2)
  }
  if (presentes("foto_mes_formato_fecha"))
    dataset[, foto_mes_formato_fecha := NULL]

  if (presentes("cantidad_total_transacciones_quarter"))
    dataset[, cantidad_total_transacciones_quarter_normalizado := cantidad_total_transacciones_quarter]

  if (presentes(c("cantidad_total_transacciones_quarter", "cliente_antiguedad"))) {
    dataset[cliente_antiguedad == 1, cantidad_total_transacciones_quarter_normalizado := cantidad_total_transacciones_quarter * 5]
    dataset[cliente_antiguedad == 2, cantidad_total_transacciones_quarter_normalizado := cantidad_total_transacciones_quarter * 2]
    dataset[cliente_antiguedad == 3, cantidad_total_transacciones_quarter_normalizado := cantidad_total_transacciones_quarter * 1.2]
  }

  if (presentes(c("mpayroll", "cliente_edad")))
    dataset[, mpayroll_sobre_edad := mpayroll / cliente_edad]

  # distintas formas de combinar el status de Visa y Master, cuidando los NA
  if (presentes(c("Master_status", "Visa_status"))) {
    dataset[, vm_status01 := pmax(Master_status, Visa_status, na.rm= TRUE)]
    dataset[, vm_status02 := Master_status + Visa_status]
    dataset[, vm_status03 := pmax(
      ifelse(is.na(Master_status), 10, Master_status),
      ifelse(is.na(Visa_status), 10, Visa_status)
    )]
    dataset[, vm_status04 := ifelse(is.na(Master_status), 10, Master_status)
      + ifelse(is.na(Visa_status), 10, Visa_status)]
    dataset[, vm_status05 := ifelse(is.na(Master_status), 10, Master_status)
      + 100 * ifelse(is.na(Visa_status), 10, Visa_status)]
    dataset[, vm_status06 := ifelse(is.na(Visa_status),
      ifelse(is.na(Master_status), 10, Master_status),
      Visa_status
    )]
    dataset[, mv_status07 := ifelse(is.na(Master_status),
      ifelse(is.na(Visa_status), 10, Visa_status),
      Master_status
    )]
  }

  # Visa + Master: suma de montos, la fecha mas cercana o la mas lejana
  sumas <- c("mfinanciacion_limite", "msaldototal", "msaldopesos", "msaldodolares",
    "mconsumospesos", "mconsumosdolares", "mlimitecompra", "madelantopesos",
    "madelantodolares", "mpagado", "mpagospesos", "mpagosdolares", "mconsumototal",
    "cconsumos", "cadelantosefectivo", "mpagominimo")
  minimos <- c("Fvencimiento", "Finiciomora")
  maximos <- c("fultimo_cierre", "fechaalta")

  for (v in c("mfinanciacion_limite", "Fvencimiento", "Finiciomora", "msaldototal",
              "msaldopesos", "msaldodolares", "mconsumospesos", "mconsumosdolares",
              "mlimitecompra", "madelantopesos", "madelantodolares", "fultimo_cierre",
              "mpagado", "mpagospesos", "mpagosdolares", "fechaalta", "mconsumototal",
              "cconsumos", "cadelantosefectivo", "mpagominimo")) {
    m <- paste0("Master_", v)
    s <- paste0("Visa_", v)
    if (!presentes(c(m, s))) next
    nueva <- paste0("vm_", v)
    if (v %in% sumas) dataset[, (nueva) := rowSums(cbind(get(m), get(s)), na.rm= TRUE)]
    if (v %in% minimos) dataset[, (nueva) := pmin(get(m), get(s), na.rm= TRUE)]
    if (v %in% maximos) dataset[, (nueva) := pmax(get(m), get(s), na.rm= TRUE)]
  }

  # ratios contra el limite de compra (y contra el saldo total)
  ratios <- list(
    vmr_Master_mlimitecompra = c("Master_mlimitecompra", "vm_mlimitecompra"),
    vmr_Visa_mlimitecompra = c("Visa_mlimitecompra", "vm_mlimitecompra"),
    vmr_msaldototal = c("vm_msaldototal", "vm_mlimitecompra"),
    vmr_msaldopesos = c("vm_msaldopesos", "vm_mlimitecompra"),
    vmr_msaldopesos2 = c("vm_msaldopesos", "vm_msaldototal"),
    vmr_msaldodolares = c("vm_msaldodolares", "vm_mlimitecompra"),
    vmr_msaldodolares2 = c("vm_msaldodolares", "vm_msaldototal"),
    vmr_mconsumospesos = c("vm_mconsumospesos", "vm_mlimitecompra"),
    vmr_mconsumosdolares = c("vm_mconsumosdolares", "vm_mlimitecompra"),
    vmr_madelantopesos = c("vm_madelantopesos", "vm_mlimitecompra"),
    vmr_madelantodolares = c("vm_madelantodolares", "vm_mlimitecompra"),
    vmr_mpagado = c("vm_mpagado", "vm_mlimitecompra"),
    vmr_mpagospesos = c("vm_mpagospesos", "vm_mlimitecompra"),
    vmr_mpagosdolares = c("vm_mpagosdolares", "vm_mlimitecompra"),
    vmr_mconsumototal = c("vm_mconsumototal", "vm_mlimitecompra"),
    vmr_mpagominimo = c("vm_mpagominimo", "vm_mlimitecompra")
  )
  for (nueva in names(ratios)) {
    r <- ratios[[nueva]]
    if (presentes(r)) dataset[, (nueva) := get(r[1]) / get(r[2])]
  }

  # infinitos a NA y 0/0 a 0
  infinitos <- sum(sapply(dataset, function(x) sum(is.infinite(x))))
  if (infinitos > 0) {
    cat(infinitos, "valores infinitos, pasan a NA\n")
    dataset[mapply(is.infinite, dataset)] <<- NA
  }

  nans <- sum(sapply(dataset, function(x) sum(is.nan(x))))
  if (nans > 0) {
    cat(nans, "valores NaN, pasan a 0\n")
    dataset[mapply(is.nan, dataset)] <<- 0
  }

  cat("fin AgregarVariables_IntraMes()\n")
}

AgregarVariables_IntraMes(dataset)
cat("columnas despues del FE intra mes:", ncol(dataset), "\n")

# ---------------------------------------------------------------------------
# Formulas al azar: v1 op v2 o (v1 op v2) op v3 con campos del mes. En el
# experimento #7 sumar formulas sorteadas gano ~3 M (E2 - E0 +2,85 M, 16 de
# 20 semillas) y buscarlas con un genetico no le gano al azar. Van antes del
# FE historico, asi reciben lags, deltas y tendencia como cualquier campo
# ---------------------------------------------------------------------------
evaluar_formula <- function(formula, tabla) {
  v <- tryCatch(eval(parse(text= formula)[[1]], envir= tabla), error= function(e) NULL)
  if (is.null(v) || length(v) != nrow(tabla)) return(NULL)
  v <- as.numeric(v)
  v[is.infinite(v)] <- NA
  v[is.nan(v)] <- 0
  if (length(unique(v[!is.na(v)])) < 2) return(NULL)   # constante: no aporta
  v
}

# distintas y no constantes en la muestra; usa su propia semilla y deja el
# RNG de R como estaba
sortear_formulas <- function(n, vars, semilla, muestra) {
  rng <- if (exists(".Random.seed", envir= globalenv())) get(".Random.seed", envir= globalenv())
  set.seed(semilla, kind= "L'Ecuyer-CMRG")
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

if (PARAM$formulas > 0) {
  numericas <- names(dataset)[sapply(dataset, is.numeric)]
  vars <- setdiff(numericas, c("numero_de_cliente", "foto_mes"))
  formulas <- sortear_formulas(PARAM$formulas, vars, PARAM$semilla_primigenia,
    dataset[foto_mes == 202101])   # mes de training, sin mirar la clase
  tb_formulas <- data.table(nombre= sprintf("form_%02d", seq_along(formulas)), formula= formulas)
  for (i in seq_len(nrow(tb_formulas)))
    set(dataset, j= tb_formulas$nombre[i], value= evaluar_formula(tb_formulas$formula[i], dataset))
  fwrite(tb_formulas, file= "formulas.txt", sep= "\t")
  cat("formulas al azar:", nrow(tb_formulas), "\n")
}

# ---------------------------------------------------------------------------
# FE historico: lags, deltas, tendencia y ratios de los ultimos VENTANA meses
# ---------------------------------------------------------------------------

# pendiente de cuadrados minimos, min, max y promedio de la ventana, en C++
# porque en R puro tarda demasiado
cppFunction("NumericVector fhistC(NumericVector pcolumna, IntegerVector pdesde )
{
  double  x[100] ;
  double  y[100] ;

  int n = pcolumna.size();
  NumericVector out( 5*n );

  for(int i = 0; i < n; i++)
  {
    if( pdesde[i]-1 < i )  out[ i + 4*n ]  =  pcolumna[i-1] ;
    else                   out[ i + 4*n ]  =  NA_REAL ;

    int  libre    = 0 ;
    int  xvalor   = 1 ;

    for( int j= pdesde[i]-1;  j<=i; j++ )
    {
       double a = pcolumna[j] ;

       if( !R_IsNA( a ) )
       {
          y[ libre ]= a ;
          x[ libre ]= xvalor ;
          libre++ ;
       }

       xvalor++ ;
    }

    if( libre > 1 )
    {
      double  xsum  = x[0] ;
      double  ysum  = y[0] ;
      double  xysum = xsum * ysum ;
      double  xxsum = xsum * xsum ;
      double  vmin  = y[0] ;
      double  vmax  = y[0] ;

      for( int h=1; h<libre; h++)
      {
        xsum  += x[h] ;
        ysum  += y[h] ;
        xysum += x[h]*y[h] ;
        xxsum += x[h]*x[h] ;

        if( y[h] < vmin )  vmin = y[h] ;
        if( y[h] > vmax )  vmax = y[h] ;
      }

      out[ i ]  =  (libre*xysum - xsum*ysum)/(libre*xxsum -xsum*xsum) ;
      out[ i + n ]    =  vmin ;
      out[ i + 2*n ]  =  vmax ;
      out[ i + 3*n ]  =  ysum / libre ;
    }
    else
    {
      out[ i       ]  =  NA_REAL ;
      out[ i + n   ]  =  NA_REAL ;
      out[ i + 2*n ]  =  NA_REAL ;
      out[ i + 3*n ]  =  NA_REAL ;
    }
  }

  return  out;
}")

# agrega <campo>_tend<ventana> (y opcionalmente min, max, promedio y ratios)
# a cada columna de cols; el dataset tiene que estar ordenado por cliente y mes
TendenciaYmuchomas <- function(
    dataset, cols, ventana = 6, tendencia = TRUE,
    minimo = TRUE, maximo = TRUE, promedio = TRUE,
    ratioavg = FALSE, ratiomax = FALSE) {
  gc(verbose= FALSE)
  last <- nrow(dataset)

  # vector_desde: donde empieza la ventana de cada fila, sin pasar al
  # cliente anterior
  vector_ids <- dataset[, numero_de_cliente]
  vector_desde <- seq(-ventana + 2, nrow(dataset) - ventana + 1)
  vector_desde[1:ventana] <- 1

  for (i in 2:last) {
    if (vector_ids[i - 1] != vector_ids[i]) vector_desde[i] <- i
  }
  for (i in 2:last) {
    if (vector_desde[i] < vector_desde[i - 1]) vector_desde[i] <- vector_desde[i - 1]
  }

  for (campo in cols) {
    nueva_col <- fhistC(dataset[, get(campo)], vector_desde)

    if (tendencia)
      dataset[, paste0(campo, "_tend", ventana) := nueva_col[(0 * last + 1):(1 * last)]]
    if (minimo)
      dataset[, paste0(campo, "_min", ventana) := nueva_col[(1 * last + 1):(2 * last)]]
    if (maximo)
      dataset[, paste0(campo, "_max", ventana) := nueva_col[(2 * last + 1):(3 * last)]]
    if (promedio)
      dataset[, paste0(campo, "_avg", ventana) := nueva_col[(3 * last + 1):(4 * last)]]
    if (ratioavg)
      dataset[, paste0(campo, "_ratioavg", ventana) := get(campo) / nueva_col[(3 * last + 1):(4 * last)]]
    if (ratiomax)
      dataset[, paste0(campo, "_ratiomax", ventana) := get(campo) / nueva_col[(2 * last + 1):(3 * last)]]
  }
}

setorder(dataset, numero_de_cliente, foto_mes)

cols_lagueables <- copy(setdiff(
  colnames(dataset),
  c("numero_de_cliente", "foto_mes", "clase_ternaria")
))

dataset[, paste0(cols_lagueables, "_lag1") := shift(.SD, 1, NA, "lag"),
  by= numero_de_cliente, .SDcols= cols_lagueables]

dataset[, paste0(cols_lagueables, "_lag2") := shift(.SD, 2, NA, "lag"),
  by= numero_de_cliente, .SDcols= cols_lagueables]

for (vcol in cols_lagueables) {
  dataset[, paste0(vcol, "_delta1") := get(vcol) - get(paste0(vcol, "_lag1"))]
  dataset[, paste0(vcol, "_delta2") := get(vcol) - get(paste0(vcol, "_lag2"))]
}

if (!PARAM$lags)
  dataset[, c(paste0(cols_lagueables, "_lag1"), paste0(cols_lagueables, "_lag2")) := NULL]

cols_lagueables <- intersect(cols_lagueables, colnames(dataset))
setorder(dataset, numero_de_cliente, foto_mes)

# TendenciaYmuchomas agrega columnas con := a su argumento dataset: si el
# data.table se queda sin lugares reservados para columnas, las nuevas quedan
# en una copia local y se pierden sin error. Se reserva el lugar antes, afuera
sufijos <- c("_tend", if (PARAM$FE_hist$ratios) c("_ratioavg", "_ratiomax"))
setalloccol(dataset, ncol(dataset) + length(sufijos) * length(cols_lagueables) + 100)

TendenciaYmuchomas(dataset,
  cols = cols_lagueables,
  ventana = PARAM$FE_hist$ventana,
  tendencia = TRUE,
  minimo = FALSE,
  maximo = FALSE,
  promedio = FALSE,
  ratioavg = PARAM$FE_hist$ratios,
  ratiomax = PARAM$FE_hist$ratios
)

for (s in paste0(sufijos, PARAM$FE_hist$ventana)) {
  faltan <- setdiff(paste0(cols_lagueables, s), colnames(dataset))
  if (length(faltan)) stop("faltan ", length(faltan), " columnas ", s, " del FE historico")
}
cat("columnas despues del FE historico:", ncol(dataset), "\n")

# ---------------------------------------------------------------------------
# Variables de random forest: un LightGBM en modo rf entrenado en
# 202101-202103; cada hoja de cada arbol pasa a ser una variable 0/1
# ---------------------------------------------------------------------------
PARAM$FE_rf$arbolitos <- 20
PARAM$FE_rf$hojas_por_arbol <- 16
PARAM$FE_rf$datos_por_hoja <- 100
PARAM$FE_rf$mtry_ratio <- 0.2
PARAM$FE_rf$train$clase01_valor1 <- c("BAJA+2", "BAJA+1")
PARAM$FE_rf$train$training <- c(202101, 202102, 202103)

PARAM$FE_rf$lgb_param <- list(
  num_iterations = PARAM$FE_rf$arbolitos,
  num_leaves = PARAM$FE_rf$hojas_por_arbol,
  min_data_in_leaf = PARAM$FE_rf$datos_por_hoja,
  feature_fraction_bynode = PARAM$FE_rf$mtry_ratio,

  boosting = "rf",
  bagging_fraction = (1.0 - 1.0 / exp(1.0)),
  bagging_freq = 1.0,
  feature_fraction = 1.0,

  max_bin = 31L,
  objective = "binary",
  first_metric_only = TRUE,
  boost_from_average = TRUE,
  feature_pre_filter = FALSE,
  force_row_wise = TRUE,
  verbosity = -100,
  max_depth = -1L,
  min_gain_to_split = 0.0,
  min_sum_hessian_in_leaf = 0.001,
  lambda_l1 = 0.0,
  lambda_l2 = 0.0,
  pos_bagging_fraction = 1.0,
  neg_bagging_fraction = 1.0,
  is_unbalance = FALSE,
  scale_pos_weight = 1.0,
  drop_rate = 0.1,
  max_drop = 50,
  skip_drop = 0.5,
  extra_trees = FALSE
)

AgregaVarRandomForest <- function() {
  cat("inicio AgregaVarRandomForest()\n")
  gc(verbose= FALSE)
  dataset[, clase01 := 0L]
  dataset[clase_ternaria %in% PARAM$FE_rf$train$clase01_valor1, clase01 := 1L]

  campos_buenos <- setdiff(colnames(dataset), c("clase_ternaria", "clase01"))

  dataset[, entrenamiento := as.integer(foto_mes %in% PARAM$FE_rf$train$training)]

  dtrain <- lgb.Dataset(
    data = data.matrix(dataset[entrenamiento == TRUE, campos_buenos, with= FALSE]),
    label = dataset[entrenamiento == TRUE, clase01],
    free_raw_data = FALSE
  )

  modelo <- lgb.train(data= dtrain, param= PARAM$FE_rf$lgb_param, verbose= -100)
  lgb.save(modelo, file= "modelo_rf.model")

  for (periodo in dataset[, unique(foto_mes)]) {
    cat("periodo", periodo, "\n")
    datamatrix <- data.matrix(dataset[foto_mes == periodo, campos_buenos, with= FALSE])
    prediccion <- predict(modelo, datamatrix, type= "leaf")

    for (arbolito in 1:PARAM$FE_rf$arbolitos) {
      for (nodo_id in unique(prediccion[, arbolito])) {
        dataset[foto_mes == periodo,
          paste0("rf_", sprintf("%03d", arbolito), "_", sprintf("%03d", nodo_id)) :=
            as.integer(nodo_id == prediccion[, arbolito])]
      }
    }

    rm(prediccion, datamatrix)
    gc(verbose= FALSE)
  }

  dataset[, clase01 := NULL]
}

# experimento #6 (grupo B): sin estas variables se gana lo mismo (p 0,557) y
# la corrida es mas rapida
if (PARAM$rf) {
  AgregaVarRandomForest()
  cat("columnas despues del random forest:", ncol(dataset), "\n")
}

# ---------------------------------------------------------------------------
# Canaritos: se agregan columnas al azar, se entrena un LightGBM y se borra
# todo lo que queda por debajo de mediana + 2 desvios del puesto de las
# canaritos en la importancia
# ---------------------------------------------------------------------------
PARAM$CN$ratio <- 0.2
PARAM$CN$desvios <- 2
PARAM$CN$train$clase01_valor1 <- c("BAJA+2", "BAJA+1")
PARAM$CN$train$positivos <- c("BAJA+2")
PARAM$CN$train$training <- c(202101, 202102, 202103)
PARAM$CN$train$validation <- c(202105)
PARAM$CN$train$undersampling <- 0.1
PARAM$CN$train$gan1 <- 0.975
PARAM$CN$train$gan0 <- -0.025

# ganancia promedio de las 500 mejores posiciones de la curva
fganancia_meseta <- function(probs, datos) {
  vlabels <- get_field(datos, "label")
  vpesos <- get_field(datos, "weight")

  tbl <- data.table(
    prob = probs,
    gan = ifelse(vlabels == 1 & vpesos > 1, PARAM$CN$train$gan1, PARAM$CN$train$gan0)
  )
  setorder(tbl, -prob)
  tbl[, gan_acum := cumsum(gan)]
  setorder(tbl, -gan_acum)

  list(name= "ganancia", value= mean(tbl[1:500, gan_acum]), higher_better= TRUE)
}

campitos <- c("numero_de_cliente", "foto_mes", "clase_ternaria")

PodarConCanaritos <- function(ratio, desvios, semilla) {
  cat("inicio PodarConCanaritos()\n")
  gc(verbose= FALSE)
  dataset[, clase01 := 0L]
  dataset[clase_ternaria %in% PARAM$CN$train$clase01_valor1, clase01 := 1L]

  set.seed(semilla, kind= "L'Ecuyer-CMRG")
  for (i in 1:(ncol(dataset) * ratio))
    dataset[, paste0("canarito", i) := runif(nrow(dataset))]

  campos_buenos <- setdiff(colnames(dataset), c(campitos, "clase01"))

  azar <- runif(nrow(dataset))
  dataset[, entrenamiento := as.integer(foto_mes %in% PARAM$CN$train$training &
    (clase01 == 1 | azar < PARAM$CN$train$undersampling))]

  dtrain <- lgb.Dataset(
    data = data.matrix(dataset[entrenamiento == TRUE, campos_buenos, with= FALSE]),
    label = dataset[entrenamiento == TRUE, clase01],
    weight = dataset[entrenamiento == TRUE,
      ifelse(clase_ternaria %in% PARAM$CN$train$positivos, 1.0000001, 1.0)],
    free_raw_data = FALSE
  )

  dvalid <- lgb.Dataset(
    data = data.matrix(dataset[foto_mes %in% PARAM$CN$train$validation, campos_buenos, with= FALSE]),
    label = dataset[foto_mes %in% PARAM$CN$train$validation, clase01],
    weight = dataset[foto_mes %in% PARAM$CN$train$validation,
      ifelse(clase_ternaria %in% PARAM$CN$train$positivos, 1.0000001, 1.0)],
    free_raw_data = FALSE
  )

  param <- list(
    objective = "binary",
    metric = "custom",
    first_metric_only = TRUE,
    boost_from_average = TRUE,
    feature_pre_filter = FALSE,
    verbosity = -100,
    seed = semilla,
    max_depth = -1,
    min_gain_to_split = 0.0,
    lambda_l1 = 0.0,
    lambda_l2 = 0.0,
    max_bin = 31,
    num_iterations = 9999,
    force_row_wise = TRUE,
    learning_rate = 0.065,
    feature_fraction = 1.0,
    min_data_in_leaf = 260,
    num_leaves = 60,
    early_stopping_rounds = 200,
    num_threads = 1
  )

  set.seed(semilla, kind= "L'Ecuyer-CMRG")
  modelo <- lgb.train(
    data = dtrain,
    valids = list(valid= dvalid),
    eval = fganancia_meseta,
    param = param,
    verbose = -100
  )

  tb_importancia <- lgb.importance(model= modelo)
  tb_importancia[, pos := .I]

  umbral <- tb_importancia[Feature %like% "canarito", median(pos) + desvios * sd(pos)]
  col_utiles <- tb_importancia[pos < umbral & !(Feature %like% "canarito"), Feature]
  col_utiles <- unique(c(col_utiles, campitos, "mes"))

  dataset[, (setdiff(colnames(dataset), col_utiles)) := NULL]

  cat("fin PodarConCanaritos()\n")
  tb_importancia
}

if (PARAM$canaritos) {
  tb_importancia <- PodarConCanaritos(
    ratio = PARAM$CN$ratio,
    desvios = PARAM$CN$desvios,
    semilla = PARAM$semilla_primigenia
  )
  fwrite(tb_importancia, file= "canaritos.txt", sep= "\t")
}

cat("columnas despues de canaritos:", ncol(dataset), "\n")

# ---------------------------------------------------------------------------
# Final train
# ---------------------------------------------------------------------------
meses <- c(
  201901, 201902, 201903, 201904, 201905, 201906,
  201907, 201908, 201909, 201910, 201911, 201912,
  202001, 202002, 202003, 202004, 202005, 202006,
  202007, 202008, 202009, 202010, 202011, 202012,
  202101, 202102, 202103, 202104, 202105, 202106,
  202107
)

if (PARAM$modo == "final") {
  PARAM$trainingstrategy$final_train <- meses
  PARAM$trainingstrategy$future <- 202109
} else {
  PARAM$trainingstrategy$final_train <- meses[meses <= 202105]
  PARAM$trainingstrategy$future <- 202107
}
PARAM$trainingstrategy$positivos <- c("BAJA+1", "BAJA+2")

dataset[, clase01 := ifelse(clase_ternaria %in% PARAM$trainingstrategy$positivos, 1, 0)]

campos_buenos <- copy(setdiff(
  colnames(dataset),
  c("clase_ternaria", "clase01", "foto_mes", "mes_indice", "peso_temporal_final")
))

# pesos temporales: lineal de 0.5 (el mes mas viejo) a 1.0 (el mas nuevo)
dataset[, mes_indice := (foto_mes %/% 100) * 12 + (foto_mes %% 100)]
dataset[, fold_final_train := foto_mes %in% PARAM$trainingstrategy$final_train]

mes_min <- min(dataset[fold_final_train == TRUE, mes_indice])
mes_max <- max(dataset[fold_final_train == TRUE, mes_indice])
dataset[, peso_temporal_final := 0.5 + 0.5 * (mes_indice - mes_min) / (mes_max - mes_min)]

# PESOS=0 (default): sin pesos. En el experimento #4 (grupo A) esta misma
# ponderacion 0.5 -> 1 perdio -9,9 M contra las estrategias lideres (Holm 0,029)
dfinal_train <- lgb.Dataset(
  data = data.matrix(dataset[fold_final_train == TRUE, campos_buenos, with= FALSE]),
  label = dataset[fold_final_train == TRUE, clase01],
  weight = if (PARAM$pesos) dataset[fold_final_train == TRUE, peso_temporal_final] else NULL,
  free_raw_data = TRUE
)

# hiperparametros fijos, sacados de una optimizacion bayesiana anterior
param_final <- list(
  objective = "binary",
  metric = "auc",
  num_threads = PARAM$threads,
  first_metric_only = TRUE,
  boost_from_average = TRUE,
  feature_pre_filter = FALSE,
  verbosity = -100,
  force_row_wise = TRUE,
  seed = PARAM$semilla_primigenia,
  extra_trees = FALSE,
  max_depth = -1L,
  min_gain_to_split = 0.0,
  min_data_in_leaf = 0,
  lambda_l1 = 0.0,
  lambda_l2 = 0.0,
  bagging_fraction = 1.0,
  pos_bagging_fraction = 1.0,
  neg_bagging_fraction = 1.0,
  is_unbalance = FALSE,
  scale_pos_weight = 1.0,
  drop_rate = 0.1,
  max_drop = 50,
  skip_drop = 0.5,
  max_bin = 31,

  num_iterations = 1004,
  num_leaves = 2035,
  learning_rate = 0.0237579299724983,
  feature_fraction = 0.41700652750075,
  min_sum_hessian_in_leaf = 0.171459305354304
)
PARAM$lgbm$param_final <- param_final

# las N semillas del semillerio: primos al azar a partir de la primigenia
primos <- generate_primes(min= 100000, max= 1000000)
set.seed(PARAM$semilla_primigenia, kind= "L'Ecuyer-CMRG")
PARAM$FT$semillas <- sample(primos)[seq(PARAM$FT$semillerio)]
cat("semillas:", PARAM$FT$semillas, "\n")

dir.create("modelos", showWarnings= FALSE)

for (sem in PARAM$FT$semillas) {
  archivo <- paste0("./modelos/modelo_", sem, ".txt")
  if (file.exists(archivo)) next

  param_final$seed <- sem
  set.seed(sem, kind= "L'Ecuyer-CMRG")
  modelo <- lgb.train(data= dfinal_train, param= param_final, verbose= -100)
  lgb.save(modelo, archivo)

  if (!file.exists("impo.txt"))
    fwrite(as.data.table(lgb.importance(modelo)), file= "impo.txt", sep= "\t")

  rm(modelo)
  gc(full= TRUE, verbose= FALSE)
}

# ---------------------------------------------------------------------------
# Prediccion: prob_<i> de cada semilla y prob, el promedio
# ---------------------------------------------------------------------------
dfuture <- dataset[foto_mes %in% PARAM$trainingstrategy$future]
datos_matrix <- data.matrix(dfuture[, campos_buenos, with= FALSE])

tb_prediccion <- dfuture[, list(numero_de_cliente)]
tb_prediccion[, prob := 0]

for (isem in seq_along(PARAM$FT$semillas)) {
  modelo <- lgb.load(paste0("./modelos/modelo_", PARAM$FT$semillas[isem], ".txt"))
  prediccion <- predict(modelo, datos_matrix)
  tb_prediccion[, paste0("prob_", isem) := prediccion]
  tb_prediccion[, prob := prob + prediccion]
  rm(modelo, prediccion)
  gc(full= TRUE, verbose= FALSE)
}
rm(datos_matrix)

tb_prediccion[, prob := prob / length(PARAM$FT$semillas)]
fwrite(tb_prediccion, file= "prediccion.txt", sep= "\t")

cortes <- seq(8000, 12000, by= 500)

if (PARAM$modo == "final") {
  # un csv por corte, para subir a mano
  setorder(tb_prediccion, -prob)
  dir.create("kaggle", showWarnings= FALSE)

  for (envios in cortes) {
    tb_prediccion[, Predicted := 0L]
    tb_prediccion[1:envios, Predicted := 1L]
    fwrite(tb_prediccion[, list(numero_de_cliente, Predicted)],
      file= paste0("./kaggle/KA", PARAM$experimento, "_s", length(PARAM$FT$semillas), "_", envios, ".csv"),
      sep= ","
    )
  }
} else {
  # ganancia en 202107 de cada semilla sola y del semillerio, para comparar
  # variantes de a pares con las mismas semillas
  tb_prediccion[, clase_ternaria := dfuture$clase_ternaria]
  stopifnot(tb_prediccion[, sum(clase_ternaria == "BAJA+2")] > 0)
  tb_prediccion[, gan := ifelse(clase_ternaria == "BAJA+2", 975000, -25000)]

  col_prob <- c(paste0("prob_", seq_along(PARAM$FT$semillas)), "prob")
  tb_gan <- rbindlist(lapply(col_prob, function(cp) {
    g <- tb_prediccion[order(-get(cp)), cumsum(gan)]
    fila <- list(
      semilla = if (cp == "prob") "semillerio" else as.character(PARAM$FT$semillas[as.integer(sub("prob_", "", cp))]),
      gan_max = max(g),
      envios_max = which.max(g),
      gan_meseta = mean(sort(g, decreasing= TRUE)[1:500]),
      # promedio de los cortes 8.000 a 12.000: la meseta de los experimentos
      # #6 y #7 y del workflow 635, para comparar con esas corridas
      gan_meseta_cortes = mean(g[cortes])
    )
    c(fila, as.list(setNames(g[cortes], paste0("gan_", cortes))))
  }))
  tb_gan[, experimento := PARAM$experimento]
  fwrite(tb_gan, file= "ganancias_semillas.txt", sep= "\t")
  print(tb_gan)
}

write_yaml(PARAM, file= "PARAM.yml")

format(Sys.time(), "%a %b %d %X %Y")
