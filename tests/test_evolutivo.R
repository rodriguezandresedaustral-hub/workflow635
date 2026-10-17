# Prueba chica del FE evolutivo con un dataset sintetico (segundos, no datos reales):
#   Rscript tests/test_evolutivo.R 635_workflow_senior.R
# Saca del script el bloque del evolutivo (entre "ARCH_EV_GEN <-" y el
# comentario de Kaggle) a un archivo temporal, lo carga con source() y lo
# corre con stubs de PARAM, loguear y mandar_mail.
suppressMessages({ library(data.table); library(lightgbm) })
args <- commandArgs(trailingOnly= TRUE)
script <- normalizePath(if (length(args)) args[1] else "635_workflow_senior.R")
lin <- readLines(script)
desde <- grep("^ARCH_EV_GEN <- ", lin)
hasta <- grep("^# GRUPO A: Kaggle se prepara", lin) - 1
stopifnot(length(desde) == 1, length(hasta) == 1, hasta > desde)

dir <- tempfile("ev_test_"); dir.create(file.path(dir, "checkpoints"), recursive= TRUE); setwd(dir)
bloque <- file.path(dir, "bloque_evolutivo.R")
writeLines(lin[desde:hasta], bloque)

loguear <- function(...) cat(format(Sys.time(), "%H:%M:%S"), "|", ..., "\n")
MAILS <- 0; mandar_mail <- function(...) MAILS <<- MAILS + 1
GRUPO <- "B"
PARAM <- list(semilla_primigenia= 100213, ganancia= list(acierto= 975000, error= -25000),
  BO= list(ht_fijo= ""), GA= list(modo= "evolutivo"),
  EV= list(seleccion= "importancia", generaciones= 4L, tope= 0L, hijos= 1, clones= 0.1, presion= 10,
           semillas_n= 1L, alfa= 0.95, borrar_muertas= TRUE, valida= 202101L, ventana= 3L,
           undersampling= 0.5, param_bo= TRUE, mail_cada_gen= 1,
           lgb_param= list(objective= "binary", num_iterations= 30, learning_rate= 0.1, num_leaves= 15,
             min_data_in_leaf= 20, feature_fraction= 0.8, max_bin= 31, force_row_wise= TRUE,
             deterministic= TRUE, verbosity= -100, num_threads= 2)))
source(bloque)

# dataset: 7 meses x 3000 clientes, 20 variables; la BAJA depende de v1*v2 y v3/v4
set.seed(1)
meses <- c(202007:202012, 202101)
dataset <- rbindlist(lapply(meses, function(m) {
  d <- data.table(numero_de_cliente= 1:3000, foto_mes= m)
  for (j in 1:20) d[, (paste0("v", j)) := rnorm(.N)]
  d[, v20 := 0]                          # constante: no tiene que romper nada
  d[sample(.N, 50), v5 := NA]            # NA
  z <- d$v1 * d$v2 + d$v3 / (abs(d$v4) + 0.5)
  p <- plogis(-4 + 1.5 * z)
  d[, clase_ternaria := ifelse(runif(.N) < p, ifelse(runif(.N) < 0.5, "BAJA+2", "BAJA+1"), "CONTINUA")]
  d
}))
dataset[, azar := runif(.N)]
originales <- paste0("v", 1:20)
dataset0 <- copy(dataset)

res <- correr_evolutivo()
cat(res, "\n")
gen <- fread(ARCH_EV_GEN)
nac <- fread(ARCH_EV_NAC)
pob <- fread(ARCH_EV_POB)
ok <- function(cond, msg) { cat(if (isTRUE(cond)) "OK   " else "FALLA", msg, "\n"); if (!isTRUE(cond)) quit(status= 1) }
ok(nrow(gen) == 5, "una fila por generacion (0..4)")
ok(all(gen$poblacion[-1] == 20), "la poblacion queda en el tope (20) todas las generaciones")
ok(all(gen$candidatos[-1] > 20), "nacen hijos y la poblacion crece antes de la muerte")
ok(sum(gen$nacidas) == max(gen$nacidas_acumuladas), "conteo de formulas nacidas")
ok(any(gen$clones > 0), "hay clones")
ok(all(grepl("\\+ cero$|\\* uno$", nac[padre2 %in% c("cero", "uno"), formula])), "clones X+cero / X*uno")
ok(max(gen$prof_max) >= 2, "hay recombinacion entre generaciones (profundidad >= 2)")
ok(nrow(pob) == 20, "evolutivo_poblacion.txt con 20 filas")
gen_vivas <- pob[original == FALSE, nombre]
ok(all(gen_vivas %in% names(dataset)), "las generadas vivas estan en el dataset")
muertas <- setdiff(originales, pob$nombre)
ok(!any(muertas %in% names(dataset)), "las originales muertas salieron del dataset")
f <- pob[original == FALSE][1]
if (nrow(f)) ok(isTRUE(all.equal(dataset[[f$nombre]], ev_evaluar(f$formula, dataset0))), "formula recalculada en el dataset entero")
ok(MAILS == 4, "un mail por generacion")
ok(inherits(try(ev_evaluar("system('ls')", dataset), silent= TRUE), "try-error"), "ev_evaluar no ejecuta codigo")

# retomar: con el checkpoint en la ultima generacion no reentrena nada
n_gen <- nrow(gen)
dataset <- copy(dataset0)
correr_evolutivo()
ok(nrow(fread(ARCH_EV_GEN)) == n_gen, "retomar desde el checkpoint no repite generaciones")

# seleccion al azar corre igual
unlink(c(ARCH_EV_GEN, ARCH_EV_NAC, ARCH_EV_POB, CK_EV))
PARAM$EV$seleccion <- "azar"; PARAM$EV$generaciones <- 2L
dataset <- copy(dataset0)
correr_evolutivo()
ok(nrow(fread(ARCH_EV_GEN)) == 3, "EV_SELECCION=azar")
cat("TODO OK\n")
