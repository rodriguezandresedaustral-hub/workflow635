# ===========================================================================
# ¿Cuánto ruido tiene la ganancia con la que comparamos corridas?
#
# Lee el prediccion.txt de corridas del grupo B ya terminadas (202107, con la
# clase real) y mide, sin entrenar nada:
#   1. el ruido entre semillas del máximo de la curva y de la meseta;
#   2. el intervalo bootstrap de la ganancia de UNA corrida (remuestreando
#      clientes de 202107: el ruido del mes de testing, que el Wilcoxon entre
#      semillas no ve);
#   3. el optimismo del máximo (se elige mirando la respuesta) y qué tan
#      estable es el corte óptimo;
#   4. un "public" simulado: 202107 partido 30/70 al azar como el LB de
#      Kaggle. ¿El public ordena las corridas como el private? ¿Acierta el
#      signo de la diferencia entre dos brazos?
#
# Uso (en la VM, como ds):
#   Rscript curvas_202107.R <salida_dir> <dataset.csv.gz> <carpeta_WF> [<carpeta_WF> ...]
# o con un glob: Rscript curvas_202107.R out dataset.csv.gz '/home/ds/buckets/b1/exp/WF990[0-4]_s*'
# Cada carpeta necesita prediccion.txt (numero_de_cliente, prob). El brazo y
# la semilla salen del nombre (WF<exp>_s<semilla>).
# ===========================================================================
suppressPackageStartupMessages(library(data.table))

args <- commandArgs(trailingOnly= TRUE)
if (length(args) < 3) stop("uso: Rscript curvas_202107.R <salida_dir> <dataset.csv.gz> <carpeta_WF>...")
SALIDA  <- args[1]
DATASET <- args[2]
carpetas <- unlist(lapply(args[-(1:2)], Sys.glob))
carpetas <- carpetas[file.exists(file.path(carpetas, "prediccion.txt"))]
dir.create(SALIDA, showWarnings= FALSE, recursive= TRUE)

MES       <- 202107
ACIERTO   <- 975000
ERROR     <- -25000
CORTES    <- seq(8000, 12000, by= 500)
B_BOOT    <- as.integer(Sys.getenv("B_BOOT", "500"))
R_PUBLIC  <- as.integer(Sys.getenv("R_PUBLIC", "500"))
PCT_PUB   <- 0.3
set.seed(17)

salida <- file(file.path(SALIDA, "curvas_202107.txt"), "w")
say <- function(...) { txt <- paste0(...); cat(txt, "\n"); writeLines(txt, salida) }
M <- function(x) formatC(x / 1e6, format= "f", digits= 2, big.mark= ".", decimal.mark= ",")

# --- clase real de 202107 --------------------------------------------------
clase <- fread(DATASET, select= c("numero_de_cliente", "foto_mes", "clase_ternaria"))[foto_mes == MES]
clase[, g := ifelse(clase_ternaria == "BAJA+2", ACIERTO, ERROR)]
n_b2 <- clase[clase_ternaria == "BAJA+2", .N]
say("Mes ", MES, ": ", nrow(clase), " clientes, ", n_b2, " BAJA+2 (", round(100 * n_b2 / nrow(clase), 3), "%)")

# --- predicciones: una columna por corrida --------------------------------
nombre <- basename(carpetas)
corridas <- data.table(corrida= nombre,
  exp= sub("^WF([0-9]+).*", "\\1", nombre),
  semilla= ifelse(grepl("_s[0-9]+$", nombre), sub(".*_s([0-9]+)$", "\\1", nombre), NA))
P <- clase[, .(numero_de_cliente, g)]
for (i in seq_along(carpetas)) {
  p <- fread(file.path(carpetas[i], "prediccion.txt"), select= c("numero_de_cliente", "prob"))
  setnames(p, "prob", nombre[i])
  P <- merge(P, p, by= "numero_de_cliente", all.x= TRUE)
}
stopifnot(!anyNA(P))
say("Corridas: ", nrow(corridas), "  (", paste(names(table(corridas$exp)), table(corridas$exp), sep= ":", collapse= " "), ")\n")

# ganancia acumulada con pesos por cliente (w = 1: la curva tal cual;
# w Poisson(1): un bootstrap; w 0/1: un subconjunto). El corte N se cuenta en
# clientes pesados, re-escalado a la población entera con `escala`.
curva <- function(prob, g, w= NULL, escala= 1) {
  o <- order(prob, decreasing= TRUE)
  if (is.null(w)) w <- rep(1, length(g))
  cw <- cumsum(w[o]) / escala
  cg <- cumsum(w[o] * g[o]) / escala
  list(cw= cw, cg= cg)
}
resumen <- function(cv) {
  en_corte <- sapply(CORTES, function(k) cv$cg[max(1, findInterval(k, cv$cw))])
  imax <- which.max(cv$cg)
  c(meseta= mean(en_corte), maximo= cv$cg[imax], envios_max= cv$cw[imax], setNames(en_corte, CORTES))
}

