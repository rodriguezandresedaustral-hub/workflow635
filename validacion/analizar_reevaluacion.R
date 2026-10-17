# ===========================================================================
# Analiza la salida de reevaluar_bo.R: ¿qué criterio de validación predice
# mejor la ganancia en 202107?
#
#   Rscript analizar_reevaluacion.R <reevaluacion.csv> [salida.txt]
#
# Para cada configuración promedia las semillas y compara contra la meseta de
# T07 (la ganancia en 202107 con el final train de los brazos):
#   - Spearman de cada criterio contra T07;
#   - regret: cuánto se pierde en 202107 por elegir la mejor según el criterio
#     en vez de la mejor de verdad, y en qué puesto de T07 queda la elegida;
#   - ruido entre semillas dentro de cada vista.
# ===========================================================================
suppressPackageStartupMessages(library(data.table))
args <- commandArgs(trailingOnly= TRUE)
r <- fread(args[1])
out <- if (length(args) >= 2) file(args[2], "w") else stdout()
say <- function(...) writeLines(paste0(...), out)
M <- function(x) sprintf("%.2f", x / 1e6)

say("Filas: ", nrow(r), "  por vista y semilla:")
say(paste(capture.output(print(dcast(r, vista ~ semilla, fun.aggregate= length, value.var= "config"))), collapse= "\n"))

# --- ruido entre semillas ---------------------------------------------------
say("\nRuido entre semillas (misma configuración, distinta semilla):")
for (v in unique(r$vista)) {
  w <- dcast(r[vista == v], config ~ semilla, value.var= "meseta")
  if (ncol(w) < 3) next
  sds <- r[vista == v, .(sd= sd(meseta), sda= sd(auc)), by= config]
  say(sprintf("  %s  Spearman meseta semilla1 vs semilla2 %.2f   sd media de la meseta %s M   sd media de la AUC %.5f   rango de la meseta entre configs %s M",
    v, cor(w[[2]], w[[3]], method= "spearman", use= "complete.obs"), M(mean(sds$sd, na.rm= TRUE)),
    mean(sds$sda, na.rm= TRUE), M(diff(range(r[vista == v, mean(meseta), by= config]$V1)))))
}

# --- tabla ancha por config, promediando semillas ---------------------------
a <- r[, .(auc= mean(auc), meseta= mean(meseta), maximo= mean(maximo), auc_bo= auc_bo[1]), by= .(config, vista)]
w <- dcast(a, config + auc_bo ~ vista, value.var= c("auc", "meseta", "maximo"))
if (!"meseta_T07" %in% names(w)) stop("todavía no hay T07")
w <- w[!is.na(meseta_T07)]
crit <- list(
  "AUC de la BO original (202105, 1 semilla)"= w$auc_bo,
  "AUC 202105 (V05)"                          = w$auc_V05,
  "meseta 202105 (V05)"                       = w$meseta_V05,
  "maximo 202105 (V05)"                       = w$maximo_V05,
  "AUC 202103 (V03)"                          = w$auc_V03,
  "meseta 202103 (V03)"                       = w$meseta_V03,
  "meseta promedio 202103+202105"             = (w$meseta_V03 + w$meseta_V05) / 2,
  "AUC 202107 (T07, referencia)"              = w$auc_T07)
mejor <- max(w$meseta_T07)
say(sprintf("\n%d configuraciones con T07. Meseta 202107: mejor %s M, mediana %s M, peor %s M",
  nrow(w), M(mejor), M(median(w$meseta_T07)), M(min(w$meseta_T07))))
say(sprintf("La que eligió la BO (config 1, mejor AUC en 202105): meseta 202107 %s M, puesto %d de %d",
  M(w[config == 1]$meseta_T07), w[, frank(-meseta_T07)][w$config == 1], nrow(w)))
say("\nCriterio                                   n   Spearman vs meseta T07   elegida: meseta T07  puesto  regret   top5: meseta T07 media")
for (nm in names(crit)) {
  x <- crit[[nm]]; ok <- !is.na(x)
  if (sum(ok) < 5) next
  ww <- w[ok]; xx <- x[ok]
  el <- which.max(xx)
  top5 <- order(-xx)[1:5]
  say(sprintf("%-42s %2d   %6.2f                   %s          %3d    %6s   %s",
    nm, sum(ok), cor(xx, ww$meseta_T07, method= "spearman"), M(ww$meseta_T07[el]),
    frank(-ww$meseta_T07)[el], M(mejor - ww$meseta_T07[el]), M(mean(ww$meseta_T07[top5]))))
}
fwrite(w, sub("\\.csv$", "_por_config.csv", args[1]))
if (length(args) >= 2) close(out)
