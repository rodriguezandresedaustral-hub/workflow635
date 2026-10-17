# ¿El fitness distingue una formula de otra, o es ruido de la semilla?
#
#   Rscript analisis/ruido_fitness.R <archivo> [<archivo> ...]
#
# Acepta transferencia.txt (GA_MODO=transferencia) y prefiltro_medidas.txt
# (GA_BUSQUEDA=prefiltro): los dos tienen la misma formula medida con varias
# semillas de LightGBM. Por cada mes medido descompone la mejora en
#
#   mejora[formula, semilla] = efecto de la semilla + efecto de la formula + ruido
#
# El efecto de la semilla es la suerte de la base de esa semilla: mueve a todas
# las formulas juntas y no cambia el orden. Lo que importa para elegir es si el
# efecto de la formula (sd_senal) es grande contra el ruido de UNA medicion
# (sd_ruido). confiab_1_semilla = sd_senal^2 / (sd_senal^2 + sd_ruido^2): con 0
# la mejor de la busqueda es la de mejor suerte; p_hay_senal es el test F de
# que todas las formulas valen lo mismo.
suppressMessages(library(data.table))

descomponer <- function(d) {
  d[, n := .N, by= .(grupo, formula)]
  ns_max <- d[, max(n)]
  d <- d[n == ns_max & ns_max >= 2]
  if (!nrow(d)) return(data.table())
  d[, {
    nf <- uniqueN(formula); ns <- uniqueN(semilla)
    gm <- mean(mejora)
    fm <- tapply(mejora, formula, mean); sm <- tapply(mejora, semilla, mean)
    res <- mejora - fm[formula] - sm[as.character(semilla)] + gm
    ms_f <- ns * sum((fm - gm)^2) / (nf - 1)
    ms_e <- sum(res^2) / ((nf - 1) * (ns - 1))
    vs <- max(0, (ms_f - ms_e) / ns)
    .(formulas= nf, semillas= ns, sd_efecto_semilla= sd(sm), sd_ruido= sqrt(ms_e),
      sd_senal= sqrt(vs), confiab_1_semilla= vs / (vs + ms_e),
      p_hay_senal= pf(ms_f / ms_e, nf - 1, (nf - 1) * (ns - 1), lower.tail= FALSE))
  }, by= grupo]
}

for (arch in commandArgs(trailingOnly= TRUE)) {
  d <- fread(arch, sep= "\t")
  if ("tipo" %in% names(d)) {
    # transferencia.txt: la mejora es contra la BASE de la misma busqueda, mes y semilla
    b <- d[tipo == "BASE", .(busqueda, mes, semilla, base= ganancia)]
    d <- merge(d[tipo != "BASE"], b, by= c("busqueda", "mes", "semilla"))
    d[, mejora := ganancia - base]
    d <- d[mes != busqueda]
    d[, grupo := paste(busqueda, "->", mes)]
  } else {
    # prefiltro_medidas.txt: ya trae la mejora contra la base de su semilla
    d[, grupo := paste("ronda", ronda)]
  }
  d <- d[!is.na(mejora)]
  d[, mejora := mejora / 1e6]
  cat("==", arch, "(millones)\n")
  print(descomponer(d), digits= 2)
}
