# ===========================================================================
# Ensamble de semillerios: junta los prediccion.txt de varias corridas de
# semillerio.R y promedia todas las prob_<i> juntas. Cada modelo pesa lo
# mismo, asi que una corrida de 36 semillas pesa el triple que una de 12
# (a diferencia de ensamblar.R, que promedia la prob de cada corrida).
#
# uso:
#   Rscript ensamblar_semillas.R <carpeta salida> <corrida 1> <corrida 2> ...
#   Rscript ensamblar_semillas.R /home/ds/buckets/b1/exp/ENS_F4 \
#     /home/ds/buckets/b1/exp/WF9921 /home/ds/buckets/b1/exp/WF9922 ...
#
# graba <salida>/prediccion.txt y <salida>/kaggle/KA<nombre>_s<modelos>_<envios>.csv
# ===========================================================================
suppressMessages(library(data.table))

args <- commandArgs(trailingOnly= TRUE)
if (length(args) < 2) stop("uso: Rscript ensamblar_semillas.R <carpeta salida> <corrida 1> <corrida 2> ...")
SALIDA <- args[1]
CORRIDAS <- args[-1]
CORTES <- seq(8000, 12500, by= 500)
if (anyDuplicated(normalizePath(CORRIDAS, mustWork= FALSE))) stop("hay corridas repetidas")

tb <- NULL
modelos <- 0
for (carpeta in CORRIDAS) {
  archivo <- file.path(carpeta, "prediccion.txt")
  if (!file.exists(archivo)) stop("falta ", archivo, " (la corrida no termino?)")
  p <- fread(archivo)
  cols <- grep("^prob_", colnames(p), value= TRUE)
  p <- p[, list(numero_de_cliente, suma= rowSums(.SD)), .SDcols= cols]
  cat(carpeta, ":", length(cols), "modelos\n")

  if (is.null(tb)) {
    tb <- p
  } else {
    if (nrow(p) != nrow(tb) || !setequal(p$numero_de_cliente, tb$numero_de_cliente))
      stop(carpeta, " no predice los mismos clientes que las anteriores")
    tb[p, on= "numero_de_cliente", suma := suma + i.suma]
  }
  modelos <- modelos + length(cols)
}

tb[, prob := suma / modelos]
tb[, suma := NULL]
setorder(tb, -prob)

dir.create(file.path(SALIDA, "kaggle"), recursive= TRUE, showWarnings= FALSE)
fwrite(tb, file.path(SALIDA, "prediccion.txt"), sep= "\t")

nombre <- basename(SALIDA)
for (envios in CORTES) {
  tb[, Predicted := 0L]
  tb[1:envios, Predicted := 1L]
  fwrite(tb[, list(numero_de_cliente, Predicted)],
    file= file.path(SALIDA, "kaggle", paste0("KA", nombre, "_s", modelos, "_", envios, ".csv")),
    sep= ","
  )
}
cat(nrow(tb), "clientes,", modelos, "modelos. Cortes en", file.path(SALIDA, "kaggle"), "\n")
