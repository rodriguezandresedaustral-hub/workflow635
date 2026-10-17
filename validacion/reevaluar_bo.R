# ===========================================================================
# ¿La validación de la BO elige los hiperparámetros que mejor andan en 202107?
#
# La BO del grupo B entrena en 201901-202103, valida en 202105 y maximiza AUC.
# Lo que nos importa es la ganancia en 202107 (y en 202109 para Kaggle). Este
# script toma las configuraciones que la BO ya evaluó (su BO_log.txt) y las
# vuelve a entrenar en tres vistas, sobre el dataset con FE y canaritos de una
# corrida del pipeline (checkpoints/dataset_canaritos.fst):
#
#   V03  train 201901-202101, gap 202102, valida 202103
#   V05  train 201901-202103, gap 202104, valida 202105   (= la BO del grupo B)
#   T07  train 201901-202105, gap 202106, testea 202107   (= el final train)
#
# En V03 y V05 el training lleva el undersampling de la BO (0.2 de los
# CONTINUA); en T07 el de FT_UNDERSAMPLING (0.2 en los brazos). Por cada
# modelo graba AUC, ganancia máxima, envíos del máximo, meseta 8000-12000 y la
# ganancia en cada corte. Va grabando fila por fila: si se corta, retoma.
#
# OJO V03: FE_rf y canaritos entrenan con 202101-202103, así que la vista V03
# está algo contaminada (las features ya "vieron" 202103). V05 y T07 no.
#
# Uso (en la VM, como ds):
#   Rscript reevaluar_bo.R <dataset_canaritos.fst> <BO_log.txt> <salida_dir> [semillas]
#   semillas por defecto: 100213 271211
#   variables: VISTAS="V05 T07 V03"  MAX_CONFIGS=50  NTHREADS=0 (todos)
# ===========================================================================
suppressPackageStartupMessages({ library(data.table); library(fst); library(lightgbm) })

args <- commandArgs(trailingOnly= TRUE)
if (length(args) < 3) stop("uso: Rscript reevaluar_bo.R <dataset_canaritos.fst> <BO_log.txt> <salida_dir> [semillas]")
CK      <- args[1]
BO_LOG  <- args[2]
SALIDA  <- args[3]
SEMILLAS <- if (length(args) >= 4) as.integer(strsplit(args[4], "[ ,]+")[[1]]) else c(100213L, 271211L)
VISTAS   <- strsplit(Sys.getenv("VISTAS", "V05 T07 V03"), " +")[[1]]
MAX_CONFIGS <- as.integer(Sys.getenv("MAX_CONFIGS", "50"))
NTHREADS <- as.integer(Sys.getenv("NTHREADS", "0"))
dir.create(SALIDA, showWarnings= FALSE, recursive= TRUE)
ARCHIVO <- file.path(SALIDA, "reevaluacion.csv")

ACIERTO <- 975000; ERROR <- -25000
CORTES  <- seq(8000, 12000, by= 500)
meses <- function(desde, hasta) {
  todos <- c(201901:201912, 202001:202012, 202101:202112)
  todos[todos >= desde & todos <= hasta]
}
DEF_VISTAS <- list(
  V03= list(train= meses(201901, 202101), valida= 202103, pct= 0.2),
  V05= list(train= meses(201901, 202103), valida= 202105, pct= 0.2),
  T07= list(train= meses(201901, 202105), valida= 202107, pct= as.numeric(Sys.getenv("FT_UNDERSAMPLING", "0.2")))
)

# --- configuraciones de la BO (BO_log.txt guarda los valores en log2) ------
bo <- fread(BO_LOG)
bo[, config := .I]                       # el BO_log viene ordenado por AUC desc
bo <- head(bo, MAX_CONFIGS)
trafo <- function(r) list(
  num_iterations= as.integer(round(2^r$num_iterations)),
  num_leaves= as.integer(round(2^r$num_leaves)),
  learning_rate= 2^r$learning_rate,
  feature_fraction= r$feature_fraction,
  min_sum_hessian_in_leaf= 2^r$min_sum_hessian_in_leaf)
cat(nrow(bo), "configuraciones de", BO_LOG, "\n")