# --- 1. ruido entre semillas y optimismo del máximo -----------------------
tab <- rbindlist(lapply(corridas$corrida, function(r) as.list(resumen(curva(P[[r]], P$g)))))
tab <- cbind(corridas, tab)
fwrite(tab, file.path(SALIDA, "curvas_202107.csv"))
say("1. Por brazo (millones): media y desvío entre semillas")
por_exp <- tab[, .(n= .N, meseta= mean(meseta), sd_meseta= sd(meseta), maximo= mean(maximo),
                   sd_maximo= sd(maximo), optimismo= mean(maximo - meseta),
                   envios_max_med= median(envios_max), envios_max_min= min(envios_max),
                   envios_max_max= max(envios_max)), by= exp]
for (i in seq_len(nrow(por_exp))) with(por_exp[i], say(sprintf(
  "  WF%s n=%2d  meseta %s (sd %s)  maximo %s (sd %s)  maximo-meseta %s  envios del maximo: mediana %d [%d; %d]",
  exp, n, M(meseta), M(sd_meseta), M(maximo), M(sd_maximo), M(optimismo),
  as.integer(envios_max_med), as.integer(envios_max_min), as.integer(envios_max_max))))

# diferencias pareadas por semilla entre brazos: la relación señal/ruido de
# cada métrica (media de la diferencia / desvío de la diferencia)
say("\n   Diferencias pareadas contra el primer brazo (WF", tab$exp[1], "), por métrica:")
base <- tab[exp == min(exp)]
for (e in setdiff(unique(tab$exp), min(tab$exp))) {
  d <- merge(base, tab[exp == e], by= "semilla")
  if (nrow(d) < 3) next
  for (m in c("meseta", "maximo", "10000")) {
    x <- d[[paste0(m, ".y")]] - d[[paste0(m, ".x")]]
    say(sprintf("   WF%s - WF%s  %-7s n=%2d  media %7s  sd %6s  media/sd %5.2f  gana %d de %d  p Wilcoxon %.3f",
      e, min(tab$exp), m, length(x), M(mean(x)), M(sd(x)), mean(x) / sd(x), sum(x > 0), length(x),
      suppressWarnings(wilcox.test(x)$p.value)))
  }
}

# --- 2. bootstrap de clientes de 202107 -----------------------------------
# Poisson(1) por cliente, los mismos pesos para todas las corridas en cada
# réplica: así el bootstrap de una DIFERENCIA es pareado.
say("\n2. Bootstrap de clientes de 202107 (", B_BOOT, " réplicas, Poisson(1)): IC 95% de UNA corrida")
boot <- rbindlist(lapply(seq_len(B_BOOT), function(b) {
  w <- rpois(nrow(P), 1)
  rbindlist(lapply(corridas$corrida, function(r) {
    s <- resumen(curva(P[[r]], P$g, w))
    data.table(b= b, corrida= r, meseta= s[["meseta"]], maximo= s[["maximo"]], envios_max= s[["envios_max"]])
  }))
}))
fwrite(boot, file.path(SALIDA, "bootstrap_202107.csv"))
ej <- tab$corrida[1]
for (m in c("meseta", "maximo")) {
  q <- quantile(boot[corrida == ej][[m]], c(.025, .5, .975))
  say(sprintf("   %s %-6s observado %s  IC [%s; %s]  sd %s", ej, m, M(tab[corrida == ej][[m]]),
    M(q[1]), M(q[3]), M(sd(boot[corrida == ej][[m]]))))
}
q <- quantile(boot[corrida == ej]$envios_max, c(.025, .5, .975))
say(sprintf("   %s envios del maximo: observado %d, IC bootstrap [%d; %d]", ej,
  as.integer(tab[corrida == ej]$envios_max), as.integer(q[1]), as.integer(q[3])))
sd_boot <- boot[, .(sd_meseta= sd(meseta), sd_maximo= sd(maximo)), by= corrida]
say(sprintf("   sd bootstrap promedio entre corridas: meseta %s, maximo %s",
  M(mean(sd_boot$sd_meseta)), M(mean(sd_boot$sd_maximo))))
