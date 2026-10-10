# ===========================================================================
# 635_workflow_senior.R
#
# El workflow del z635_WorkFlow_01_senior.ipynb (catedra) como script para
# correr desatendido en una VM Spot:
#
#   Rscript 635_workflow_senior.R .env  >> log.txt 2>&1
#
# Las funciones y celdas de la catedra estan COPIADAS SIN CAMBIOS (cada bloque
# dice de que celda viene). Lo agregado:
#
#   * configuracion desde un .env (ver .env.example): grupo, rutas, mail, kaggle
#   * GRUPO A: valida 202107, final train hasta 202107, predice 202109, Kaggle
#     GRUPO B: valida 202105, final train hasta 202105, predice 202107 y
#              calcula la ganancia contra la clase real de 202107. Sin Kaggle.
#   * semillerio con semillas fijas (PARAM$FT$semillas) en vez de primos al azar
#   * mail a una LISTA de destinatarios: arranque, fin de cada etapa, cada N
#     evaluaciones de la BO, error (con la etapa) y fin
#   * checkpoints en el bucket, para que una VM expropiada no pierda trabajo:
#       - dataset despues del FE historico y despues de canaritos (.fst)
#       - BO: cada evaluacion del diseno inicial y cada iteracion (HT.RDATA)
#       - modelos finales: uno por semilla (ya lo hacia el z635)
#       - Kaggle: una marca por archivo subido, no se resube
#     Relanzar el mismo comando retoma desde lo ultimo guardado.
# ===========================================================================

format(Sys.time(), "%a %b %d %X %Y")

# ---------------------------------------------------------------------------
# PAQUETES: libreria del usuario (la VM es nueva en cada lanzamiento)
# ---------------------------------------------------------------------------
dir.create(Sys.getenv("R_LIBS_USER"), recursive= TRUE, showWarnings= FALSE)
.libPaths(c(Sys.getenv("R_LIBS_USER"), .libPaths()))
options(repos= c(CRAN= "https://cloud.r-project.org"))

# --- z635 celda 9 ---
require("data.table")

if( !require("R.utils")) install.packages("R.utils")
require("R.utils")

if (!require("fst")) install.packages("fst")
require("fst")

# ---------------------------------------------------------------------------
# CONFIGURACION desde el .env
# ---------------------------------------------------------------------------
args <- commandArgs(trailingOnly= TRUE)
archivo_env <- if (length(args) >= 1) args[1] else ".env"
if (!file.exists(archivo_env)) stop("No existe el archivo de configuracion ", archivo_env,
  " (copiar .env.example y completarlo)")
readRenviron(archivo_env)

requeridas <- c("GRUPO", "EXPERIMENTO", "BUCKET_DIR", "DATASET_PATH",
  "MAIL_FROM", "MAIL_PASS_FILE", "MAIL_TO_FILE")
GRUPO <- toupper(Sys.getenv("GRUPO"))
if (GRUPO == "A") requeridas <- c(requeridas, "KAGGLE_JSON", "KAGGLE_COMPETENCIA")
faltan <- requeridas[Sys.getenv(requeridas) == ""]
if (length(faltan)) stop("Faltan variables en ", archivo_env, ": ", paste(faltan, collapse= ", "))
if (!(GRUPO %in% c("A", "B"))) stop("GRUPO tiene que ser A o B, no '", GRUPO, "'")
if (!file.exists(Sys.getenv("DATASET_PATH"))) stop("No existe DATASET_PATH: ", Sys.getenv("DATASET_PATH"))

PARAM <- list()
PARAM$semilla_primigenia <- 100213
PARAM$experimento <- as.integer(Sys.getenv("EXPERIMENTO"))
PARAM$grupo <- GRUPO
PARAM$dataset <- basename(Sys.getenv("DATASET_PATH"))

# semillerio del final training: semillas fijas. Las 5 primeras son del
# usuario; las 4 ultimas son primos sorteados con
#   set.seed(100213); sample(setdiff(primes::generate_primes(100000, 1000000), mias), 4)
PARAM$FT$semillas <- c(100213, 100313, 100613, 100913, 101113,
                       570991, 669287, 832421, 882599)
PARAM$FT$semillerio <- length(PARAM$FT$semillas)

PARAM$mail$desde    <- Sys.getenv("MAIL_FROM")
PARAM$mail$cada_iter <- as.integer(Sys.getenv("MAIL_CADA_ITER", "5"))

# ganancia del problema, para el grupo B (testing contra 202107)
PARAM$ganancia$acierto <- 975000    # BAJA+2 enviado
PARAM$ganancia$error   <- -25000    # cualquier otro enviado
PARAM$kaggle$cortes <- seq(8000, 12000, by = 500)

# --- FE genetico (consigna del FE intra-mes) --------------------------------
# Por ronda, gramEvol evoluciona formulas  v1 op v2  o  (v1 op v2) op v3
# sobre los campos del mes. Fitness: cuanta ganancia agrega la formula a un
# LightGBM fijo, medida en el mes de validacion del grupo (nunca el de testing).
# La mejor de la ronda se queda solo si mejora mas que 2 desvios del ruido entre
# semillas; si no, se corta. Cada ganadora entra como columna gen_<ronda>.
PARAM$GA$rondas        <- 3     # cuantas variables geneticas buscar como maximo
PARAM$GA$poblacion     <- 30    # formulas por generacion
PARAM$GA$generaciones  <- 20    # generaciones por ronda
PARAM$GA$mail_cada_gen <- 1     # mail de avance cada N generaciones
PARAM$GA$horas_max     <- Inf   # sin tope: la genetica corre todas sus rondas y
                                # generaciones. Con un numero, al llegar a esas horas
                                # cierra la ronda con la mejor formula medida y sigue
                                # sola con el resto del workflow
PARAM$GA$desvios       <- 2     # la mejora tiene que superar desvios * ruido
PARAM$GA$proteger_de_canaritos <- FALSE   # TRUE: canaritos no puede borrar las gen_*
PARAM$GA$undersampling <- 0.1   # fraccion de CONTINUA en el training del fitness
PARAM$GA$entrena <- if (GRUPO == "A") c(202101, 202102, 202103, 202104, 202105) else c(202101, 202102, 202103)
PARAM$GA$valida  <- if (GRUPO == "A") c(202107) else c(202105)
PARAM$GA$semillas_ruido <- PARAM$FT$semillas[1:3]
PARAM$GA$lgb_param <- list(
  objective= "binary",
  num_iterations= 200,
  learning_rate= 0.065,
  num_leaves= 60,
  min_data_in_leaf= 260,
  # con feature_fraction 1 y sin bagging la semilla no cambia nada y el ruido
  # entre semillas daria 0: el umbral quedaria en 0 y pasaria cualquier formula
  feature_fraction= 0.5,
  bagging_fraction= 0.8,
  bagging_freq= 1,
  max_bin= 31,
  force_row_wise= TRUE,
  deterministic= TRUE,
  verbosity= -100,
  num_threads= parallel::detectCores()
)

# ---------------------------------------------------------------------------
# CARPETA DEL EXPERIMENTO (en el bucket: todo lo que se graba sobrevive)
# ---------------------------------------------------------------------------
carpeta_exp <- file.path(Sys.getenv("BUCKET_DIR"), "exp", paste0("WF", PARAM$experimento))
dir.create(carpeta_exp, recursive= TRUE, showWarnings= FALSE)
setwd(carpeta_exp)
dir.create("checkpoints", showWarnings= FALSE)

loguear <- function(...) cat(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "|", ..., "\n")
loguear("experimento", PARAM$experimento, "grupo", GRUPO, "en", carpeta_exp)

# ---------------------------------------------------------------------------
# MAIL: Gmail SMTP con curl, a todos los de MAIL_TO_FILE (uno por linea).
# Un mail que falla se loguea y la corrida sigue.
# ---------------------------------------------------------------------------
destinatarios <- function() {
  arch <- Sys.getenv("MAIL_TO_FILE")
  if (!file.exists(arch)) return(character(0))
  d <- trimws(readLines(arch, warn= FALSE))
  d[d != "" & !startsWith(d, "#")]
}

mandar_mail <- function(titulo, cuerpo) {
  tryCatch({
    para <- destinatarios()
    pass_file <- Sys.getenv("MAIL_PASS_FILE")
    if (!length(para)) { loguear("SIN MAIL: no hay destinatarios en", Sys.getenv("MAIL_TO_FILE")); return(invisible(FALSE)) }
    if (!file.exists(pass_file)) { loguear("SIN MAIL: no existe", pass_file); return(invisible(FALSE)) }
    pass <- trimws(readLines(pass_file, warn= FALSE)[1])
    titulo <- sprintf("[WF%d grupo %s] %s", PARAM$experimento, GRUPO, titulo)

    archivo <- tempfile(fileext= ".txt")
    writeLines(c(
      paste0("From: ", PARAM$mail$desde),
      paste0("To: ", paste(para, collapse= ", ")),
      paste0("Subject: ", titulo),
      "Content-Type: text/plain; charset=UTF-8",
      "",
      cuerpo), archivo)

    rc <- system2("curl", c("-s", "--ssl-reqd",
      "--url", "smtps://smtp.gmail.com:465",
      "--mail-from", PARAM$mail$desde,
      as.vector(rbind("--mail-rcpt", para)),
      "--user", shQuote(paste0(PARAM$mail$desde, ":", pass)),
      "-T", archivo), stdout= FALSE, stderr= FALSE)
    unlink(archivo)
    if (rc == 0) loguear("mail enviado:", titulo) else loguear("FALLO el mail (curl rc =", rc, "):", titulo)
    invisible(rc == 0)
  }, error= function(e) { loguear("FALLO el mail:", conditionMessage(e)); invisible(FALSE) })
}

# ---------------------------------------------------------------------------
# ETAPAS: cada una avisa por mail al terminar; un error avisa en que etapa fue
# ---------------------------------------------------------------------------
ETAPA <- "inicio"
T_ETAPA <- Sys.time()
T_INICIO <- Sys.time()
# duracion de cada etapa en esta sesion, para el registro final
TIEMPOS <- data.table(etapa= character(), minutos= numeric())
WF_VERSION <- Sys.getenv("WF_VERSION", "sin version (no se lanzo con vm/lanzar.sh)")

etapa <- function(nombre) {
  ETAPA <<- nombre
  T_ETAPA <<- Sys.time()
  loguear("=== inicio etapa", nombre)
}

fin_etapa <- function(detalle= "") {
  mins <- as.numeric(difftime(Sys.time(), T_ETAPA, units= "mins"))
  loguear("=== fin etapa", ETAPA, sprintf("(%.1f min)", mins))
  TIEMPOS <<- rbind(TIEMPOS, data.table(etapa= ETAPA, minutos= round(mins, 1)))
  total_h <- as.numeric(difftime(Sys.time(), T_INICIO, units= "hours"))
  mandar_mail(sprintf("termino %s (%.1f min)", ETAPA, mins),
    paste0("Etapa ", ETAPA, " terminada en ", sprintf("%.1f", mins), " min.\n",
           if (exists("dataset")) paste0("dataset: ", nrow(dataset), " filas x ", ncol(dataset), " columnas\n") else "",
           detalle, "\n\n",
           "Tiempos de esta sesion (", sprintf("%.1f", total_h), " h en total):\n",
           paste(sprintf("  %-28s %8.1f min", TIEMPOS$etapa, TIEMPOS$minutos), collapse= "\n")))
}

options(error= function() {
  msg <- geterrmessage()
  loguear("ERROR en la etapa", ETAPA, ":", msg)
  mandar_mail(paste("ERROR en", ETAPA),
    paste0("La corrida se detuvo en la etapa ", ETAPA, ".\n\n", msg,
           "\nRelanzar el mismo comando retoma desde el ultimo checkpoint."))
  quit(save= "no", status= 1)
})

# graba con nombre temporal y renombra: un corte a mitad no deja un archivo roto
grabar_checkpoint <- function(archivo) {
  tmp <- paste0(archivo, ".tmp")
  write_fst(dataset, tmp, compress= 50)
  file.rename(tmp, archivo)
  loguear("checkpoint grabado:", archivo)
}

leer_checkpoint <- function(archivo) {
  loguear("retomo desde checkpoint:", archivo)
  read_fst(archivo, as.data.table= TRUE)
}

# ===========================================================================
# FE GENETICO
#   genetica_log.txt     una fila por formula evaluada (es tambien el cache:
#                        al retomar, gramEvol repite la misma secuencia con la
#                        misma semilla y lo ya medido no se vuelve a entrenar)
#   genetica_rondas.txt  una fila por ronda terminada: la mejor formula y si quedo
# ===========================================================================
if (!require("gramEvol")) install.packages("gramEvol")
require("gramEvol")
if (!require("lightgbm")) install.packages("lightgbm")
require("lightgbm")