# los mismos parametros fijos que la BO del 635_workflow_senior.R
param_fijos <- list(
  objective= "binary", metric= "auc", first_metric_only= TRUE,
  boost_from_average= TRUE, feature_pre_filter= FALSE, verbosity= -100,
  force_row_wise= TRUE, extra_trees= FALSE, max_depth= -1L,
  min_gain_to_split= 0.0, min_data_in_leaf= 0, lambda_l1= 0.0, lambda_l2= 0.0,
  bagging_fraction= 1.0, pos_bagging_fraction= 1.0, neg_bagging_fraction= 1.0,
  is_unbalance= FALSE, scale_pos_weight= 1.0, max_bin= 31,
  early_stopping_rounds= 0, num_threads= NTHREADS)

# --- dataset ---------------------------------------------------------------
dataset <- read_fst(CK, as.data.table= TRUE)
dataset[, clase01 := as.integer(clase_ternaria %in% c("BAJA+1", "BAJA+2"))]
# igual que el workflow: entra todo menos la clase y el azar
campos_buenos <- setdiff(colnames(dataset), c("clase_ternaria", "clase01", "azar"))
cat("dataset", nrow(dataset), "filas,", length(campos_buenos), "campos\n")

ganancia <- function(prob, clase) {
  o <- order(prob, decreasing= TRUE)
  cg <- cumsum(ifelse(clase[o] == "BAJA+2", ACIERTO, ERROR))
  en_corte <- cg[pmin(CORTES, length(cg))]
  list(maximo= max(cg), envios_max= which.max(cg), meseta= mean(en_corte), cortes= en_corte)
}
auc <- function(prob, y) {   # Mann-Whitney
  r <- frank(prob); n1 <- sum(y); n0 <- length(y) - n1
  (sum(r[y == 1]) - n1 * (n1 + 1) / 2) / (n1 * n0)
}

hechos <- if (file.exists(ARCHIVO)) fread(ARCHIVO)[, paste(vista, semilla, config)] else character()

for (v in VISTAS) {
  dv <- DEF_VISTAS[[v]]
  dval <- dataset[foto_mes %in% dv$valida]
  mval <- data.matrix(dval[, campos_buenos, with= FALSE])
  for (sem in SEMILLAS) {
    pend <- bo$config[!paste(v, sem, bo$config) %in% hechos]
    if (!length(pend)) next
    # el undersampling depende de la semilla, como en el pipeline
    set.seed(sem, kind= "L'Ecuyer-CMRG")
    azar <- runif(nrow(dataset))
    fila_tr <- dataset$foto_mes %in% dv$train &
      (dataset$clase_ternaria %in% c("BAJA+1", "BAJA+2") | azar < dv$pct)
    dtrain <- lgb.Dataset(data= data.matrix(dataset[fila_tr, campos_buenos, with= FALSE]),
                          label= dataset[fila_tr, clase01], free_raw_data= FALSE)
    cat(format(Sys.time()), v, "semilla", sem, ":", sum(fila_tr), "filas de training,", length(pend), "configs\n")
    for (k in pend) {
      x <- trafo(bo[config == k])
      t0 <- Sys.time()
      m <- lgb.train(data= dtrain, param= modifyList(param_fijos, c(x, list(seed= sem))), verbose= -100)
      p <- predict(m, mval)
      g <- ganancia(p, dval$clase_ternaria)
      fila <- data.table(vista= v, mes= dv$valida, semilla= sem, config= k,
        auc_bo= bo[config == k]$y, auc= auc(p, dval$clase01),
        maximo= g$maximo, envios_max= g$envios_max, meseta= g$meseta,
        as.data.table(as.list(setNames(g$cortes, paste0("g", CORTES)))),
        as.data.table(x), minutos= as.numeric(difftime(Sys.time(), t0, units= "mins")))
      fwrite(fila, ARCHIVO, append= file.exists(ARCHIVO))
      cat(sprintf("  %s s%d config %2d  auc %.5f  meseta %.1f M  max %.1f M en %d  (%.1f min)\n",
        v, sem, k, fila$auc, g$meseta / 1e6, g$maximo / 1e6, g$envios_max, fila$minutos))
      rm(m); gc(verbose= FALSE)
    }
    rm(dtrain); gc(verbose= FALSE)
  }
}
cat("listo:", ARCHIVO, "\n")
