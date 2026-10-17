# ===========================================================================
# ¿La diferencia entre brazos sobrevive al ruido del mes de testing?
#
#   Rscript bootstrap_brazos.R <validacion_curvas_dir> [brazo_base]
#
# Usa curvas_202107.csv y bootstrap_202107.csv (de curvas_202107.R). En cada
# réplica del bootstrap de clientes de 202107 promedia la meseta de las
# semillas que tienen los dos brazos y toma la diferencia contra el brazo
# base. Esto suma las dos fuentes de ruido: el Wilcoxon entre semillas solo ve
# el de la semilla, y el bootstrap con una sola semilla solo ve el del mes.
# El IC sale de remuestrear semillas y clientes a la vez.
# ===========================================================================
suppressPackageStartupMessages(library(data.table))
args <- commandArgs(trailingOnly= TRUE)
dir <- args[1]
tab  <- fread(file.path(dir, "curvas_202107.csv"), colClasses= list(character= c("exp", "semilla")))
boot <- fread(file.path(dir, "bootstrap_202107.csv"))
boot <- merge(boot, tab[, .(corrida, exp, semilla)], by= "corrida")
base <- if (length(args) >= 2) args[2] else min(tab$exp)
set.seed(7)
for (e in setdiff(sort(unique(tab$exp)), base)) {
  sem <- intersect(tab[exp == e, semilla], tab[exp == base, semilla])
  d <- dcast(boot[exp %in% c(e, base) & semilla %in% sem], b + semilla ~ exp, value.var= "meseta")
  d[, dif := get(e) - get(base)]
  obs <- tab[exp == e & semilla %in% sem][order(semilla), meseta] - tab[exp == base & semilla %in% sem][order(semilla), meseta]
  # solo clientes: misma lista de semillas en cada réplica
  solo_mes <- d[, .(m= mean(dif)), by= b]$m
  # semillas y clientes: en cada réplica, además, se remuestrean las semillas
  ambos <- d[, .(m= mean(sample(dif, replace= TRUE))), by= b]$m
  cat(sprintf("WF%s - WF%s (%d semillas): diferencia de meseta observada %.2f M\n", e, base, length(sem), mean(obs) / 1e6))
  cat(sprintf("   ruido de semillas solo (error estandar t): %.2f M -> IC95 [%.2f; %.2f]\n",
    sd(obs) / sqrt(length(obs)) / 1e6, (mean(obs) - 1.96 * sd(obs) / sqrt(length(obs))) / 1e6, (mean(obs) + 1.96 * sd(obs) / sqrt(length(obs))) / 1e6))
  cat(sprintf("   ruido del mes solo (bootstrap clientes): sd %.2f M -> IC95 [%.2f; %.2f], P(dif>0) %.2f\n",
    sd(solo_mes) / 1e6, quantile(solo_mes, .025) / 1e6, quantile(solo_mes, .975) / 1e6, mean(solo_mes > 0)))
  cat(sprintf("   semillas + mes: sd %.2f M -> IC95 [%.2f; %.2f], P(dif>0) %.2f\n",
    sd(ambos) / 1e6, quantile(ambos, .025) / 1e6, quantile(ambos, .975) / 1e6, mean(ambos > 0)))
}
