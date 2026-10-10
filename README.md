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
con 8 o 12 vCPU, imagen `labo-family`. **Al expropiarse, la VM se borra**
(`instanceTerminationAction: DELETE`): por eso todo se guarda en el bucket y
el grupo administrado la recrea.

La cuota global de este proyecto es de **12 vCPUs**: dos VM de
`to-128ram-08vcpu` (8 + 8) no entran a la vez. `lanzar.sh` lo chequea antes
de crear nada.

## Sin probar todavía

Nada de esto corrió en una VM. El script se verificó solo con `parse()` de R
y los `.sh` con `bash -n`. La primera corrida es la prueba.