ARCH_GA_LOG <- "genetica_log.txt"
ARCH_GA_RONDAS <- "genetica_rondas.txt"
GA_PENALIDAD <- -1e12      # mejora de una formula que no se puede evaluar o es constante

ga_rondas <- function() {
  if (file.exists(ARCH_GA_RONDAS)) fread(ARCH_GA_RONDAS, sep= "\t") else
    data.table(ronda= integer(), nombre= character(), formula= character(),
               mejora= numeric(), umbral= numeric(), aceptada= logical(), evaluaciones= integer())
}
ga_ganadoras <- function() { r <- ga_rondas(); r[aceptada == TRUE] }

texto_ganadoras <- function() {
  r <- ga_rondas()
  if (!nrow(r)) return("Sin rondas geneticas.")
  paste0("Rondas geneticas:\n",
    paste(sprintf("  ronda %d: %s = %s\n    mejora %s (umbral %s) -> %s",
      r$ronda, r$nombre, r$formula,
      formatC(r$mejora, format= "d", big.mark= "."), formatC(r$umbral, format= "d", big.mark= "."),
      ifelse(r$aceptada, "QUEDA", "descartada: no supera el ruido")), collapse= "\n"))
}

# evalua una formula sobre una tabla: Inf -> NA y NaN -> 0, como la valvula del FE intra-mes
ga_evaluar_formula <- function(formula, tabla) {
  v <- tryCatch(eval(parse(text= formula)[[1]], envir= tabla), error= function(e) NULL)
  if (is.null(v) || length(v) != nrow(tabla)) return(NULL)
  v <- as.numeric(v)
  v[is.infinite(v)] <- NA
  v[is.nan(v)] <- 0
  if (length(unique(v[!is.na(v)])) < 2) return(NULL)   # constante: no aporta
  v
}

# ganancia en meseta (como fganancia_lgbm_meseta de canaritos): promedio de las
# 500 mejores ganancias acumuladas
ga_ganancia_meseta <- function(prob) {
  gan_acum <- cumsum(GA$gan_valid[order(-prob)])
  mean(sort(gan_acum, decreasing= TRUE)[1:min(500, length(gan_acum))])
}

ga_entrenar <- function(X, semilla) {
  dtr <- lgb.Dataset(X[!GA$es_valid, , drop= FALSE], label= GA$label[!GA$es_valid], free_raw_data= TRUE)
  p <- PARAM$GA$lgb_param
  p$seed <- semilla
  m <- lgb.train(data= dtr, params= p, verbose= -100)
  ga_ganancia_meseta(predict(m, X[GA$es_valid, , drop= FALSE]))
}

# filas de referencia del log (no son formulas): la base de cada ronda y el ruido
es_referencia <- function(formula) formula == "BASE" | startsWith(formula, "RUIDO_")

