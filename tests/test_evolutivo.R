# Prueba chica del FE evolutivo con un dataset sintetico (segundos, no datos reales):
#   Rscript tests/test_evolutivo.R 635_workflow_senior.R
# Saca del script el bloque del evolutivo (entre "ARCH_EV_GEN <-" y el
# comentario de Kaggle) y fganancia_lgbm_meseta (z635 celda 65) a archivos
# temporales, los carga con source() y los corre con stubs de PARAM, loguear
# y mandar_mail. PARAM$CN$train es el de la catedra (celda 67): la importancia
# sale del LightGBM de canaritos.
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
c65 <- grep("^# --- z635 celda 65 ---", lin); c66 <- grep("^# --- z635 celda 66 ---", lin)
stopifnot(length(c65) == 1, length(c66) == 1, c66 > c65)
bloque_cn <- file.path(dir, "celda65.R")
writeLines(lin[c65:(c66 - 1)], bloque_cn)

loguear <- function(...) cat(format(Sys.time(), "%H:%M:%S"), "|", ..., "\n")
MAILS <- 0; mandar_mail <- function(...) MAILS <<- MAILS + 1
GRUPO <- "B"
PARAM <- list(semilla_primigenia= 100213, ganancia= list(acierto= 975000, error= -25000),
  BO= list(ht_fijo= ""), GA= list(modo= "evolutivo"),
  EV= list(seleccion= "importancia", generaciones= 4L, tope= 0L, hijos= 1, clones= 0.1, presion= 10,
           semillas_n= 1L, borrar_muertas= TRUE, mail_cada_gen= 1),
  CN= list(train= list(clase01_valor1= c("BAJA+2", "BAJA+1"), positivos= c("BAJA+2"),
    training= c(202101, 202102, 202103), validation= c(202105), undersampling= 0.1,
    gan1= 0.975, gan0= -0.025)))
source(bloque_cn)
source(bloque)

# dataset: 6 meses x 3000 clientes, 20 variables; la BAJA depende de v1*v2 y v3/v4.
# Incluye los meses de canaritos (202101-202103 y 202105)
set.seed(1)
meses <- c(202012, 202101, 202102, 202103, 202104, 202105)
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
ok(all(gen$ganancia_meseta != 0), "la ganancia sale de la validation de canaritos (202105)")
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
