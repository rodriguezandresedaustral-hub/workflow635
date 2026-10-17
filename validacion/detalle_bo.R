# ===========================================================================
# Detalle de la reevaluación de la BO (salida de reevaluar_bo.R): top de T07
# con sus hiperparámetros, en qué puesto de T07 caen las 7 mejores AUC de la
# BO, sesgo del ganador y relación de cada hiperparámetro con T07 y con V05.
#
#   Rscript detalle_bo.R <reevaluacion.csv>
# ===========================================================================
suppressPackageStartupMessages(library(data.table))
r <- fread(commandArgs(trailingOnly= TRUE)[1])
a <- r[, .(auc= mean(auc), meseta= mean(meseta)/1e6, sd= sd(meseta)/1e6), by= .(config, vista)]
w <- dcast(a, config ~ vista, value.var= c("auc","meseta","sd"))
p <- unique(r[, .(config, auc_bo, num_iterations, num_leaves, learning_rate, feature_fraction, min_sum_hessian_in_leaf)])
w <- merge(w, p, by= "config")
setorder(w, -meseta_T07)
cat("Top 12 por meseta T07 (M):\n")
print(w[1:12, .(config, auc_bo= round(auc_bo,5), V05= round(meseta_V05,1), V03= round(meseta_V03,1), T07= round(meseta_T07,1), sdT07= round(sd_T07,1),
  nit= num_iterations, hojas= num_leaves, lr= signif(learning_rate,3), ff= round(feature_fraction,2), msh= signif(min_sum_hessian_in_leaf,2))])
cat("\nTop 7 de la BO (config 1-7) en T07:\n")
print(w[config <= 7][order(config), .(config, auc_bo= round(auc_bo,5), T07= round(meseta_T07,1), puesto= match(config, w$config))])
cat(sprintf("Media T07 top7 BO %.1f  | media top7 de verdad %.1f | mediana 50 %.1f\n",
  w[config<=7, mean(meseta_T07)], mean(w$meseta_T07[1:7]), median(w$meseta_T07)))
# diferencia pareada config1 vs mejor de T07, por semilla
m <- w$config[1]
d <- dcast(r[vista=="T07" & config %in% c(1,m)], semilla ~ config, value.var= "meseta")
cat(sprintf("\nmejor T07 = config %d; diferencia con config 1 por semilla (M): %s\n", m, paste(round((d[[3]]-d[[2]])/1e6,1), collapse=" ")))
# sesgo de seleccion: max de 50 ruidosas. Simulacion: si las top 10 fueran iguales, cuanto daria el max?
set.seed(1); s <- w[1:10, mean(meseta_T07)]; sdm <- mean(w$sd_T07, na.rm=TRUE)/sqrt(2)
cat(sprintf("sd de la media de 2 semillas ~ %.1f M; max esperado de 10 iguales por puro ruido: +%.1f M\n", sdm,
  mean(replicate(5000, max(rnorm(10, 0, sdm))))))
cat("\nSpearman de cada hiperparametro con T07 y con AUC V05:\n")
for (h in c("num_iterations","num_leaves","learning_rate","feature_fraction","min_sum_hessian_in_leaf"))
  cat(sprintf("  %-24s T07 %5.2f   V05auc %5.2f\n", h, cor(w[[h]], w$meseta_T07, method="spearman"), cor(w[[h]], w$auc_V05, method="spearman")))
# cobertura de la meseta: envios del maximo por vista
cat("\nEnvios del maximo (mediana) por vista, top 10 de T07:\n")
print(r[config %in% w$config[1:10], .(envios_max_mediana= median(envios_max)), by= vista])