ga_registrar <- function(ronda, formula, ganancia, mejora, segundos) {
  fwrite(data.table(ronda= ronda, formula= formula, ganancia= ganancia, mejora= mejora,
    segundos= round(segundos, 1), fecha= format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
    ARCH_GA_LOG, sep= "\t", append= file.exists(ARCH_GA_LOG))
  # el cache guarda la mejora de las formulas y la ganancia de las referencias
  GA$cache[[paste(ronda, formula)]] <- if (es_referencia(formula)) ganancia else mejora
}

# horas de entrenamiento ya gastadas en la genetica, sumando todas las sesiones
ga_horas_usadas <- function() {
  if (!file.exists(ARCH_GA_LOG)) return(0)
  sum(fread(ARCH_GA_LOG, sep= "\t")$segundos, na.rm= TRUE) / 3600
}

# la funcion de costo de gramEvol (minimiza): -(mejora en ganancia)
ga_costo <- function(expr) {
  formula <- as.character(expr)
  clave <- paste(GA$ronda, formula)
  if (!is.null(GA$cache[[clave]])) return(-GA$cache[[clave]])
  if (GA$horas + GA$horas_sesion() >= PARAM$GA$horas_max)
    stop(structure(class= c("ga_tope", "error", "condition"),
      list(message= "tope de horas de la genetica", call= NULL)))

  # el entrenamiento no puede mover el RNG de R: si lo moviera, al retomar con
  # el cache gramEvol seguiria otro camino
  rng <- get(".Random.seed", envir= globalenv())
  t0 <- Sys.time()
  v <- ga_evaluar_formula(formula, GA$datos)
  if (is.null(v)) {
    ganancia <- NA_real_
    mejora <- GA_PENALIDAD
  } else {
    ganancia <- ga_entrenar(cbind(GA$X, gen= v), PARAM$semilla_primigenia)
    mejora <- ganancia - GA$base
  }
  assign(".Random.seed", rng, envir= globalenv())
  ga_registrar(GA$ronda, formula, ganancia, mejora, as.numeric(difftime(Sys.time(), t0, units= "secs")))
  -mejora
}

ga_monitor <- function(resultado) {
  gen <- tryCatch(resultado$population$currentIteration, error= function(e) NA)
  loguear("genetica ronda", GA$ronda, "generacion", gen,
          "mejor mejora", formatC(-min(resultado$best$cost), format= "d", big.mark= "."))
  if (is.na(gen) || PARAM$GA$mail_cada_gen <= 0 || gen %% PARAM$GA$mail_cada_gen != 0) return(invisible())
  log_ga <- fread(ARCH_GA_LOG, sep= "\t")[ronda == GA$ronda & !es_referencia(formula)]
  top <- head(log_ga[order(-mejora)], 10)
  mandar_mail(sprintf("genetica ronda %d, generacion %d", GA$ronda, gen),
    paste0("Formulas evaluadas en la ronda: ", nrow(log_ga),
           sprintf(" (%.0f s promedio cada una)", mean(log_ga$segundos[log_ga$segundos > 0])), "\n",
           sprintf("Horas usadas: %.1f de %g\n", GA$horas + GA$horas_sesion(), PARAM$GA$horas_max),
           "Ganancia base de la ronda: ", formatC(GA$base, format= "d", big.mark= "."),
           ", umbral para quedar: ", formatC(GA$umbral, format= "d", big.mark= "."), "\n\n",
           "Las 10 mejores hasta ahora:\n",
           paste(sprintf("  %s  %s", formatC(top$mejora, format= "d", big.mark= ".", width= 14), top$formula),
                 collapse= "\n")))
}

# valor de una formula ya medida o por medir sin gramEvol (base y ruido)
ga_medir <- function(clave, expr_fn) {
  if (!is.null(GA$cache[[clave]])) return(GA$cache[[clave]])
  t0 <- Sys.time()
  g <- expr_fn()
  ga_registrar(as.integer(sub(" .*", "", clave)), sub("^[^ ]+ ", "", clave), g, NA_real_,
               as.numeric(difftime(Sys.time(), t0, units= "secs")))
  g
}

GA <- new.env()

correr_genetica <- function() {
  GA$cache <- list()
  if (file.exists(ARCH_GA_LOG)) {
    l <- fread(ARCH_GA_LOG, sep= "\t")
    for (i in seq_len(nrow(l))) GA$cache[[paste(l$ronda[i], l$formula[i])]] <-
      if (es_referencia(l$formula[i])) l$ganancia[i] else l$mejora[i]
    loguear("genetica: ya hay", nrow(l), "formulas medidas")
  }

  # muestra para el fitness: meses de entrenamiento con undersampling + validacion completa
  set.seed(PARAM$semilla_primigenia, kind = "L'Ecuyer-CMRG")
  azar <- runif(nrow(dataset))
  positivos <- c("BAJA+1", "BAJA+2")
  filas <- (dataset$foto_mes %in% PARAM$GA$entrena &
             (dataset$clase_ternaria %in% positivos | azar < PARAM$GA$undersampling)) |
           dataset$foto_mes %in% PARAM$GA$valida
  GA$datos <- dataset[filas]
  GA$es_valid <- GA$datos$foto_mes %in% PARAM$GA$valida
  GA$label <- as.integer(GA$datos$clase_ternaria %in% positivos)
  GA$gan_valid <- ifelse(GA$datos$clase_ternaria[GA$es_valid] == "BAJA+2",
                         PARAM$ganancia$acierto, PARAM$ganancia$error)
  numericas <- names(GA$datos)[sapply(GA$datos, is.numeric)]
  campos_modelo <- setdiff(numericas, "numero_de_cliente")
  vars <- setdiff(numericas, c("numero_de_cliente", "foto_mes"))
  GA$X <- data.matrix(GA$datos[, campos_modelo, with= FALSE])
  loguear("genetica: muestra de", nrow(GA$datos), "filas,", length(vars), "campos para combinar")

  gramatica <- CreateGrammar(list(
    expr = gsrule("<var><op><var>", "(<var><op><var>)<op><var>"),
    op   = gsrule(" + ", " - ", " * ", " / "),
    var  = do.call(gsrule, as.list(vars))
  ))

  # ruido: la misma base con distintas semillas
  ganancias_ruido <- sapply(PARAM$GA$semillas_ruido, function(s)
    ga_medir(paste0("0 RUIDO_semilla_", s), function() ga_entrenar(GA$X, s)))
  ruido <- sd(ganancias_ruido)
  GA$umbral <- PARAM$GA$desvios * ruido
  PARAM$GA$ruido <<- ruido
  loguear("genetica: ruido entre semillas", round(ruido), "-> umbral", round(GA$umbral))

  GA$horas <- ga_horas_usadas()
  t_sesion <- Sys.time()
  GA$horas_sesion <- function() as.numeric(difftime(Sys.time(), t_sesion, units= "hours"))
  loguear("genetica: horas ya usadas", round(GA$horas, 1), "de", PARAM$GA$horas_max)

  hechas <- ga_rondas()
  for (r in seq_len(PARAM$GA$rondas)) {
    GA$ronda <- r
    GA$base <- ga_medir(paste0(r, " BASE"), function() ga_entrenar(GA$X, PARAM$semilla_primigenia))

    if (r %in% hechas$ronda) {
      fila <- hechas[ronda == r]
      loguear("genetica: ronda", r, "ya hecha:", fila$formula, if (fila$aceptada) "(queda)" else "(descartada)")
    } else {
      set.seed(PARAM$semilla_primigenia + r, kind = "L'Ecuyer-CMRG")
      corto <- FALSE
      ge <- tryCatch(
        GrammaticalEvolution(gramatica, ga_costo,
          optimizer= "ga", popSize= PARAM$GA$poblacion, iterations= PARAM$GA$generaciones,
          monitorFunc= ga_monitor, disable.warnings= TRUE),
        ga_tope= function(e) { corto <<- TRUE; NULL })
      if (corto) {
        # se llego al tope: la mejor formula medida en la ronda
        l <- fread(ARCH_GA_LOG, sep= "\t")[ronda == r & !es_referencia(formula)]
        if (!nrow(l)) { loguear("genetica: tope de horas antes de medir formulas en la ronda", r); break }
        mejor <- l[which.max(mejora), formula]
        mejora <- max(l$mejora)
        loguear("genetica: tope de", PARAM$GA$horas_max, "h alcanzado en la ronda", r)
      } else {
        mejor <- as.character(ge$best$expressions)
        mejora <- -ge$best$cost
      }
      fila <- data.table(ronda= r, nombre= sprintf("gen_%02d", r), formula= mejor,
        mejora= mejora, umbral= GA$umbral, aceptada= mejora > GA$umbral,
        evaluaciones= nrow(fread(ARCH_GA_LOG, sep= "\t")[ronda == r & !es_referencia(formula)]))
      fwrite(fila, ARCH_GA_RONDAS, sep= "\t", append= file.exists(ARCH_GA_RONDAS))
      mandar_mail(sprintf("genetica ronda %d terminada%s", r, if (corto) " (tope de horas)" else ""),
                  texto_ganadoras())
    }

    if (fila$aceptada) {
      v <- ga_evaluar_formula(fila$formula, GA$datos)
      GA$X <- cbind(GA$X, v)
      colnames(GA$X)[ncol(GA$X)] <- fila$nombre
    } else {
      loguear("genetica: la ronda", r, "no supero el ruido, corto"); break
    }
    if (ga_horas_usadas() >= PARAM$GA$horas_max) {
      loguear("genetica: tope de horas, no se abren mas rondas"); break
    }
  }

  # las ganadoras entran al dataset completo
  for (i in seq_len(nrow(ga_ganadoras()))) {
    g <- ga_ganadoras()[i]
    v <- ga_evaluar_formula(g$formula, dataset)
    if (is.null(v)) stop("la formula genetica ", g$formula, " no se puede evaluar en el dataset completo")
    set(dataset, j= g$nombre, value= v)
    loguear("genetica: agregada", g$nombre, "=", g$formula)
  }
  PARAM$GA$ganadoras <<- ga_ganadoras()
  rm(list= c("datos", "X"), envir= GA)
  gc(verbose= FALSE)
}

# GRUPO A: Kaggle se prepara y se prueba al arrancar. Si no anda, avisa por
# mail ahora; la corrida sigue y los archivos para subir quedan en ./kaggle
KAGGLE_OK <- FALSE
preparar_kaggle <- function(avisar) {
  dir.create("~/.kaggle", showWarnings= FALSE)
  if (!file.exists("~/.kaggle/kaggle.json") && file.exists(Sys.getenv("KAGGLE_JSON"))) {
    file.copy(Sys.getenv("KAGGLE_JSON"), "~/.kaggle/kaggle.json")
    Sys.chmod("~/.kaggle/kaggle.json", "600")
  }
  kaggle_bin <<- Sys.getenv("KAGGLE_BIN", "kaggle")
  probar_kaggle <- function() {
    out <- suppressWarnings(tryCatch(system2(kaggle_bin, "--version", stdout= TRUE, stderr= TRUE),
      error= function(e) structure("no se pudo ejecutar", status= 127L)))
    is.null(attr(out, "status"))
  }
  if (!probar_kaggle()) {
    loguear("kaggle no responde: instalo el CLI con pip")
    system2("python3", c("-m", "pip", "install", "--user", "--quiet", "kaggle"))
    if (kaggle_bin == "kaggle") kaggle_bin <<- path.expand("~/.local/bin/kaggle")
  }
  KAGGLE_OK <<- file.exists("~/.kaggle/kaggle.json") && probar_kaggle()
  if (!KAGGLE_OK && avisar) mandar_mail("AVISO: Kaggle no funciona",
    paste0("No hay ~/.kaggle/kaggle.json (KAGGLE_JSON=", Sys.getenv("KAGGLE_JSON"),
           ") o el CLI no responde. La corrida sigue; al final los archivos quedan en ",
           carpeta_exp, "/kaggle y no se suben."))
}
if (GRUPO == "A") preparar_kaggle(avisar= TRUE)

CK_HIST <- "checkpoints/dataset_fe_historico.fst"
CK_CANARITOS <- "checkpoints/dataset_canaritos.fst"

mandar_mail("arranco",
  paste0("Experimento ", PARAM$experimento, ", grupo ", GRUPO, "\n",
         "Version del script: ", WF_VERSION, "\n",
         "Carpeta: ", carpeta_exp, "\n",
         "Semillas: ", paste(PARAM$FT$semillas, collapse= ", "), "\n",
         "Checkpoints existentes: ",
         paste(c(if (file.exists(CK_HIST)) "FE historico", if (file.exists(CK_CANARITOS)) "canaritos",
                 if (file.exists("HT.RDATA")) "BO (HT.RDATA)", if (file.exists("BO_log.txt")) "BO terminada"),
               collapse= ", ")))

# ===========================================================================
# 9.7.1 PREPROCESAMIENTO DEL DATASET
# ===========================================================================

if (!file.exists(CK_CANARITOS)) {

  if (!file.exists(CK_HIST)) {

    etapa("lectura del dataset")
    dataset <- fread(Sys.getenv("DATASET_PATH"))
    fin_etapa()

    etapa("CA catastrophe analysis")
# --- z635 celda 19 ---
if( !require("mice")) install.packages("mice", repos = "http://cran.us.r-project.org")
require("mice")

# --- z635 celda 20 ---
# Escrito por alumnos de  Universidad Austral  Rosario

Corregir_MICE <- function(pcampo, pmeses) {

  meth <- rep("", ncol(dataset))
  names(meth) <- colnames(dataset)
  meth[names(meth) == pcampo] <- "sample"

  # llamada a mice  !
  imputacion <- mice(dataset,
    method = meth,
    maxit = 5,
    m = 1,
    seed = 7)

  tbl <- mice::complete(dataset)

  dataset[, paste0(pcampo) := ifelse(foto_mes %in% pmeses, tbl[, get(pcampo)], get(pcampo))]

}

# --- z635 celda 21 ---
Corregir_interpolar <- function(pcampo, pmeses) {

  tbl <- dataset[, list(
    "v1" = shift(get(pcampo), 1, type = "lag"),
    "v2" = shift(get(pcampo), 1, type = "lead")
  ),
  by = eval(PARAM$dataset_metadata$entity_id)
  ]

  tbl[, paste0(PARAM$dataset_metadata$entity_id) := NULL]
  tbl[, promedio := rowMeans(tbl, na.rm = TRUE)]

  dataset[
    ,
    paste0(pcampo) := ifelse(!(foto_mes %in% pmeses),
      get(pcampo),
      tbl$promedio
    )
  ]
}

# --- z635 celda 22 ---
AsignarNA_campomeses <- function(pcampo, pmeses) {

  if( pcampo %in% colnames( dataset ) ) {

    dataset[ foto_mes %in% pmeses, paste0(pcampo) := NA ]
  }
}

# --- z635 celda 23 ---

Corregir_atributo <- function(pcampo, pmeses, pmetodo)
{
  # si el campo no existe en el dataset, Afuera !
  if( !(pcampo %in% colnames( dataset )) )
    return( 1 )

  # llamo a la funcion especializada que corresponde
  switch( pmetodo,
    "MachineLearning"     = AsignarNA_campomeses(pcampo, pmeses),
    "EstadisticaClasica"  = Corregir_interpolar(pcampo, pmeses),
    "MICE"                = Corregir_MICE(pcampo, pmeses),
  )

  return( 0 )
}

# --- z635 celda 24 ---

Corregir_Rotas <- function(dataset, pmetodo) {
  gc(verbose= FALSE)
  cat( "inicio Corregir_Rotas()\n")
  # acomodo los errores del dataset

  Corregir_atributo("active_quarter", c(202006), pmetodo) # 1
  Corregir_atributo("internet", c(202006), pmetodo) # 2

  Corregir_atributo("mrentabilidad", c(201905, 201910, 202006), pmetodo) # 3
  Corregir_atributo("mrentabilidad_annual", c(201905, 201910, 202006), pmetodo) # 4

  Corregir_atributo("mcomisiones", c(201905, 201910, 202006), pmetodo) # 5

  Corregir_atributo("mactivos_margen", c(201905, 201910, 202006), pmetodo) # 6
  Corregir_atributo("mpasivos_margen", c(201905, 201910, 202006), pmetodo) # 7

  Corregir_atributo("mcuentas_saldo", c(202006), pmetodo) # 8

  Corregir_atributo("ctarjeta_debito_transacciones", c(202006), pmetodo) # 9

  Corregir_atributo("mautoservicio", c(202006), pmetodo) # 10

  Corregir_atributo("ctarjeta_visa_transacciones", c(202006), pmetodo) # 11
  Corregir_atributo("mtarjeta_visa_consumo", c(202006), pmetodo) # 12

  Corregir_atributo("ctarjeta_master_transacciones", c(202006), pmetodo) # 13
  Corregir_atributo("mtarjeta_master_consumo", c(202006), pmetodo) # 14

  Corregir_atributo("ctarjeta_visa_debitos_automaticos", c(201904), pmetodo) # 15
  Corregir_atributo("mttarjeta_visa_debitos_automaticos", c(201904), pmetodo) # 16

  Corregir_atributo("ccajeros_propios_descuentos",
    c(201910, 202002, 202006, 202009, 202010, 202102), pmetodo) # 17

  Corregir_atributo("mcajeros_propios_descuentos",
    c(201910, 202002, 202006, 202009, 202010, 202102), pmetodo) # 18

  Corregir_atributo("ctarjeta_visa_descuentos",
    c(201910, 202002, 202006, 202009, 202010, 202102), pmetodo) # 19

  Corregir_atributo("mtarjeta_visa_descuentos",
    c(201910, 202002, 202006, 202009, 202010, 202102), pmetodo) # 20

  Corregir_atributo("ctarjeta_master_descuentos",
    c(201910, 202002, 202006, 202009, 202010, 202102), pmetodo) # 21

  Corregir_atributo("mtarjeta_master_descuentos",
    c(201910, 202002, 202006, 202009, 202010, 202102), pmetodo) # 22

  Corregir_atributo("ccomisiones_otras", c(201905, 201910, 202006), pmetodo) # 23
  Corregir_atributo("mcomisiones_otras", c(201905, 201910, 202006), pmetodo) # 24

  Corregir_atributo("cextraccion_autoservicio", c(202006), pmetodo) # 25
  Corregir_atributo("mextraccion_autoservicio", c(202006), pmetodo) # 26

  Corregir_atributo("ccheques_depositados", c(202006), pmetodo) # 27
  Corregir_atributo("mcheques_depositados", c(202006), pmetodo) # 28
  Corregir_atributo("ccheques_emitidos", c(202006), pmetodo) # 29
  Corregir_atributo("mcheques_emitidos", c(202006), pmetodo) # 30
  Corregir_atributo("ccheques_depositados_rechazados", c(202006), pmetodo) # 31
  Corregir_atributo("mcheques_depositados_rechazados", c(202006), pmetodo) # 32
  Corregir_atributo("ccheques_emitidos_rechazados", c(202006), pmetodo) # 33
  Corregir_atributo("mcheques_emitidos_rechazados", c(202006), pmetodo) # 34

  Corregir_atributo("tcallcenter", c(202006), pmetodo) # 35
  Corregir_atributo("ccallcenter_transacciones", c(202006), pmetodo) # 36

  Corregir_atributo("thomebanking", c(202006), pmetodo) # 37
  Corregir_atributo("chomebanking_transacciones", c(201910, 202006), pmetodo) # 38

  Corregir_atributo("ccajas_transacciones", c(202006), pmetodo) # 39
  Corregir_atributo("ccajas_consultas", c(202006), pmetodo) # 40

  Corregir_atributo("ccajas_depositos", c(202006, 202105), pmetodo) # 41

  Corregir_atributo("ccajas_extracciones", c(202006), pmetodo) # 41
  Corregir_atributo("ccajas_otras", c(202006), pmetodo) # 43

  Corregir_atributo("catm_trx", c(202006), pmetodo) # 44
  Corregir_atributo("matm", c(202006), pmetodo) # 45
  Corregir_atributo("catm_trx_other", c(202006), pmetodo) # 46
  Corregir_atributo("matm_other", c(202006), pmetodo) # 47

  cat( "fin Corregir_rotas()\n")
}

# --- z635 celda 25 ---
# resuelvo el Catastrophe Analysis

setorder( dataset, numero_de_cliente, foto_mes )

PARAM$CA$metodo= "MachineLearning"

if( PARAM$CA$metodo %in% c("MachineLearning", "EstadisticaClasica", "MICE") )
  Corregir_Rotas(dataset, PARAM$CA$metodo)

    fin_etapa()

    etapa("DR data drifting")
# --- z635 celda 27 ---
# meses que me interesan para el ajuste de variables monetarias
vfoto_mes <- c(
  201901, 201902, 201903, 201904, 201905, 201906,
  201907, 201908, 201909, 201910, 201911, 201912,
  202001, 202002, 202003, 202004, 202005, 202006,
  202007, 202008, 202009, 202010, 202011, 202012,
  202101, 202102, 202103, 202104, 202105, 202106,
  202107, 202108, 202109
)

# --- z635 celda 28 ---
# los valores que siguen fueron calculados por alumnos

# momento 1.0  31-dic-2020 a las 23:59
vIPC <- c(
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

vdolar_blue <- c(
   39.045455,  38.402500,  41.639474,
   44.274737,  46.095455,  45.063333,
   43.983333,  54.842857,  61.059524,
   65.545455,  66.750000,  72.368421,
   77.477273,  78.191667,  82.434211,
  101.087500, 126.236842, 125.857143,
  130.782609, 133.400000, 137.954545,
  170.619048, 160.400000, 153.052632,
  157.900000, 149.780952, 143.615385,
  146.250000, 153.550000, 162.000000,
  178.478261, 180.878788, 184.357143
)

vdolar_oficial <- c(
   38.430000,  39.428000,  42.542105,
   44.354211,  46.088636,  44.955000,
   43.751429,  54.650476,  58.790000,
   61.403182,  63.012632,  63.011579,
   62.983636,  63.580556,  65.200000,
   67.872000,  70.047895,  72.520952,
   75.324286,  77.488500,  79.430909,
   83.134762,  85.484737,  88.181667,
   91.474000,  93.997778,  96.635909,
   98.526000,  99.613158, 100.619048,
  101.619048, 102.569048, 103.781818
)

vUVA <- c(
  2.001408838932958,  1.950325472789153,  1.89323032351521,
  1.8247220405493787, 1.746027787673673,  1.6871348409529485,
  1.6361678865622313, 1.5927529755859773, 1.5549162794128493,
  1.4949100586391746, 1.4197729500774545, 1.3678188186372326,
  1.3136508617223726, 1.2690535173062818, 1.2381595983200178,
  1.211656735577568,  1.1770808941405335, 1.1570338657445522,
  1.1388769475653255, 1.1156993751209352, 1.093638313080772,
  1.0657171590878205, 1.0362173587708712, 1.0,
  0.9669867858358365, 0.9323750098728378, 0.8958202912590305,
  0.8631993702994263, 0.8253893405524657, 0.7928918905364516,
  0.7666323845128089, 0.7428976357662823, 0.721615762047849
)

# --- z635 celda 29 ---
tb_indices <- as.data.table( list(
  "IPC" = vIPC,
  "dolar_blue" = vdolar_blue,
  "dolar_oficial" = vdolar_oficial,
  "UVA" = vUVA
  )
)

tb_indices[[ 'foto_mes' ]] <- vfoto_mes

tb_indices

# --- z635 celda 30 ---
drift_UVA <- function(campos_monetarios) {
  cat( "inicio drift_UVA()\n")

  dataset[tb_indices,
    on = c("foto_mes"),
    (campos_monetarios) := .SD * i.UVA,
    .SDcols = campos_monetarios
  ]

  cat( "fin drift_UVA()\n")
}

# --- z635 celda 31 ---
drift_dolar_oficial <- function(campos_monetarios) {
  cat( "inicio drift_dolar_oficial()\n")

  dataset[tb_indices,
    on = c("foto_mes"),
    (campos_monetarios) := .SD / i.dolar_oficial,
    .SDcols = campos_monetarios
  ]

  cat( "fin drift_dolar_oficial()\n")
}

# --- z635 celda 32 ---
drift_dolar_blue <- function(campos_monetarios) {
  cat( "inicio drift_dolar_blue()\n")

  dataset[tb_indices,
    on = c("foto_mes"),
    (campos_monetarios) := .SD / i.dolar_blue,
    .SDcols = campos_monetarios
  ]

  cat( "fin drift_dolar_blue()\n")
}

# --- z635 celda 33 ---
drift_deflacion <- function(campos_monetarios) {
  cat( "inicio drift_deflacion()\n")

  dataset[tb_indices,
    on = c("foto_mes"),
    (campos_monetarios) := .SD * i.IPC,
    .SDcols = campos_monetarios
  ]

  cat( "fin drift_deflacion()\n")
}

# --- z635 celda 34 ---
drift_rank_simple <- function(campos_drift) {

  cat( "inicio drift_rank_simple()\n")
  for (campo in campos_drift)
  {
    cat(campo, " ")
    dataset[, paste0(campo, "_rank") :=
      (frank(get(campo), ties.method = "random") - 1) / (.N - 1), by = list(foto_mes)]
    dataset[, (campo) := NULL]
  }
  cat( "fin drift_rank_simple()\n")
}

# --- z635 celda 35 ---
# El cero se transforma en cero
# los positivos se rankean por su lado
# los negativos se rankean por su lado

drift_rank_cero_fijo <- function(campos_drift) {

  cat( "inicio drift_rank_cero_fijo()\n")
  for (campo in campos_drift)
  {
    cat(campo, " ")
    dataset[get(campo) == 0, paste0(campo, "_rank") := 0]
    dataset[get(campo) > 0, paste0(campo, "_rank") :=
      frank(get(campo), ties.method = "random") / .N, by = list(foto_mes)]

    dataset[get(campo) < 0, paste0(campo, "_rank") :=
      -frank(-get(campo), ties.method = "random") / .N, by = list(foto_mes)]
    dataset[, (campo) := NULL]
  }
  cat("\n")
  cat( "fin drift_rank_cero_fijo()\n")
}

# --- z635 celda 36 ---
# funcion provista por alumnos amantes de la Estadistica Clasica

drift_estandarizar <- function(campos_drift) {

  cat( "inicio drift_estandarizar()\n")
  for (campo in campos_drift)
  {
    cat(campo, " ")
    dataset[, paste0(campo, "_normal") :=
      (get(campo) -mean(get(campo), na.rm=TRUE)) / sd(get(campo), na.rm=TRUE),
      by = list(foto_mes)]

    dataset[, (campo) := NULL]
  }
  cat( "fin drift_estandarizar()\n")
}

# --- z635 celda 37 ---
# por como armé los nombres de campos,
#  estos son los campos que expresan variables monetarias
campos_monetarios <- colnames(dataset)
campos_monetarios <- campos_monetarios[campos_monetarios %like%
  "^(m|Visa_m|Master_m|vm_m)"]

campos_monetarios

# --- z635 celda 38 ---
# ejecuto el Data Drifting
setorder( dataset, numero_de_cliente, foto_mes )


PARAM$DR$metodo <- "deflacion"

switch(PARAM$DR$metodo,
  "ninguno"        = cat("No hay correccion del data drifting"),
  "rank_simple"    = drift_rank_simple(campos_monetarios),
  "rank_cero_fijo" = drift_rank_cero_fijo(campos_monetarios),
  "deflacion"      = drift_deflacion(campos_monetarios),
  "dolar_blue"     = drift_dolarblue(campos_monetarios),
  "dolar_oficial"  = drift_dolaroficial(campos_monetarios),
  "UVA"            = drift_UVA(campos_monetarios),
  "estandarizar"   = drift_estandarizar(campos_monetarios)
)

    fin_etapa()

    etapa("FE intra-mes")
# --- z635 celda 41 ---
if( !require("lubridate")) install.packages("lubridate", repos = "http://cran.us.r-project.org")
require("lubridate")

# --- z635 celda 42 ---
# esta funcion atributos presentes existe debido a que las modalidades poseen datasets con distinta cantidad de campos
atributos_presentes <- function( patributos )
{
  atributos <- unique( patributos )
  comun <- intersect( atributos, colnames(dataset) )

  return(  length( atributos ) == length( comun ) )
}

# --- z635 celda 43 ---
# Esta es la parte que los alumnos deben desplegar todo su ingenio
# Agregar aqui sus PROPIAS VARIABLES manuales

AgregarVariables_IntraMes <- function(dataset) {
  cat( "inicio AgregarVariables_IntraMes()\n")
  gc(verbose= FALSE)
  # INICIO de la seccion donde se deben hacer cambios con variables nuevas

  # el mes 1,2, ..12
  if( atributos_presentes( c("foto_mes") ))
    dataset[, kmes := foto_mes %% 100]

  # creo un ctr_quarter que tenga en cuenta cuando
  # los clientes hace 3 menos meses que estan
  # ya que seria injusto considerar las transacciones medidas en menor tiempo
  if( atributos_presentes( c("ctrx_quarter") ))
    dataset[, ctrx_quarter_normalizado := as.numeric(ctrx_quarter) ]

  if( atributos_presentes( c("ctrx_quarter", "cliente_antiguedad") ))
    dataset[cliente_antiguedad == 1, ctrx_quarter_normalizado := ctrx_quarter * 5]

  if( atributos_presentes( c("ctrx_quarter", "cliente_antiguedad") ))
    dataset[cliente_antiguedad == 2, ctrx_quarter_normalizado := ctrx_quarter * 2]

  if( atributos_presentes( c("ctrx_quarter", "cliente_antiguedad") ))
    dataset[
      cliente_antiguedad == 3,
      ctrx_quarter_normalizado := ctrx_quarter * 1.2
    ]

   if(atributos_presentes(c("foto_mes")))
    dataset[,foto_mes_formato_fecha := as.Date(paste(substr(dataset$foto_mes,1,4),substr(dataset$foto_mes,5,6),"01",sep='-'))]

  #dataset$foto_mes_formato_fecha <<- as.Date(paste(substr(dataset$foto_mes,1,4),substr(dataset$foto_mes,5,6),"01",sep='-'))

  if(atributos_presentes(c("cantidad_total_transacciones"))){
   auxiliarmenos1 <- dataset[,list(numero_de_cliente,foto_mes_formato_fecha, cantidad_total_transacciones)]
   auxiliarmenos2 <- dataset[,list(numero_de_cliente,foto_mes_formato_fecha,cantidad_total_transacciones)]
   # auxiliarmenos1$foto_mes_formato_fecha <- as.Date(auxiliarmenos1$foto_mes_formato_fecha)
   # auxiliarmenos2$foto_mes_formato_fecha <- as.Date(auxiliarmenos2$foto_mes_formato_fecha)
   auxiliarmenos1$foto_mes_formato_fecha <- auxiliarmenos1$foto_mes_formato_fecha  %m-%  months(1)
   auxiliarmenos2$foto_mes_formato_fecha <- auxiliarmenos2$foto_mes_formato_fecha %m-% months(2)
   auxiliarmenos1$codigo <- paste(auxiliarmenos1$numero_de_cliente,auxiliarmenos1$foto_mes_formato_fecha,sep='-')
   auxiliarmenos2$codigo <- paste(auxiliarmenos2$numero_de_cliente,auxiliarmenos2$foto_mes_formato_fecha,sep='-')

   dataset[, codigo := paste(numero_de_cliente, foto_mes_formato_fecha, sep='-') ]

   dataset[ auxiliarmenos1,
            on = "codigo",
            transaccionesmenos1 := i.cantidad_total_transacciones ]

   dataset[ auxiliarmenos2,
            on = "codigo",
            transaccionesmenos2 := i.cantidad_total_transacciones ]

   dataset[, cantidad_total_transacciones_quarter := rowSums(cbind(cantidad_total_transacciones +
    transaccionesmenos1 + transaccionesmenos2),na.rm=T) ]

   dataset[, codigo := NULL ]
   dataset[, transaccionesmenos1 := NULL ]
   dataset[, transaccionesmenos2 := NULL ]
   dataset[, foto_mes_formato_fecha := NULL ]
   rm(auxiliarmenos1)
   rm(auxiliarmenos2)
  }

  if( atributos_presentes( c("cantidad_total_transacciones_quarter") ))
    dataset[, cantidad_total_transacciones_quarter_normalizado := cantidad_total_transacciones_quarter]

  if( atributos_presentes( c("cantidad_total_transacciones_quarter", "cliente_antiguedad") ))
    dataset[cliente_antiguedad == 1, cantidad_total_transacciones_quarter_normalizado := cantidad_total_transacciones_quarter * 5]

  if( atributos_presentes( c("cantidad_total_transacciones_quarter", "cliente_antiguedad") ))
    dataset[cliente_antiguedad == 2, cantidad_total_transacciones_quarter_normalizado := cantidad_total_transacciones_quarter * 2]

  if( atributos_presentes( c("cantidad_total_transacciones_quarter", "cliente_antiguedad") ))
    dataset[cliente_antiguedad == 3, cantidad_total_transacciones_quarter_normalizado := cantidad_total_transacciones_quarter * 1.2]

  # variable extraida de una tesis de maestria de Irlanda
  if( atributos_presentes( c("mpayroll", "cliente_edad") ))
    dataset[, mpayroll_sobre_edad := mpayroll / cliente_edad]

  # se crean los nuevos campos para MasterCard  y Visa,
  #  teniendo en cuenta los NA's
  # varias formas de combinar Visa_status y Master_status
  if( atributos_presentes( c("Master_status", "Visa_status") ))
  {
    dataset[, vm_status01 := pmax(Master_status, Visa_status, na.rm = TRUE)]
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


  # combino MasterCard y Visa
  if( atributos_presentes( c("Master_mfinanciacion_limite", "Visa_mfinanciacion_limite") ))
    dataset[, vm_mfinanciacion_limite := rowSums(cbind(Master_mfinanciacion_limite, Visa_mfinanciacion_limite), na.rm = TRUE)]

  if( atributos_presentes( c("Master_Fvencimiento", "Visa_Fvencimiento") ))
    dataset[, vm_Fvencimiento := pmin(Master_Fvencimiento, Visa_Fvencimiento, na.rm = TRUE)]

  if( atributos_presentes( c("Master_Finiciomora", "Visa_Finiciomora") ))
    dataset[, vm_Finiciomora := pmin(Master_Finiciomora, Visa_Finiciomora, na.rm = TRUE)]

  if( atributos_presentes( c("Master_msaldototal", "Visa_msaldototal") ))
    dataset[, vm_msaldototal := rowSums(cbind(Master_msaldototal, Visa_msaldototal), na.rm = TRUE)]

  if( atributos_presentes( c("Master_msaldopesos", "Visa_msaldopesos") ))
    dataset[, vm_msaldopesos := rowSums(cbind(Master_msaldopesos, Visa_msaldopesos), na.rm = TRUE)]

  if( atributos_presentes( c("Master_msaldodolares", "Visa_msaldodolares") ))
    dataset[, vm_msaldodolares := rowSums(cbind(Master_msaldodolares, Visa_msaldodolares), na.rm = TRUE)]

  if( atributos_presentes( c("Master_mconsumospesos", "Visa_mconsumospesos") ))
    dataset[, vm_mconsumospesos := rowSums(cbind(Master_mconsumospesos, Visa_mconsumospesos), na.rm = TRUE)]

  if( atributos_presentes( c("Master_mconsumosdolares", "Visa_mconsumosdolares") ))
    dataset[, vm_mconsumosdolares := rowSums(cbind(Master_mconsumosdolares, Visa_mconsumosdolares), na.rm = TRUE)]

  if( atributos_presentes( c("Master_mlimitecompra", "Visa_mlimitecompra") ))
    dataset[, vm_mlimitecompra := rowSums(cbind(Master_mlimitecompra, Visa_mlimitecompra), na.rm = TRUE)]

  if( atributos_presentes( c("Master_madelantopesos", "Visa_madelantopesos") ))
    dataset[, vm_madelantopesos := rowSums(cbind(Master_madelantopesos, Visa_madelantopesos), na.rm = TRUE)]

  if( atributos_presentes( c("Master_madelantodolares", "Visa_madelantodolares") ))
    dataset[, vm_madelantodolares := rowSums(cbind(Master_madelantodolares, Visa_madelantodolares), na.rm = TRUE)]

  if( atributos_presentes( c("Master_fultimo_cierre", "Visa_fultimo_cierre") ))
    dataset[, vm_fultimo_cierre := pmax(Master_fultimo_cierre, Visa_fultimo_cierre, na.rm = TRUE)]

  if( atributos_presentes( c("Master_mpagado", "Visa_mpagado") ))
    dataset[, vm_mpagado := rowSums(cbind(Master_mpagado, Visa_mpagado), na.rm = TRUE)]

  if( atributos_presentes( c("Master_mpagospesos", "Visa_mpagospesos") ))
    dataset[, vm_mpagospesos := rowSums(cbind(Master_mpagospesos, Visa_mpagospesos), na.rm = TRUE)]

  if( atributos_presentes( c("Master_mpagosdolares", "Visa_mpagosdolares") ))
    dataset[, vm_mpagosdolares := rowSums(cbind(Master_mpagosdolares, Visa_mpagosdolares), na.rm = TRUE)]

  if( atributos_presentes( c("Master_fechaalta", "Visa_fechaalta") ))
    dataset[, vm_fechaalta := pmax(Master_fechaalta, Visa_fechaalta, na.rm = TRUE)]

  if( atributos_presentes( c("Master_mconsumototal", "Visa_mconsumototal") ))
    dataset[, vm_mconsumototal := rowSums(cbind(Master_mconsumototal, Visa_mconsumototal), na.rm = TRUE)]

  if( atributos_presentes( c("Master_cconsumos", "Visa_cconsumos") ))
    dataset[, vm_cconsumos := rowSums(cbind(Master_cconsumos, Visa_cconsumos), na.rm = TRUE)]

  if( atributos_presentes( c("Master_cadelantosefectivo", "Visa_cadelantosefectivo") ))
    dataset[, vm_cadelantosefectivo := rowSums(cbind(Master_cadelantosefectivo, Visa_cadelantosefectivo), na.rm = TRUE)]

  if( atributos_presentes( c("Master_mpagominimo", "Visa_mpagominimo") ))
    dataset[, vm_mpagominimo := rowSums(cbind(Master_mpagominimo, Visa_mpagominimo), na.rm = TRUE)]

  # a partir de aqui juego con la suma de Mastercard y Visa
  if( atributos_presentes( c("Master_mlimitecompra", "vm_mlimitecompra") ))
    dataset[, vmr_Master_mlimitecompra := Master_mlimitecompra / vm_mlimitecompra]

  if( atributos_presentes( c("Visa_mlimitecompra", "vm_mlimitecompra") ))
    dataset[, vmr_Visa_mlimitecompra := Visa_mlimitecompra / vm_mlimitecompra]

  if( atributos_presentes( c("vm_msaldototal", "vm_mlimitecompra") ))
    dataset[, vmr_msaldototal := vm_msaldototal / vm_mlimitecompra]

  if( atributos_presentes( c("vm_msaldopesos", "vm_mlimitecompra") ))
    dataset[, vmr_msaldopesos := vm_msaldopesos / vm_mlimitecompra]

  if( atributos_presentes( c("vm_msaldopesos", "vm_msaldototal") ))
    dataset[, vmr_msaldopesos2 := vm_msaldopesos / vm_msaldototal]

  if( atributos_presentes( c("vm_msaldodolares", "vm_mlimitecompra") ))
    dataset[, vmr_msaldodolares := vm_msaldodolares / vm_mlimitecompra]

  if( atributos_presentes( c("vm_msaldodolares", "vm_msaldototal") ))
    dataset[, vmr_msaldodolares2 := vm_msaldodolares / vm_msaldototal]

  if( atributos_presentes( c("vm_mconsumospesos", "vm_mlimitecompra") ))
    dataset[, vmr_mconsumospesos := vm_mconsumospesos / vm_mlimitecompra]

  if( atributos_presentes( c("vm_mconsumosdolares", "vm_mlimitecompra") ))
    dataset[, vmr_mconsumosdolares := vm_mconsumosdolares / vm_mlimitecompra]

  if( atributos_presentes( c("vm_madelantopesos", "vm_mlimitecompra") ))
    dataset[, vmr_madelantopesos := vm_madelantopesos / vm_mlimitecompra]

  if( atributos_presentes( c("vm_madelantodolares", "vm_mlimitecompra") ))
    dataset[, vmr_madelantodolares := vm_madelantodolares / vm_mlimitecompra]

  if( atributos_presentes( c("vm_mpagado", "vm_mlimitecompra") ))
    dataset[, vmr_mpagado := vm_mpagado / vm_mlimitecompra]

  if( atributos_presentes( c("vm_mpagospesos", "vm_mlimitecompra") ))
    dataset[, vmr_mpagospesos := vm_mpagospesos / vm_mlimitecompra]

  if( atributos_presentes( c("vm_mpagosdolares", "vm_mlimitecompra") ))
    dataset[, vmr_mpagosdolares := vm_mpagosdolares / vm_mlimitecompra]

  if( atributos_presentes( c("vm_mconsumototal", "vm_mlimitecompra") ))
    dataset[, vmr_mconsumototal := vm_mconsumototal / vm_mlimitecompra]

  if( atributos_presentes( c("vm_mpagominimo", "vm_mlimitecompra") ))
    dataset[, vmr_mpagominimo := vm_mpagominimo / vm_mlimitecompra]

  # Aqui debe usted agregar sus propias nuevas variables

  # valvula de seguridad para evitar valores infinitos
  # paso los infinitos a NULOS
  infinitos <- lapply(
    names(dataset),
    function(.name) dataset[, sum(is.infinite(get(.name)))]
  )

  infinitos_qty <- sum(unlist(infinitos))
  if (infinitos_qty > 0) {
    cat(
      "ATENCION, hay", infinitos_qty,
      "valores infinitos en tu dataset. Seran pasados a NA\n"
    )
    dataset[mapply(is.infinite, dataset)] <<- NA
  }


  # valvula de seguridad para evitar valores NaN  que es 0/0
  # paso los NaN a 0 , decision polemica si las hay
  # se invita a asignar un valor razonable segun la semantica del campo creado
  nans <- lapply(
    names(dataset),
    function(.name) dataset[, sum(is.nan(get(.name)))]
  )

  nans_qty <- sum(unlist(nans))
  if (nans_qty > 0) {
    cat(
      "ATENCION, hay", nans_qty,
      "valores NaN 0/0 en tu dataset. Seran pasados arbitrariamente a 0\n"
    )

    cat("Si no te gusta la decision, modifica a gusto el programa!\n\n")
    dataset[mapply(is.nan, dataset)] <<- 0
  }

  cat( "fin AgregarVariables_IntraMes()\n")
}

# --- z635 celda 44 ---
# agrego las variables intra mes

AgregarVariables_IntraMes(dataset)

    fin_etapa()

    etapa("FE genetico")
    correr_genetica()
    fin_etapa(texto_ganadoras())

    etapa("FE historico")
# --- z635 celda 48 ---
if( !require("Rcpp")) install.packages("Rcpp", repos = "http://cran.us.r-project.org")
require("Rcpp")

# --- z635 celda 49 ---
# se calculan para los 6 meses previos el minimo, maximo y
#  tendencia calculada con cuadrados minimos
# la formula de calculo de la tendencia puede verse en
#  https://stats.libretexts.org/Bookshelves/Introductory_Statistics/Book%3A_Introductory_Statistics_(Shafer_and_Zhang)/10%3A_Correlation_and_Regression/10.04%3A_The_Least_Squares_Regression_Line
# para la maxíma velocidad esta funcion esta escrita en lenguaje C,
# y no en la porqueria de R o Python

cppFunction("NumericVector fhistC(NumericVector pcolumna, IntegerVector pdesde )
{
  /* Aqui se cargan los valores para la regresion */
  double  x[100] ;
  double  y[100] ;

  int n = pcolumna.size();
  NumericVector out( 5*n );

  for(int i = 0; i < n; i++)
  {
    //lag
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

    /* Si hay al menos dos valores */
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

# --- z635 celda 50 ---
# calcula la tendencia de las variables cols de los ultimos 6 meses
# la tendencia es la pendiente de la recta que ajusta por cuadrados minimos
# La funcionalidad de ratioavg es autoria de  Daiana Sparta,  UAustral  2021

TendenciaYmuchomas <- function(
    dataset, cols, ventana = 6, tendencia = TRUE,
    minimo = TRUE, maximo = TRUE, promedio = TRUE,
    ratioavg = FALSE, ratiomax = FALSE) {
  gc(verbose= FALSE)
  # Esta es la cantidad de meses que utilizo para la historia
  ventana_regresion <- ventana

  last <- nrow(dataset)

  # creo el vector_desde que indica cada ventana
  # de esta forma se acelera el procesamiento ya que lo hago una sola vez
  vector_ids <- dataset[ , numero_de_cliente ]

  vector_desde <- seq(
    -ventana_regresion + 2,
    nrow(dataset) - ventana_regresion + 1
  )

  vector_desde[1:ventana_regresion] <- 1

  for (i in 2:last) {
    if (vector_ids[i - 1] != vector_ids[i]) {
      vector_desde[i] <- i
    }
  }
  for (i in 2:last) {
    if (vector_desde[i] < vector_desde[i - 1]) {
      vector_desde[i] <- vector_desde[i - 1]
    }
  }

  for (campo in cols) {
    nueva_col <- fhistC(dataset[, get(campo)], vector_desde)

    if (tendencia) {
      dataset[, paste0(campo, "_tend", ventana) :=
        nueva_col[(0 * last + 1):(1 * last)]]
    }

    if (minimo) {
      dataset[, paste0(campo, "_min", ventana) :=
        nueva_col[(1 * last + 1):(2 * last)]]
    }

    if (maximo) {
      dataset[, paste0(campo, "_max", ventana) :=
        nueva_col[(2 * last + 1):(3 * last)]]
    }

    if (promedio) {
      dataset[, paste0(campo, "_avg", ventana) :=
        nueva_col[(3 * last + 1):(4 * last)]]
    }

    if (ratioavg) {
      dataset[, paste0(campo, "_ratioavg", ventana) :=
        get(campo) / nueva_col[(3 * last + 1):(4 * last)]]
    }

    if (ratiomax) {
      dataset[, paste0(campo, "_ratiomax", ventana) :=
        get(campo) / nueva_col[(2 * last + 1):(3 * last)]]
    }
  }
}

# --- z635 celda 51 ---
# Feature Engineering Historico

setorder(dataset, numero_de_cliente, foto_mes)

# todo es lagueable, menos la primary key y la clase
cols_lagueables <- copy( setdiff(
    colnames(dataset),
    c("numero_de_cliente", "foto_mes", "clase_ternaria")
) )

# https://rdrr.io/cran/data.table/man/shift.html

# lags de orden 1
dataset[,
    paste0(cols_lagueables, "_lag1") := shift(.SD, 1, NA, "lag"),
    by = numero_de_cliente,
    .SDcols = cols_lagueables
]

# lags de orden 2
dataset[,
    paste0(cols_lagueables, "_lag2") := shift(.SD, 2, NA, "lag"),
    by = numero_de_cliente,
    .SDcols = cols_lagueables
]

# agrego los delta lags
for (vcol in cols_lagueables)
{
    dataset[, paste0(vcol, "_delta1") := get(vcol) - get(paste0(vcol, "_lag1"))]
    dataset[, paste0(vcol, "_delta2") := get(vcol) - get(paste0(vcol, "_lag2"))]
}

# --- z635 celda 52 ---
# parametros de Feature Engineering Historico de Tendencias
PARAM$FE_hist$Tendencias$run <- TRUE
PARAM$FE_hist$Tendencias$ventana <- 6
PARAM$FE_hist$Tendencias$tendencia <- TRUE
PARAM$FE_hist$Tendencias$minimo <- FALSE
PARAM$FE_hist$Tendencias$maximo <- FALSE
PARAM$FE_hist$Tendencias$promedio <- FALSE
PARAM$FE_hist$Tendencias$ratioavg <- FALSE
PARAM$FE_hist$Tendencias$ratiomax <- FALSE

# --- z635 celda 53 ---
cols_lagueables <- intersect(cols_lagueables, colnames(dataset))
setorder(dataset, numero_de_cliente, foto_mes)

if( PARAM$FE_hist$Tendencias$run) {
    TendenciaYmuchomas(dataset,
    cols = cols_lagueables,
    ventana = PARAM$FE_hist$Tendencias$ventana, # 6 meses de historia
    tendencia = PARAM$FE_hist$Tendencias$tendencia,
    minimo = PARAM$FE_hist$Tendencias$minimo,
    maximo = PARAM$FE_hist$Tendencias$maximo,
    promedio = PARAM$FE_hist$Tendencias$promedio,
    ratioavg = PARAM$FE_hist$Tendencias$ratioavg,
    ratiomax = PARAM$FE_hist$Tendencias$ratiomax
  )
}

    grabar_checkpoint(CK_HIST)
    fin_etapa("Checkpoint grabado: si se corta, retoma desde aca.")

  } else {
    dataset <- leer_checkpoint(CK_HIST)
  }

  etapa("FE random forest")
# --- z635 celda 57 ---
if( !require("lightgbm")) install.packages("lightgbm")
require("lightgbm")

# --- z635 celda 58 ---
AgregaVarRandomForest <- function() {

  cat( "inicio AgregaVarRandomForest()\n")
  gc(verbose= FALSE)
  dataset[, clase01 := 0L ]
  dataset[ clase_ternaria %in% PARAM$FE_rf$train$clase01_valor1,
      clase01 := 1L ]

  campos_buenos <- setdiff(
    colnames(dataset),
    c( "clase_ternaria", "clase01")
  )

  dataset[, entrenamiento :=
    as.integer( foto_mes %in% PARAM$FE_rf$train$training )]

  dtrain <- lgb.Dataset(
    data = data.matrix(dataset[entrenamiento == TRUE, campos_buenos, with = FALSE]),
    label = dataset[entrenamiento == TRUE, clase01],
    free_raw_data = FALSE
  )

  modelo <- lgb.train(
     data = dtrain,
     param = PARAM$FE_rf$lgb_param,
     verbose = -100
  )

  cat( "Fin construccion RandomForest\n" )
  # grabo el modelo, achivo .model
  lgb.save(modelo, file="modelo.model" )

  qarbolitos <- copy(PARAM$FE_rf$lgb_param$num_iterations)

  periodos <- dataset[ , unique( foto_mes ) ]

  for( periodo in  periodos )
  {
    cat( "periodo = ", periodo, "\n" )
    datamatrix <- data.matrix(dataset[ foto_mes== periodo, campos_buenos, with = FALSE])

    cat( "Inicio prediccion\n" )
    prediccion <- predict(
        modelo,
        datamatrix,
        type = "leaf"
    )
    cat( "Fin prediccion\n" )

    for( arbolito in 1:qarbolitos )
    {
       cat( arbolito, " " )
       hojas_arbol <- unique(prediccion[ , arbolito])

       for (pos in 1:length(hojas_arbol)) {
         # el numero de nodo de la hoja, estan salteados
         nodo_id <- hojas_arbol[pos]
         dataset[ foto_mes== periodo, paste0(
            "rf_", sprintf("%03d", arbolito),
             "_", sprintf("%03d", nodo_id)
          ) :=  as.integer( nodo_id == prediccion[ , arbolito]) ]

       }

       rm( hojas_arbol )
    }
    cat( "\n" )

    rm( prediccion )
    rm( datamatrix )
    gc(verbose= FALSE)
  }

  gc(verbose= FALSE)

  # borro clase01 , no debe ensuciar el dataset
  dataset[ , clase01 := NULL ]

}

# --- z635 celda 59 ---
# Parametros de Feature Engineering  a partir de hojas de Random Forest

# Estos CUATRO parametros son los que se deben modificar
PARAM$FE_rf$arbolitos= 20
PARAM$FE_rf$hojas_por_arbol= 16
PARAM$FE_rf$datos_por_hoja= 100
PARAM$FE_rf$mtry_ratio= 0.2

# Estos son quasi fijos
PARAM$FE_rf$train$clase01_valor1 <- c( "BAJA+2", "BAJA+1")
PARAM$FE_rf$train$training <- c( 202101, 202102, 202103)

# Estos TAMBIEN son quasi fijos
PARAM$FE_rf$lgb_param <-list(
    # parametros que se pueden cambiar
    num_iterations = PARAM$FE_rf$arbolitos,
    num_leaves  = PARAM$FE_rf$hojas_por_arbol,
    min_data_in_leaf = PARAM$FE_rf$datos_por_hoja,
    feature_fraction_bynode  = PARAM$FE_rf$mtry_ratio,

    # para que LightGBM emule Random Forest
    boosting = "rf",
    bagging_fraction = ( 1.0 - 1.0/exp(1.0) ),
    bagging_freq = 1.0,
    feature_fraction = 1.0,

    # genericos de LightGBM
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

# --- z635 celda 60 ---
# Feature Engineering agregando variables de Random Forest
AgregaVarRandomForest()

  fin_etapa()

  etapa("canaritos")
# --- z635 celda 65 ---
VPOS_CORTE <- c()

fganancia_lgbm_meseta <- function(probs, datos) {
  vlabels <- get_field(datos, "label")
  vpesos <- get_field(datos, "weight")

  tbl <- as.data.table(list(
    "prob" = probs,
    "gan" = ifelse(vlabels == 1 & vpesos > 1, PARAM$CN$train$gan1, PARAM$CN$train$gan0)
  ))

  setorder(tbl, -prob)
  tbl[, posicion := .I]
  tbl[, gan_acum := cumsum(gan)]
  setorder(tbl, -gan_acum) # voy por la meseta

  gan <- mean(tbl[1:500, gan_acum]) # meseta de tamaño 500

  pos_meseta <- tbl[1:500, median(posicion)]
  VPOS_CORTE <<- c(VPOS_CORTE, pos_meseta)

  return(list(
    "name" = "ganancia",
    "value" = gan,
    "higher_better" = TRUE
  ))
}

# --- z635 celda 66 ---
# Elimina del dataset las variables que estan por debajo
#  de la capa geologica de canaritos
# se llama varias veces, luego de agregar muchas variables nuevas,
#  para ir reduciendo la cantidad de variables
# y así hacer lugar a nuevas variables importantes

GVEZ <- 1

campitos <- c( "numero_de_cliente", "foto_mes", "clase_ternaria" )

CanaritosAsesinos <- function(
  canaritos_ratio,
  canaritos_desvios,
  canaritos_semilla) {

  cat( "inicio CanaritosAsesinos()\n")
  gc(verbose= FALSE)
  dataset[, clase01 := 0L ]
  dataset[ clase_ternaria %in% PARAM$CN$train$clase01_valor1,
      clase01 := 1L ]

  set.seed(canaritos_semilla, kind = "L'Ecuyer-CMRG")
  for (i in 1:(ncol(dataset) * canaritos_ratio)) {
    dataset[, paste0("canarito", i) := runif(nrow(dataset))]
  }

  campos_buenos <- setdiff(
    colnames(dataset),
    c( campitos, "clase01")
  )

  azar <- runif(nrow(dataset))

  dataset[, entrenamiento :=
    as.integer( foto_mes %in% PARAM$CN$train$training &
      (clase01 == 1 | azar < PARAM$CN$train$undersampling))]

  dtrain <- lgb.Dataset(
    data = data.matrix(dataset[entrenamiento == TRUE, campos_buenos, with = FALSE]),
    label = dataset[entrenamiento == TRUE, clase01],
    weight = dataset[
      entrenamiento == TRUE,
      ifelse(clase_ternaria %in% PARAM$CN$train$positivos, 1.0000001, 1.0)
    ],
    free_raw_data = FALSE
  )

  dvalid <- lgb.Dataset(
    data = data.matrix(dataset[foto_mes %in% PARAM$CN$train$validation, campos_buenos, with = FALSE]),
    label = dataset[foto_mes %in% PARAM$CN$train$validation, clase01],
    weight = dataset[
      foto_mes %in% PARAM$CN$train$validation,
      ifelse( clase_ternaria %in% PARAM$CN$train$positivos, 1.0000001, 1.0)
    ],
    free_raw_data = FALSE
  )


  param <- list(
    objective = "binary",
    metric = "custom",
    first_metric_only = TRUE,
    boost_from_average = TRUE,
    feature_pre_filter = FALSE,
    verbosity = -100,
    seed = canaritos_semilla,
    max_depth = -1, # -1 significa no limitar,  por ahora lo dejo fijo
    min_gain_to_split = 0.0, # por ahora, lo dejo fijo
    lambda_l1 = 0.0, # por ahora, lo dejo fijo
    lambda_l2 = 0.0, # por ahora, lo dejo fijo
    max_bin = 31, # por ahora, lo dejo fijo
    num_iterations = 9999, # un numero grande, lo limita early_stopping_rounds
    force_row_wise = TRUE, # para que los alumnos no se atemoricen con  warning
    learning_rate = 0.065,
    feature_fraction = 1.0, # lo seteo en 1
    min_data_in_leaf = 260,
    num_leaves = 60,
    early_stopping_rounds = 200,
    num_threads = 1
  )

  set.seed(canaritos_semilla, kind = "L'Ecuyer-CMRG")
  modelo <- lgb.train(
    data = dtrain,
    valids = list(valid = dvalid),
    eval = fganancia_lgbm_meseta,
    param = param,
    verbose = -100
  )

  tb_importancia <- lgb.importance(model = modelo)
  tb_importancia[, pos := .I]

  fwrite(tb_importancia,
    file = paste0("impo_", GVEZ, ".txt"),
    sep = "\t"
  )

  GVEZ <<- GVEZ + 1

  umbral <- tb_importancia[
    Feature %like% "canarito",
    median(pos) + canaritos_desvios * sd(pos)
  ] # Atencion corto en la mediana mas desvios!!

  col_utiles <- tb_importancia[
    pos < umbral & !(Feature %like% "canarito"),
    Feature
  ]

  col_utiles <- unique(c(
    col_utiles,
    c(campitos, "mes")
  ))

  col_inutiles <- setdiff(colnames(dataset), col_utiles)

  dataset[, (col_inutiles) := NULL]

  cat( "fin CanaritosAsesinos()\n")

  return( tb_importancia )
}

# --- z635 celda 67 ---
# Estos DOS parametros son los que se deben modificar
PARAM$CN$ratio <- 0.2
PARAM$CN$desvios <- 2


# Parametros quasi fijos
# Parametros de un LightGBM que se genera para estimar la column importance
PARAM$CN$train$clase01_valor1 <- c( "BAJA+2", "BAJA+1")
PARAM$CN$train$positivos <- c( "BAJA+2")
PARAM$CN$train$training <- c( 202101, 202102, 202103)
PARAM$CN$train$validation <- c( 202105 )
PARAM$CN$train$undersampling <- 0.1
PARAM$CN$train$gan1 <- 0.975
PARAM$CN$train$gan0 <- -0.025

  # las variables geneticas, si se pidio protegerlas (no entran al LightGBM de
  # canaritos y no se pueden borrar, igual que numero_de_cliente o foto_mes)
  if (PARAM$GA$proteger_de_canaritos && nrow(ga_ganadoras()))
    campitos <- unique(c(campitos, ga_ganadoras()$nombre))
# --- z635 celda 68 ---
# la llamada a Canaritos Asesinos
tb_importancia <- CanaritosAsesinos(
  canaritos_ratio = PARAM$CN$ratio,
  canaritos_desvios = PARAM$CN$desvios,
  canaritos_semilla = PARAM$semilla_primigenia
)

# --- z635 celda 69 ---
# grabo la importancia, ver el archivo directamente en la carpeta

fwrite( tb_importancia,
  file="canaritos.txt",
  sep="\t"
)

  grabar_checkpoint(CK_CANARITOS)
  fin_etapa("Checkpoint grabado: si se corta, retoma desde aca.")

} else {
  dataset <- leer_checkpoint(CK_CANARITOS)
}

# ===========================================================================
# 9.7.2 MODELADO
# ===========================================================================

etapa("training strategy")
# Reemplaza la celda 74 del z635: los meses dependen del grupo
meses <- function(desde, hasta) {
  todos <- c(201901:201912, 202001:202012, 202101:202112)
  todos[todos >= desde & todos <= hasta]
}

if (GRUPO == "A") {
  PARAM$trainingstrategy$validate    <- c(202107)
  PARAM$trainingstrategy$training    <- meses(201901, 202105)
  PARAM$trainingstrategy$final_train <- meses(201901, 202107)
  PARAM$trainingstrategy$future      <- c(202109)
} else {
  # se deja 202104 como gap, igual que el A deja 202106
  PARAM$trainingstrategy$validate    <- c(202105)
  PARAM$trainingstrategy$training    <- meses(201901, 202103)
  PARAM$trainingstrategy$final_train <- meses(201901, 202105)
  PARAM$trainingstrategy$future      <- c(202107)
}
PARAM$trainingstrategy$training_pct <- 0.2
PARAM$trainingstrategy$positivos <- c( "BAJA+1", "BAJA+2")

# --- z635 celda 75 ---
# seteo la clase01   1={BAJA+1, BAJA+2}   0={CONTINUA}
dataset[, clase01 := ifelse( clase_ternaria %in% PARAM$trainingstrategy$positivos, 1, 0 )]

# --- z635 celda 76 ---
# los campos en los que se entrena
campos_buenos <- copy( setdiff(
    colnames(dataset), c("clase_ternaria","clase01","azar"))
)

# --- z635 celda 77 ---
# preparo para que se puede hacer undersampling de los CONTINUA
#  solamente por un tema de VELOCIDAD
set.seed(PARAM$semilla_primigenia, kind = "L'Ecuyer-CMRG")
dataset[, azar:=runif(nrow(dataset))]

# undersampling de los CONTINUA
dataset[, fold_train :=  foto_mes %in%  PARAM$trainingstrategy$training &
    (clase_ternaria %in% c("BAJA+1", "BAJA+2") |
     azar < PARAM$trainingstrategy$training_pct ) ]


if( !require("lightgbm")) install.packages("lightgbm")
require("lightgbm")

dtrain <- lgb.Dataset(
  data= data.matrix(dataset[fold_train == TRUE, campos_buenos, with = FALSE]),
  label= dataset[fold_train == TRUE, clase01],
  free_raw_data= TRUE
)

# --- z635 celda 78 ---
# datos de validation
dvalidate <- lgb.Dataset(
  data= data.matrix(dataset[foto_mes %in% PARAM$trainingstrategy$validate, campos_buenos, with = FALSE]),
  label= dataset[foto_mes %in% PARAM$trainingstrategy$validate, clase01],
  free_raw_data= TRUE
)

nrow(dvalidate)

fin_etapa(paste0("validate ", paste(PARAM$trainingstrategy$validate, collapse= " "),
  ", future ", paste(PARAM$trainingstrategy$future, collapse= " ")))

# ---------------------------------------------------------------------------
# 9.7.2.2 HYPERPARAMETER TUNING
# ---------------------------------------------------------------------------
etapa("optimizacion bayesiana")

# cada evaluacion queda en BO_iter.txt apenas termina
BO_EVALS <- if (file.exists("BO_iter.txt")) nrow(fread("BO_iter.txt")) else 0L

registrar_eval <- function(x, AUC) {
  BO_EVALS <<- BO_EVALS + 1L
  fila <- data.table(eval= BO_EVALS, fecha= format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    AUC= AUC, as.data.table(lapply(x, as.numeric)))
  fwrite(fila, "BO_iter.txt", sep= "\t", append= file.exists("BO_iter.txt"))

  if (PARAM$mail$cada_iter > 0 && BO_EVALS %% PARAM$mail$cada_iter == 0) {
    tb <- fread("BO_iter.txt")
    mejor <- tb[which.max(AUC)]
    mandar_mail(sprintf("BO: %d evaluaciones", BO_EVALS),
      paste0("Mejor AUC hasta ahora: ", round(mejor$AUC, 6), " (evaluacion ", mejor$eval, ")\n",
             "Ultima: ", round(AUC, 6), "\n\n",
             paste(capture.output(print(tail(tb, PARAM$mail$cada_iter))), collapse= "\n")))
  }
}

# --- z635 celda 83 ---
# paquetes necesarios para la Bayesian Optimization
if(!require("DiceKriging")) install.packages("DiceKriging")
require("DiceKriging")

if(!require("mlrMBO")) install.packages("mlrMBO")
require("mlrMBO")

# --- z635 celda 85 ---
# 40 es el minimo razonable,  un buen analista Sr aumentara este valor
PARAM$hipeparametertuning$num_interations <- 30

# parametros fijos del LightGBM
PARAM$lgbm$param_fijos <- list(
  objective= "binary",
  metric= "auc",
  first_metric_only= TRUE,
  boost_from_average= TRUE,
  feature_pre_filter= FALSE,
  verbosity= -100,
  force_row_wise= TRUE, # para evitar warning
  seed= PARAM$semilla_primigenia,
  extra_trees= FALSE,

  num_leaves= 128,
  max_depth= -1L, # -1 significa no limitar,  por ahora lo dejo fijo
  min_gain_to_split= 0.0, # min_gain_to_split >= 0.0
  min_data_in_leaf= 0,
  min_sum_hessian_in_leaf= 0.001, #  min_sum_hessian_in_leaf >= 0.0
  lambda_l1= 0.0, # lambda_l1 >= 0.0
  lambda_l2= 0.0, # lambda_l2 >= 0.0

  bagging_fraction= 1.0, # 0.0 < bagging_fraction <= 1.0
  pos_bagging_fraction= 1.0, # 0.0 < pos_bagging_fraction <= 1.0
  neg_bagging_fraction= 1.0, # 0.0 < neg_bagging_fraction <= 1.0
  is_unbalance= FALSE, #
  scale_pos_weight= 1.0, # scale_pos_weight > 0.0

  drop_rate= 0.1, # 0.0 < neg_bagging_fraction <= 1.0
  max_drop= 50, # <=0 means no limit
  skip_drop= 0.5, # 0.0 <= skip_drop <= 1.0

  max_bin= 31,
  early_stopping_rounds= 0
)

# --- z635 celda 86 ---

PARAM$hipeparametertuning$hs <- makeParamSet(
  makeNumericParam("num_iterations", lower= 2.0, upper= 10.0, trafo= function(x) round(2^x) ),
  makeNumericParam("num_leaves", lower= 2.0, upper= 11.0, trafo= function(x) round(2^x) ),
  makeNumericParam("learning_rate", lower= -7.0, upper= -0.1, trafo= function(x) 2^x ),
  makeNumericParam("feature_fraction", lower= 0.05, upper= 0.90),
  makeNumericParam("min_sum_hessian_in_leaf", lower= -10.0, upper= 10.0, trafo= function(x) 2^x)
)

# --- z635 celda 88 (+ registrar_eval) ---
# En  x llegan los parmaetros de la bayesiana
#  devuelve la AUC en validate del modelo entrenado
#  en el parametro x llegan los hiperparámetros que se estan optimizando

EstimarGanancia_AUC_lightgbm <- function(x) {

  # x pisa (o agrega) a param_fijos
  param_completo <- modifyList(PARAM$lgbm$param_fijos, x)

  # entreno LightGBM
  modelo_train <- lgb.train(
    data= dtrain,
    valids= list(valid = dvalidate),
    eval= "auc",
    param= param_completo,
    verbose= -100
  )

  # recupero la AUC en validation
  AUC <- modelo_train$record_evals$valid$auc$eval[[x$num_iterations]]


  message(format(Sys.time(), "%a %b %d %X %Y  "),
    toString(x),
    " AUC ", AUC
  )

  # hago espacio en la memoria
  rm(modelo_train)
  gc(full= TRUE, verbose= FALSE)

  registrar_eval(x, AUC)
  return(AUC)
}

# --- z635 celda 90 (graba en cada iteracion) ---
configureMlr(show.learner.output = FALSE)

# configuro la busqueda bayesiana,  los hiperparametros que se van a optimizar
# por favor, no desesperarse por lo complejo
obj.fun <- makeSingleObjectiveFunction(
    fn= EstimarGanancia_AUC_lightgbm, # la funcion que voy a maximizar
    minimize= FALSE, # estoy Maximizando AUC
    noisy= FALSE,
    par.set= PARAM$hipeparametertuning$hs,
    has.simple.signature= FALSE # paso los parametros en una lista
)

# cada 600 segundos guardo el resultado intermedio
ctrl <- makeMBOControl(
    save.on.disk.at= 0:(PARAM$hipeparametertuning$num_interations + 1), # graba en CADA iteracion
    save.file.path= "HT.RDATA"
)

# indico la cantidad de iteraciones que va a tener la Bayesian Optimization
ctrl <- setMBOControlTermination(
    ctrl,
    iters= PARAM$hipeparametertuning$num_interations  # cantidad de iteraciones inteligentes
)

# defino el método estandar para la creacion de los puntos iniciales
#   los "No Inteligentes"
ctrl <- setMBOControlInfill(ctrl, crit = makeMBOInfillCritEI())

# mas configuraciones
surr.km <- makeLearner(
    "regr.km",
    predict.type= "se",
    covtype= "matern3_2",
    control= list(trace = TRUE)
)


# Reemplaza la celda 92 del z635. mlrMBO no graba nada hasta terminar el
# diseno inicial (20 entrenamientos), asi que el diseno inicial se evalua
# aca, una fila por vez, grabando cada resultado en BO_init.txt. Con el
# diseno completo, mbo() sigue con las iteraciones inteligentes y graba
# HT.RDATA en cada una.
correr_bayesiana <- function() {
  if (file.exists("HT.RDATA")) {
    loguear("retomo la BO desde HT.RDATA")
    return(mboContinue("HT.RDATA"))
  }
  if (!require("lhs")) install.packages("lhs")
  hs <- PARAM$hipeparametertuning$hs
  set.seed(PARAM$semilla_primigenia, kind = "L'Ecuyer-CMRG")
  diseno <- ParamHelpers::generateDesign(n= 4L * ParamHelpers::getParamNr(hs, devectorize= TRUE), par.set= hs, fun= lhs::maximinLHS)
  diseno$y <- NA_real_
  if (file.exists("BO_init.txt")) {
    hechos <- fread("BO_init.txt")
    diseno$y[hechos$i] <- hechos$y
    loguear("diseno inicial: ya hay", nrow(hechos), "de", nrow(diseno), "puntos evaluados")
  }
  for (i in which(is.na(diseno$y))) {
    x <- ParamHelpers::trafoValue(hs, as.list(diseno[i, ParamHelpers::getParamIds(hs), drop= FALSE]))
    diseno$y[i] <- EstimarGanancia_AUC_lightgbm(x)
    fwrite(data.table(i= i, y= diseno$y[i]), "BO_init.txt", sep= "\t", append= file.exists("BO_init.txt"))
  }
  mbo(obj.fun, design= diseno, learner= surr.km, control= ctrl)
}

if (!file.exists("BO_log.txt")) {
  bayesiana_salida <- correr_bayesiana()
# --- z635 celda 94 ---
# almaceno los resultados de la Bayesian Optimization
# y capturo los mejores hiperparametros encontrados

tb_bayesiana <- as.data.table(bayesiana_salida$opt.path)

# ordeno en forma descendente por AUC = y
setorder(tb_bayesiana, -y, -num_iterations)

# grabo para eventualmente poder utilizarlos en OTRA corrida
fwrite( tb_bayesiana,
  file="BO_log.txt",
  sep="\t"
)

# los mejores hiperparámetros son los que quedaron en el registro 1 de la tabla
PARAM$out$lgbm$mejores_hiperparametros <- tb_bayesiana[
  1, # el primero es el de mejor AUC
  setdiff(colnames(tb_bayesiana),
    c("y","dob","eol","error.message","exec.time","ei","error.model",
      "train.time","prop.type","propose.time","se","mean","iter")),
  with= FALSE
]

print(PARAM$out$lgbm$mejores_hiperparametros)

} else {
  loguear("la BO ya habia terminado: leo BO_log.txt")
  tb_bayesiana <- fread("BO_log.txt")
  PARAM$out$lgbm$mejores_hiperparametros <- tb_bayesiana[
    1,
    setdiff(colnames(tb_bayesiana),
      c("y","dob","eol","error.message","exec.time","ei","error.model",
        "train.time","prop.type","propose.time","se","mean","iter")),
    with= FALSE
  ]
}
fin_etapa(paste0("Mejor AUC: ", round(tb_bayesiana[1, y], 6), "\n",
  paste(capture.output(print(PARAM$out$lgbm$mejores_hiperparametros)), collapse= "\n")))

# ===========================================================================
# 9.7.3 PRODUCCION
# ===========================================================================

etapa("final training")
# --- z635 celda 100 ---
# uno los parametros fijos y los mejores encontrados de los variables
fijos <- copy(PARAM$lgbm$param_fijos)

# quito lo que optimice en la Bayesian Optimization
fijos$num_iterations <- NULL
fijos$early_stopping_rounds <- NULL

# agrego a los hiperparametros fijos los que encontre con la Bayesian Optimization
param_final <- copy(fijos)

x <- PARAM$out$lgbm$mejores_hiperparametros
param_final$num_iterations <- round( 2^x$num_iterations )
param_final$num_leaves <- round( 2^x$num_leaves )
param_final$learning_rate <- 2^x$learning_rate
param_final$feature_fraction <- x$feature_fraction
param_final$min_sum_hessian_in_leaf <- 2^x$min_sum_hessian_in_leaf


# --- z635 celda 106 ---
primero <- TRUE

crear_modelo_final <- function( sem ) {

  nombre_arch <- paste0( "./modelos/modelo_", sem, ".txt")
  if( !file.exists(nombre_arch) )
  {
    param_final$seed <- sem

    set.seed(sem, kind = "L'Ecuyer-CMRG")
    final_model <- lgb.train(
      data= dfinal_train,
      param= param_final,
      verbose= -100
    )

    lgb.save(final_model, nombre_arch) # grabo el modelo"

    # grabo la primer importancia de variables
    #  Natalia : da lo mismo cual se guarda
    if( primero)
    {
      primero <<- FALSE
      tb_importancia <- as.data.table(lgb.importance(final_model))
      archivo_importancia <- "impo.txt"

      fwrite( tb_importancia,
        file= archivo_importancia,
        sep= "\t"
      )
    }

    rm(final_model)
    gc(full = TRUE, verbose=FALSE)
  }
}


dir.create("modelos", showWarnings =FALSE)
faltan_modelos <- PARAM$FT$semillas[!file.exists(paste0("./modelos/modelo_", PARAM$FT$semillas, ".txt"))]
loguear("modelos finales: faltan", length(faltan_modelos), "de", length(PARAM$FT$semillas))

if (length(faltan_modelos)) {
  # reemplaza la celda 98: los meses de final_train ya los fijo el grupo
  dataset[, fold_final_train := foto_mes %in% PARAM$trainingstrategy$final_train ]

  dfinal_train <- lgb.Dataset(
    data= data.matrix(dataset[fold_final_train == TRUE, campos_buenos, with= FALSE]),
    label= dataset[fold_final_train == TRUE, clase01],
    free_raw_data= TRUE
  )

  gc(full = TRUE, verbose=FALSE)
  primero <- !file.exists("impo.txt")
  for (sem in faltan_modelos) {
    crear_modelo_final(sem)                # graba ./modelos/modelo_<sem>.txt
    loguear("modelo final listo, semilla", sem)
  }
  rm(dfinal_train)
  gc(full = TRUE, verbose=FALSE)
}
fin_etapa(paste0("Semillas: ", paste(PARAM$FT$semillas, collapse= ", ")))

etapa("scoring")
dfuture <- dataset[ foto_mes %in% PARAM$trainingstrategy$future ]
# --- z635 celda 111 ---
# aplico final_model   a dfuture

tb_prediccion <- dfuture[, list(numero_de_cliente)]
tb_prediccion[, prob := 0]

datos_matrix <- data.matrix(dfuture[, campos_buenos, with= FALSE])

# --- z635 celda 112 ---
agregar_a_ensemble <- function( sem ) {

  nombre_arch <- paste0( "./modelos/modelo_", sem, ".txt")
  final_model <- lgb.load(nombre_arch)

  prediccion <- predict(
    final_model,
    datos_matrix
  )

  tb_prediccion[, paste0("prob_", isem) := prediccion]
  tb_prediccion[, prob := prob + prediccion]

  rm(final_model)
  rm(prediccion)
  gc(full = TRUE, verbose=FALSE)
}

# --- z635 celda 113 ---
for( isem in seq(length(PARAM$FT$semillas)) )
{
  sem <- PARAM$FT$semillas[ isem ]
  agregar_a_ensemble( sem )
  gc(full = TRUE, verbose=FALSE)
}

rm( datos_matrix)
gc(full = TRUE, verbose=FALSE)

tb_prediccion[, prob := prob /length(PARAM$FT$semillas) ]

# --- z635 celda 115 ---
# grabo las probabilidad del modelo
#  me va a ser util para hacer Ensembles de modelos
fwrite(tb_prediccion,
  file= "prediccion.txt",
  sep= "\t"
)

# la clase real queda al lado de la probabilidad (el grupo B la usa)
tb_prediccion[, clase_ternaria := dfuture$clase_ternaria]
fin_etapa(paste0("Clientes en ", paste(PARAM$trainingstrategy$future, collapse= " "), ": ", nrow(tb_prediccion)))

# ---------------------------------------------------------------------------
# GRUPO A: Kaggle.  GRUPO B: ganancia contra la clase real de 202107
# ---------------------------------------------------------------------------
resumen <- ""

if (GRUPO == "A") {
  etapa("kaggle")
  # kaggle.json y el CLI se prepararon al arrancar; si no andaban, se reintenta
  # (el kaggle.json pudo haberse subido al bucket durante la corrida)
  if (!KAGGLE_OK) preparar_kaggle(avisar= FALSE)
  PARAM$kaggle$competencia <- Sys.getenv("KAGGLE_COMPETENCIA")

  setorder(tb_prediccion, -prob)
  dir.create("kaggle", showWarnings= FALSE)
  subidos <- c()

  for (envios in PARAM$kaggle$cortes) {
    tb_prediccion[, Predicted := 0L]
    tb_prediccion[1:envios, Predicted := 1L]

    archivo_kaggle <- paste0("./kaggle/KA", PARAM$experimento, "_",
      "s", length(PARAM$FT$semillas), "_", envios, ".csv")
    marca <- paste0(archivo_kaggle, ".subido")
    if (file.exists(marca)) { loguear("ya subido:", archivo_kaggle); next }

    fwrite(tb_prediccion[, list(numero_de_cliente, Predicted)], file= archivo_kaggle, sep= ",")
    if (!KAGGLE_OK) { loguear("sin Kaggle: queda", archivo_kaggle, "para subir a mano"); next }

    linea <- paste(kaggle_bin, "competitions submit",
      "-c", PARAM$kaggle$competencia,
      "-f", archivo_kaggle,
      paste0("-m 'envios=", envios, "  semilla=", PARAM$semilla_primigenia, "'"))
    Sys.sleep(30)
    salida <- suppressWarnings(system(linea, intern= TRUE))
    cat(salida, "\n")
    if (is.null(attr(salida, "status"))) {
      writeLines(c(format(Sys.time()), salida), marca)
      subidos <- c(subidos, envios)
    } else {
      loguear("FALLO la subida de", archivo_kaggle, ":", paste(salida, collapse= " "))
    }
  }
  resumen <- paste0("Subidos a Kaggle en esta corrida: ",
    if (length(subidos)) paste(subidos, collapse= ", ") else "ninguno nuevo")
  fin_etapa(resumen)

} else {
  etapa("ganancia en 202107")
  setorder(tb_prediccion, -prob)
  tb_prediccion[, ganancia := ifelse(clase_ternaria == "BAJA+2",
    PARAM$ganancia$acierto, PARAM$ganancia$error)]
  tb_prediccion[, ganancia_acum := cumsum(ganancia)]

  tb_ganancia <- data.table(envios= PARAM$kaggle$cortes,
    ganancia= tb_prediccion$ganancia_acum[PARAM$kaggle$cortes])
  envios_max <- which.max(tb_prediccion$ganancia_acum)
  tb_ganancia <- rbind(tb_ganancia,
    data.table(envios= envios_max, ganancia= tb_prediccion$ganancia_acum[envios_max]))
  fwrite(tb_ganancia, "ganancia_202107.txt", sep= "\t")

  resumen <- paste0("Ganancia en 202107 por cantidad de envios:\n",
    paste(sprintf("%6d  %s", tb_ganancia$envios,
      formatC(tb_ganancia$ganancia, format= "d", big.mark= ".")), collapse= "\n"),
    "\n(la ultima fila es el maximo de la curva, que no se conoce de antemano)")
  fin_etapa(resumen)
}

etapa("fin")
# --- z635 celda 119 ---
# grabo los parametros
if( !require("yaml")) install.packages("yaml")
require("yaml")

write_yaml( PARAM, file="PARAM.yml")


# REGISTRO de la corrida: lo mismo va al mail final y a registro.txt
# el ruido sale del log, asi tambien aparece si la corrida retomo despues de la genetica
ruido_genetica <- function() {
  if (!file.exists(ARCH_GA_LOG)) return("sin medir")
  l <- fread(ARCH_GA_LOG, sep= "\t")[startsWith(formula, "RUIDO_")]
  if (nrow(l) < 2) return("sin medir")
  formatC(sd(l$ganancia), format= "d", big.mark= ".")
}

texto_registro_genetica <- function() {
  g <- ga_ganadoras()
  if (!nrow(g)) return(paste0(texto_ganadoras(), "\nNinguna variable genetica supero el ruido."))
  impo <- if (file.exists("impo.txt")) fread("impo.txt") else data.table(Feature= character())
  lineas <- sapply(seq_len(nrow(g)), function(i) {
    n <- g$nombre[i]
    derivadas <- grep(paste0("^", n, "(_|$)"), colnames(dataset), value= TRUE)
    puestos <- match(derivadas, impo$Feature)
    paste0("  ", n, " = ", g$formula[i], "\n",
      "    mejora en el fitness: ", formatC(g$mejora[i], format= "d", big.mark= "."), "\n",
      "    sobrevive a canaritos: ", if (n %in% colnames(dataset)) "si" else "no",
      " (columnas derivadas que quedan: ", if (length(derivadas)) paste(derivadas, collapse= ", ") else "ninguna", ")\n",
      "    puesto en la importancia del modelo final (de ", nrow(impo), "): ",
      if (length(derivadas)) paste(paste0(derivadas, " ", ifelse(is.na(puestos), "-", puestos)), collapse= ", ") else "-")
  })
  paste0(texto_ganadoras(), "\n\nGanadoras:\n", paste(lineas, collapse= "\n"),
    "\nRuido entre semillas del fitness (desvio): ", ruido_genetica())
}

horas <- as.numeric(difftime(Sys.time(), T_INICIO, units= "hours"))
texto <- function(x) paste(capture.output(print(x)), collapse= "\n")
seccion <- function(titulo, cuerpo) paste0("\n=== ", titulo, " ===\n", cuerpo, "\n")

registro <- paste0(
  "Experimento ", PARAM$experimento, ", grupo ", GRUPO, "\n",
  "Version del script: ", WF_VERSION, "\n",
  "Carpeta: ", carpeta_exp, "\n",
  "Terminado: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
  sprintf(" (esta sesion: %.1f h)", horas), "\n",
  seccion("Resultado", resumen),
  seccion("Linea de tiempo", paste0(
    "training ", min(PARAM$trainingstrategy$training), "-", max(PARAM$trainingstrategy$training),
    ", validate ", paste(PARAM$trainingstrategy$validate, collapse= " "),
    ", final_train ", min(PARAM$trainingstrategy$final_train), "-", max(PARAM$trainingstrategy$final_train),
    ", future ", paste(PARAM$trainingstrategy$future, collapse= " "))),
  seccion("Semillas", paste0("primigenia ", PARAM$semilla_primigenia,
    ", semillerio ", paste(PARAM$FT$semillas, collapse= ", "))),
  seccion("Variables geneticas", texto_registro_genetica()),
  seccion("Dataset final", paste0(nrow(dataset), " filas x ", ncol(dataset),
    " columnas; entrena con ", length(campos_buenos), " campos")),
  seccion("Optimizacion bayesiana", paste0("mejor AUC ", round(tb_bayesiana[1, y], 6),
    " de ", nrow(tb_bayesiana), " evaluaciones\n",
    "hiperparametros del modelo final:\n", texto(param_final))),
  seccion("Duracion de cada etapa (esta sesion)", texto(TIEMPOS)),
  seccion("PARAM completo (PARAM.yml)",
    if (file.exists("PARAM.yml")) paste(readLines("PARAM.yml"), collapse= "\n") else "no se grabo PARAM.yml"),
  seccion("Archivos en la carpeta", paste(list.files(".", recursive= TRUE), collapse= "\n"))
)
writeLines(registro, "registro.txt")

writeLines(format(Sys.time()), "TERMINADO")
mandar_mail("TERMINO", registro)
format(Sys.time(), "%a %b %d %X %Y")
