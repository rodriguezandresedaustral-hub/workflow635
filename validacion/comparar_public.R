# ===========================================================================
# Public de Kaggle (grupo A, 202109) contra 202107 con la clase real (grupo B)
# para el mismo brazo y la misma semilla del pipeline.
#
#   Rscript comparar_public.R <kaggle_subs.csv> <brazos.csv> [pares]
#
# kaggle_subs.csv: lo que devuelve la API de Kaggle (fileName, publicScore);
#   los envíos de una corrida se llaman KA<exp>_s<semilla>_s3_<envios>.csv.
# brazos.csv: salida de brazos/analizar_brazos.R (brazo, semilla, meseta, ...,
#   carpeta), con la meseta de 202107 en pesos.
# pares: "experimento A=experimento B", por defecto "9910=9900,9912=9902"
#   (E0A con E0, E2A con E2).
# Para cada corrida calcula la meseta del public (promedio de los 9 cortes
# 8000-12000) y la compara con la meseta de 202107; después, la diferencia
# entre brazos por semilla: ¿el public y 202107 coinciden en el signo?
# ===========================================================================
suppressPackageStartupMessages(library(data.table))
args <- commandArgs(trailingOnly= TRUE)
k <- fread(args[1])
b <- fread(args[2])
pares <- strsplit(strsplit(if (length(args) >= 3) args[3] else "9910=9900,9912=9902", ",")[[1]], "=")

k <- k[grepl("^KA[0-9]+_s[0-9]+_s3_[0-9]+\\.csv$", fileName) & !is.na(publicScore)]
k[, `:=`(exp= sub("^KA([0-9]+)_.*", "\\1", fileName),
         semilla= sub("^KA[0-9]+_s([0-9]+)_.*", "\\1", fileName),
         envios= as.integer(sub(".*_([0-9]+)\\.csv$", "\\1", fileName)))]
pub <- k[envios %in% seq(8000, 12000, 500), .(public_meseta= mean(publicScore), n= .N,
          public_max= max(publicScore), envios_max= envios[which.max(publicScore)]), by= .(exp, semilla)]
b[, exp := sub(".*/WF([0-9]+)_s.*", "\\1", carpeta)]
b[, semilla := as.character(semilla)]

t <- rbindlist(lapply(pares, function(p)
  merge(pub[exp == p[1]], b[exp == p[2], .(semilla, b_exp= exp, brazo, meseta_202107= meseta / 1e6,
        envios_max_202107= envios_max)], by= "semilla")))
cat("Por corrida (millones):\n")
print(t[, .(exp_A= exp, exp_B= b_exp, brazo, semilla, n, public_meseta= round(public_meseta, 2),
            meseta_202107= round(meseta_202107, 2), envios_max_public= envios_max, envios_max_202107)])
cat(sprintf("\nPearson public vs 202107 entre las %d corridas: %.2f  (Spearman %.2f)\n",
  nrow(t), cor(t$public_meseta, t$meseta_202107), cor(t$public_meseta, t$meseta_202107, method= "spearman")))

if (length(pares) >= 2) {
  d <- merge(t[b_exp == pares[[1]][2]], t[b_exp == pares[[2]][2]], by= "semilla")
  d[, `:=`(d_public= public_meseta.y - public_meseta.x, d_202107= meseta_202107.y - meseta_202107.x)]
  cat(sprintf("\nDiferencia %s - %s por semilla (millones):\n", d$brazo.y[1], d$brazo.x[1]))
  print(d[, .(semilla, d_public= round(d_public, 2), d_202107= round(d_202107, 2),
              mismo_signo= sign(d_public) == sign(d_202107))])
  cat(sprintf("Coinciden en el signo en %d de %d semillas\n", d[, sum(sign(d_public) == sign(d_202107))], nrow(d)))
}