# una diferencia pareada típica (la primera pareja de brazos con la misma semilla)
pares <- merge(tab[exp == min(exp), .(semilla, a= corrida)], tab[exp != min(exp), .(semilla, b= corrida, exp)], by= "semilla")
if (nrow(pares)) {
  dd <- rbindlist(lapply(seq_len(nrow(pares)), function(i) {
    x <- boot[corrida == pares$b[i]]$meseta - boot[corrida == pares$a[i]]$meseta
    data.table(par= paste(pares$b[i], "-", pares$a[i]), sd= sd(x))
  }))
  say(sprintf("   sd bootstrap de la DIFERENCIA de meseta entre dos brazos con la misma semilla: mediana %s (%d pares)",
    M(median(dd$sd)), nrow(dd)))
}

# --- 3. el "public": 202107 partido 30/70 ----------------------------------
say("\n3. Public simulado: ", R_PUBLIC, " particiones al azar 30/70 de 202107 (escaladas a la población)")
sim <- rbindlist(lapply(seq_len(R_PUBLIC), function(r) {
  pub <- as.numeric(runif(nrow(P)) < PCT_PUB)
  rbindlist(lapply(corridas$corrida, function(cc) {
    a <- resumen(curva(P[[cc]], P$g, pub, PCT_PUB))
    b <- resumen(curva(P[[cc]], P$g, 1 - pub, 1 - PCT_PUB))
    data.table(r= r, corrida= cc, pub_meseta= a[["meseta"]], priv_meseta= b[["meseta"]],
               pub_maximo= a[["maximo"]], priv_maximo= b[["maximo"]])
  }))
}))
fwrite(sim, file.path(SALIDA, "public_simulado.csv"))
st <- sim[, .(rho= cor(pub_meseta, priv_meseta, method= "spearman"),
              acierta_mejor= corrida[which.max(pub_meseta)] == corrida[which.max(priv_meseta)],
              mejor_pub_en_priv= frank(-priv_meseta)[which.max(pub_meseta)]), by= r]
say(sprintf("   Spearman public vs private entre las %d corridas: mediana %.2f [p5 %.2f; p95 %.2f]",
  nrow(corridas), median(st$rho), quantile(st$rho, .05), quantile(st$rho, .95)))
say(sprintf("   La mejor del public es la mejor del private en el %.0f%% de las particiones; puesto mediano en el private: %d de %d",
  100 * mean(st$acierta_mejor), as.integer(median(st$mejor_pub_en_priv)), nrow(corridas)))
say(sprintf("   sd del public de una corrida entre particiones: meseta %s, maximo %s",
  M(sim[, sd(pub_meseta), by= corrida][, mean(V1)]), M(sim[, sd(pub_maximo), by= corrida][, mean(V1)])))
# signo de la diferencia entre brazos, por semilla, public vs private
if (nrow(pares)) {
  sg <- rbindlist(lapply(seq_len(nrow(pares)), function(i) {
    a <- sim[corrida == pares$a[i]]; b <- sim[corrida == pares$b[i]]
    data.table(r= a$r, par= i, exp= pares$exp[i], d_pub= b$pub_meseta - a$pub_meseta, d_priv= b$priv_meseta - a$priv_meseta)
  }))
  ag <- sg[, .(mismo_signo= mean(sign(d_pub) == sign(d_priv)), sd_dpub= sd(d_pub)), by= exp]
  for (i in seq_len(nrow(ag))) say(sprintf(
    "   WF%s - WF%s por semilla: el public acierta el signo del private en el %.0f%% de los casos; sd de la diferencia en el public %s",
    ag$exp[i], min(tab$exp), 100 * ag$mismo_signo[i], M(ag$sd_dpub[i])))
  # el promedio de las semillas (lo que mira el experimento de brazos)
  pm <- sg[, .(d_pub= mean(d_pub), d_priv= mean(d_priv)), by= .(exp, r)]
  ap <- pm[, .(mismo_signo= mean(sign(d_pub) == sign(d_priv)), sd_dpub= sd(d_pub)), by= exp]
  for (i in seq_len(nrow(ap))) say(sprintf(
    "   WF%s - WF%s promedio de semillas: el public acierta el signo en el %.0f%%; sd %s",
    ap$exp[i], min(tab$exp), 100 * ap$mismo_signo[i], M(ap$sd_dpub[i])))
}

# --- 4. ¿qué corte fijo conviene? -----------------------------------------
say("\n4. Ganancia promedio entre corridas por corte fijo (millones) y lo que se pierde contra el máximo de cada corrida")
for (k in CORTES) say(sprintf("   %6d envíos: %s  (máximo - corte: %s)", k,
  M(mean(tab[[as.character(k)]])), M(mean(tab$maximo - tab[[as.character(k)]]))))

close(salida)
cat("\nlisto:", SALIDA, "\n")
