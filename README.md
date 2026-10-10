# workflow635

El Workflow 01 senior de la cátedra (`z635_WorkFlow_01_senior.ipynb`, sin
modificar) llevado a un script que corre desatendido en las VM Spot de la
cátedra, para los dos grupos del experimento colaborativo.

| | Grupo A | Grupo B |
|---|---|---|
| Validación de la BO | 202107 | 202105 |
| Final train | 201901 – 202107 | 201901 – 202105 |
| Predice | 202109 | 202107 |
| Testing | Kaggle (sube los cortes 8000 – 12000) | ganancia contra la clase real de 202107 |

## Qué cambia respecto del z635

Las funciones y celdas de la cátedra están copiadas **sin cambios** en
`635_workflow_senior.R`; cada bloque dice de qué celda viene. Lo agregado:

- **FE genético** (la consigna del FE intra-mes), después del FE intra-mes
  manual y antes del histórico:
  - `gramEvol` evoluciona fórmulas `v1 op v2` o `(v1 op v2) op v3` sobre los
    campos del mes, con `+ − × /`.
  - **Fitness:** cuánta ganancia agrega la fórmula a un LightGBM fijo, medida
    en el mes de validación del grupo (A: 202107, B: 202105), nunca en el de
    testing.
  - Por ronda se queda con la mejor fórmula **solo si mejora más que 2 desvíos
    del ruido entre semillas**; si no, corta. Cada ganadora entra como
    `gen_01`, `gen_02`... y después recibe lags, deltas y tendencia como
    cualquier campo.
  - Cada fórmula evaluada queda en `genetica_log.txt` (si la VM se corta,
    retoma sin volver a entrenar lo medido) y cada ronda en
    `genetica_rondas.txt`.
  - Mail en cada generación con las 10 mejores fórmulas, los segundos por
    fórmula y las horas usadas, y al terminar cada ronda.
  - **Tope de horas opcional** (`PARAM$GA$horas_max`, apagado por defecto):
    con un número, al llegar cierra la ronda con la mejor fórmula medida y
    sigue sola con el resto del workflow. El mail final dice, por variable ganadora, la fórmula, la mejora,
    si sobrevivió a canaritos y su puesto en la importancia del modelo final.
  - Los parámetros (`PARAM$GA$...`: rondas, población, generaciones, meses,
    LightGBM del fitness) están al principio del script.
- **Configuración en `.env`**: grupo, rutas, mail, Kaggle. Si falta una
  variable, corta al arrancar con su nombre.
- **Semillas fijas**: primigenia 100213, semillerio de 9:
  `100213, 100313, 100613, 100913, 101113` más 4 primos sorteados
  `570991, 669287, 832421, 882599` (en vez de 10 primos al azar).
- **Mail a una lista**: arranque, fin de cada etapa, cada N evaluaciones de la
  BO, error (con la etapa), fin, y si GCP expropia la VM. Un mail que falla no
  corta la corrida.
- **Registro de la corrida**: el mail final (y `registro.txt` en la carpeta)
  trae la versión del script (commit), grupo, línea de tiempo, semillas,
  tamaño del dataset final, mejor AUC y los hiperparámetros del modelo final,
  la duración de cada etapa, el `PARAM.yml` completo y la lista de archivos.
- **Checkpoints en el bucket**, para que una expropiación no pierda trabajo:

  | Qué | Archivo (en `exp/WF<experimento>/`) |
  |---|---|
  | dataset después del FE histórico | `checkpoints/dataset_fe_historico.fst` |
  | dataset después de canaritos | `checkpoints/dataset_canaritos.fst` |
  | cada punto del diseño inicial de la BO | `BO_init.txt` |
  | cada evaluación de la BO | `BO_iter.txt` |
  | estado de la BO en cada iteración | `HT.RDATA` |
  | un modelo final por semilla | `modelos/modelo_<semilla>.txt` |
  | cada archivo subido a Kaggle | `kaggle/*.csv.subido` |

  El z635 solo grababa la BO cada 600 s y nunca durante el diseño inicial (20
  entrenamientos): si se cortaba ahí, se perdía todo.

## Puesta en marcha

Una sola vez, en el bucket (nada de esto va al repo, que es público):

```sh
# app password de Gmail de la cuenta que manda (https://myaccount.google.com/apppasswords)
printf '%s' 'xxxxxxxxxxxxxxxx' | gsutil cp - gs://<bucket>/secrets/gmail_app_password
# destinatarios, uno por línea
gsutil cp destinatarios.txt gs://<bucket>/wf635/destinatarios.txt
# solo grupo A
gsutil cp kaggle.json gs://<bucket>/kaggle/kaggle.json
```

En el repo, desde Git Bash:

```sh
cp vm/vm.env.example vm/vm.env     # proyecto, zona, template, bucket
cp .env.example .env.A             # GRUPO=A, EXPERIMENTO, MAIL_FROM...
cp .env.example .env.B             # GRUPO=B, otro EXPERIMENTO
vm/lanzar.sh A
```

`lanzar.sh`:

1. chequea la cuota de vCPUs;
2. sube el script y el `.env` a `gs://<bucket>/wf635/<grupo>/`;
3. crea un template propio, copia del de la cátedra (misma máquina, disco,
   imagen, Spot) con `vm/startup.sh` y `vm/shutdown.sh`;
4. crea un **grupo administrado de una VM** (`wf635-a` / `wf635-b`).

**Si GCP expropia la VM**, llega un mail y el grupo crea otra sola, que
retoma desde el último checkpoint. No hay que hacer nada.

**Al terminar, o si R falla**, la VM espera 30 minutos y baja el grupo a 0,
así no se recrea (con `APAGAR_AL_TERMINAR=1`). Si R muere sin poder avisar
(por ejemplo, sin memoria), el startup manda el mail.

Para pararlo a mano: `vm/parar.sh A`. Para seguir después: `vm/lanzar.sh A`.

Log en vivo:

```sh
gsutil cat gs://<bucket>/wf635/A/log.txt | tail -50
```

## Las máquinas

Los templates de la cátedra están en el proyecto
(`gcloud compute instance-templates list`): Spot, n2 custom, de 128 a 512 GB,
con 8 o 12 vCPU, imagen `labo-family`. Los de la cátedra borran la VM al
expropiarse (`DELETE`), pero GCP no acepta eso en un grupo administrado: el
template propio usa `STOP`, y el grupo vuelve a arrancar la VM detenida.

Con una sola corrida a la vez conviene `TEMPLATE=to-128ram-12vcpu` en
`vm/vm.env`: usa los 12 vCPU de la cuota.

Detalles de la imagen que el script ya resuelve:

- el bucket lo monta gcsfuse para el usuario `ds` y **root no lo puede leer**:
  los scripts de la VM acceden como `ds`;
- gcsfuse sube un archivo recién al cerrarlo: el log se escribe en el disco
  local y se copia al bucket cada minuto;
- el Python es "externally managed" (PEP 668): el CLI de Kaggle se instala con
  `pip --user --break-system-packages`;
- desde Git Bash, `lanzar.sh` evita que las rutas del metadata se conviertan en
  rutas de Windows.

La cuota global de este proyecto es de **12 vCPUs**: dos VM de
`to-128ram-08vcpu` (8 + 8) no entran a la vez. `lanzar.sh` lo chequea antes
de crear nada.

## Primera corrida (WF9500, grupo A, 2026-10-10)

Corre en `to-128ram-12vcpu`. Tiempos medidos hasta la BO:

| Etapa | min |
|---|---|
| lectura + CA + drift + FE intra-mes | ~2 |
| FE genético | 11,4 |
| FE histórico | 6,1 |
| FE random forest | 3,1 |
| canaritos | 4,0 |

La genética evaluó 230 fórmulas distintas (~3 s cada una). La mejor,
`vm_mconsumosdolares * vmr_mpagado`, mejoró 2,26 M, por debajo del umbral de
5,7 M (2 desvíos de un ruido de 2,8 M): **ninguna variable genética quedó**.
El fitness barato y la búsqueda chica (600 contra 9.600 del default de
gramEvol) son lo primero a revisar.

Lo que la corrida confirmó: el uso de `gramEvol` (la fórmula llega a la
función de costo y el monitor por generación funciona), los checkpoints de
FE, el mail y la VM que retoma desde el bucket.

Pendiente:

- **El fitness de la genética.** Es un LightGBM de 200 árboles sobre una
  muestra sin lags: no está validado que prediga la ganancia del workflow
  completo. Opciones: validarlo pasando sus mejores fórmulas por el workflow
  entero, o un fitness más fiel (dataset completo, lags de la fórmula, varias
  semillas).
- **El tamaño de la búsqueda** (`PARAM$GA$poblacion`, `generaciones`), que
  con ~3 s por fórmula puede crecer mucho.
