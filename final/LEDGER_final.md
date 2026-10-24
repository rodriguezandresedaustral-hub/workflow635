# LEDGER — Final workflow (Workflow 01 senior, grupo A)

Append-only log. Never edit past entries; correct them with a new entry.
A new session reads **Current state** and **Next step** first.

## Goal

Using the teams' collaborative-experiment presentations (8 YouTube videos +
`Labo1_2026BA.pdf`), decide every workflow setting that is *not* chosen by the
Bayesian optimization (CA, drift, FE, canaritos, training strategy, final
training, cut), justify each decision with the evidence, and write the final
code. The final run uses a semillerio of 20-30 seeds so that a run can be
judged against seed noise.

## Sources

| Source | Status |
|---|---|
| `Labo1_2026BA.pdf` (212 pages, all teams) | pending |
| https://youtu.be/QPKILh78B2M | pending |
| https://youtu.be/WydrCFk7KPI | pending |
| https://www.youtube.com/watch?v=b8g3MyjanQY | pending |
| https://www.youtube.com/watch?v=suhOKzySp7o | pending |
| https://www.youtube.com/watch?v=wIMkbGxVVSc | pending |
| https://youtu.be/2AdendBbLD8 | pending |
| https://youtu.be/LLxaNl3mBLQ | pending |
| https://youtu.be/wA1junIwYrY | pending |
| `z635_WorkFlow_01_senior.ipynb` (verified == GitHub, blob c8426e9a) | read |
| `../PredFinal/z739_final_senior.ipynb` (cátedra's final notebook) | pending |

## Current state

Decisions written (table below). Notebook `635_WorkFlow_01_senior_final.ipynb`
built. Not run on GCP yet. The two fixes from the smoke test are not executed.

## Log

2026-10-24 — Ledger created. z635 verified identical to upstream GitHub
(blob c8426e9a). Tools available locally: python 3.10 + pymupdf, ffmpeg,
pdftotext. Not available: yt-dlp, whisper.

2026-10-24 — PDF read in full (text via pymupdf; 25 image-only slides
rendered and read). Pages 1-96 are template + cátedra examples from past
cohorts (no 2026 evidence). 2026 evidence by problem:

- **P4 FE histórico, grupo B (Morera, p.98-109)**: 5 configs × 10 seeds,
  measured on 202107, paired Wilcoxon. 9-month window with trend + ratios
  beats 6 months in 9/9 seeds (+3,5 M, p 0,004); beats "6 m. sin ratios"
  (+6,7 M, p 0,010). 9 vs 12 months: +0,4 M, p 1,0 (12 has higher max but
  more spread). Optimal cut most often 11.000; 1 in 3 above 12.000.
  Recommendation: window 9 with tendencia + ratios.
- **P4 FE histórico, grupo A (Zunino/Villalba, p.199-212)**: Study 1 (Kaggle
  public, unpaired, Holm/27): any history (B lags+deltas, C trend, D all,
  F deltas only) beats no history (p Holm 0,031); lags alone not significant.
  Study 2 (backtest 202107, 10 seeds, paired, Holm/15): FEATURE_ENG (trend +
  min/max/avg/ratios 6 m) 613,0 ≈ SIN_FOTO_MES 612,1 ≈ BO_GANANCIA 611,7;
  these beat PONDERACION (temporal weights 0,5→1), BO_AMPLIADA, LABEL_BAJA2
  (positives only BAJA+2): -10 to -14 M, p Holm 0,029. Kaggle public order
  differs completely (PONDERACION 1st, FEATURE_ENG last): public LB does not
  rank arms. Caveat: their BO validated on 202107 = backtest month.
- **P5 Training strategy, grupo A (Poletti/Fara, p.115-120)**: 10 setups,
  few seeds; recommend 2 validation months (202106-202107), rest training;
  dropping pandemic months does not help. Weak evidence (no test shown).
- **P5 Training strategy, grupo B (Martilotta, p.121-126)**: JUNIOR dataset,
  12 setups × 19 seeds, paired Wilcoxon on 202107. BO training on ONE month
  (202005: +1,60, 17/19, p<0,001; 202103: +1,41, 15/19, p 0,003; between them
  p 0,293) beats the full-history BO training. All others ≈ base. Note:
  only the BO training set changes; final_train stays 201901-202105.
- **P6 FE Random Forest, grupo A (Catalano/Chiacchio, p.128-146)**: 25 configs
  × 1 seed on Kaggle; "winner" 40/20/150/0,6. Own recommendation if no time:
  baseline 20/16/100/0,2.
- **P6 FE Random Forest, grupo B (Aznar, p.147-166)**: 37 full workflows on
  202107, paired. No arm differs from baseline (p 0,56-0,97); no-RF = same
  gain (+1,7 M, p 0,557) with 368 vs 415 columns and faster runs. The grupo A
  winner shrank from +7,7 M (6 seeds) to +3,0 M (10). Seed sd ≈ 14 M; same
  seed on another VM moved 15,5 M (LightGBM non-determinism → BO path).
  Cut: optimum 10.157-13.202; recommends cuts 10.000-14.000.
- **P7 FE intra-mes genetic, grupo A (Maceo/Rodriguez = us, p.167-193)**:
  genetic ≈ random formulas (5 versions, none beats random). Random formulas
  vs none: +2,85 M, 16/20, p 0,010 (3 formulas); 30 formulas +3,41 M; flat
  from 3 to 100. Workflow 635 with 12 seeds: removing canaritos +4,56 M,
  12/12, Holm 0,003 (only change that beat base). Temporal weights 0,95^k:
  -0,94 M, n.s. Negative bagging: wins July, loses May → rejected; keep
  standard final train. Ensemble of runs +2 to +5 M, saturates 5-10 runs.
  E11 (fixed originals + 500 formulas + their history) +17,7 M but 1 seed.
  Kaggle cut 11.000 (202109 ~18 % fewer bajas than 202107).
- **P7 grupo B (Eoin, p.194-198)**: 9 seeds of 635 with genetic: 0/27 rounds
  passed control. Ensemble of 9 runs by **averaging rankings** 592,9 M vs
  586,8 mean single seed; averaging probabilities gave 586,9 (no gain) — one
  measurement, no test. Best cut ≈ 11.000, flat 10.500-12.000. BO AUC vs
  gain r = -0,19.

2026-10-24 — Videos: yt-dlp captions (es, auto) for 7 of 8. **QPKILh78B2M
is unavailable** ("This video is not available": private or deleted); by
elimination it is P4 grupo B (Morera), whose slides are complete in the PDF.
What the videos add beyond the PDF:

- WydrCFk7KPI (P4A): no-history ≈ 391 pts public, lags+deltas 436, trend 418,
  deltas only 438, lags only 403. Same message as slides.
- wA1junIwYrY (P5A, JUNIOR dataset): validate 202106+202107 with 202105 as gap,
  training 201901-202104: 10/10 seeds, +2 pts, p 0,0029. Dropping 2020 7/10
  n.s.; 10-month validate p 0,076; 1-month train very bad.
- wIMkbGxVVSc (P5B, JUNIOR): with 10 seeds none of 6 variants differs (all
  p > 0,32); the two one-month BO-training arms were added later with 19
  seeds. His reading: one-month search picks smaller, less overfit models.
- suhOKzySp7o (P6A): Exp_4 vs base with 10 seeds, Wilcoxon p > 0,5. Advice:
  use baseline RF 20/16/100/0,2.
- LLxaNl3mBLQ (P6B): seed moves gain up to 46 M; "put the effort in the cut
  and the semillerío".
- b8g3MyjanQY (P7A, ours): says cut 12-13k; the slides (later) say 11-12k and
  Kaggle 11.000. Slides win.
- 2AdendBbLD8 (P7B, Eoin): seed spread ~19 M (3 %); BO picked 128 to 4.000+
  leaves; canaritos kept 2 to 497 vars; rank-average ensemble of 9 seeds
  592,9 vs 586,8; genetic = 70 % of runtime, 0/27 rounds passed.

2026-10-24 — z739_final_senior.ipynb (PredFinal) is identical to z635 except
one blank line → final code is built on z635. Read all 121 cells.
Random-formula generator from P7 (E2/E6) is NOT in this repo. Asked the user
whether E2/E6 formulas got history; user asked back whether I'm reading only
what they shared. Answered: P7 is pages 167-198 of the shared PDF and video
b8g3MyjanQY; besides the shared material I read z635/z739 (for the code) and
earlier FE_genetico.md + review.txt (local files, not used as evidence).

2026-10-24 — User: "check the repo on the link of the PDF". PDF p.189 links
github.com/rodriguezandresedaustral-hub/workflow635 (public). Read README,
RESULTADOS.md, brazos/README.md (HEAD 7bc1ee9) and the v2 code at f8d3b29
(where E2 lives). Facts from the code, not the slides:
- E2 (`GA_MODO=azar`, `GA_CON_HISTORIA` unset = 0): one random formula per
  round, 3 rounds, inserted right after `AgregarVariables_IntraMes` and BEFORE
  FE histórico → the formulas DID get lag1/2, delta1/2 and tend6 from the
  normal FE histórico step. RF and canaritos also ran in E2.
- Generator `ga_formulas_azar`: vars = numeric columns except
  numero_de_cliente and foto_mes; half `v1 op v2`, half `(v1 op v2) op v3`;
  ops + - * /; distinct; rejected if constant on the sample; Inf → NA,
  NaN → 0; own seed, restores the RNG.
- E2/E0 ran with HT_FIJO (BO of WF9600), final train 3 seeds at 20 % CONTINUA.
- E6 (30 random) .env is not in the repo history at f8d3b29; slides give its
  numbers. Assumed same mechanism with 30 rounds.
- RESULTADOS.md: E11 (originals + 500 formulas with history, 1 seed) needed
  ~476 GB RAM; with 512 GB it OOM'd. Group B dataset ≈ 50 GB in memory.

2026-10-24 — Built `635_WorkFlow_01_senior_final.ipynb` (z635 copy; z635
untouched, verified with git status) with `build_final.py` (scratchpad).
Ran a local smoke test on a 2 % client sample (114.601 rows, R fhistC
stand-in because local R has no Rtools). **The user then said: not run
locally, this runs in Google Cloud.** Local runs stopped; do not repeat.
What that smoke test had already found (both fixed in the notebook):
1. `foto_mes_formato_fecha` stays a `Date` when the dataset has no
   `cantidad_total_transacciones` (cátedra code). `ratioavg` divides by it →
   crash. Fix: `as.numeric` after the formulas (same value data.matrix gave).
2. Only 26 of 229 fields got `_tend9/_ratioavg9/_ratiomax9`: `TendenciaYmuchomas`
   adds columns with `:=` inside a function and once the data.table runs out
   of reserved column slots the new ones land on a local copy, silently.
   Fix: `setalloccol` at top level before the call, plus a check that stops
   the run if any history column is missing. **Fix not executed** (written
   after the stop). Whether the unmodified z635 also loses tend6 columns was
   being measured when the run was stopped: unknown.
Also: eval `corte_max` made robust (`[1]`). Kaggle-mode smoke never ran.
Full-data size from the column count: 232 base + 916 lags/deltas + 687
trend/ratios = 1.835 columns × 4,88 M rows × 8 B ≈ 72 GB, plus a final-train
matrix of similar size → ~140-150 GB peak (estimate, not measured).

2026-10-24 — Seeds. Primigenia 100213 drives everything: BO LightGBM seed,
20 % CONTINUA sample, formula draw. Final-train semillerío = z635 rule
(`sample(primes 100000-1000000)` after `set.seed(100213, "L'Ecuyer-CMRG")`),
first 30: 648289, 559093, 836183, 769147, 946919, 202627, 709237, 359783,
378583, 168541, 178001, 137957, 385199, 884743, 855331, 983617, 259933,
703699, 547559, 740011, 703321, 690997, 566161, 126653, 430739, 891707,
833477, 329657, 477209, 544889 (the first 10 are what z635 itself would use).
Same seeds in backtest and kaggle mode. Not the workflow635 fixed seeds
(100213, 100313, …). User chose to push notebook + ledger to workflow635.

2026-10-24 — Plots added (base R, png in the experiment folder + inline).
Backtest: gain curve 6.000-16.000 by 250 (each model grey, prob and rank
ensembles), per-model meseta vs reference bands, ensemble of first k; prints
the best cut and the cuts within 1 % of the max (`eval_curva.txt`). Kaggle:
cell that pulls public scores with `kaggle competitions submissions -v` and
plots them by cut, labelled as a file check, not a selector. Syntax checked
with R `parse()` only (nothing executed). Pushed to workflow635 as a PR.

**How the one Kaggle submission is chosen:** the cut comes from the backtest
ensemble curve (where its plateau is), not from the public LB. Default 11.000;
move it only if the backtest plateau clearly sits elsewhere, remembering
202109 has ~18 % fewer bajas than 202107 (P7), so the 202109 optimum is lower
than the 202107 one.

## Decisions (and why)

Evidence rule: a setting changes from z635 only if a 2026 team measured it
with several seeds and a paired test, on the senior dataset. Otherwise z635
stays as the cátedra wrote it.

| # | Stage | Decision | Evidence |
|---|---|---|---|
| 1 | CA | `MachineLearning` (unchanged) | No 2026 team measured CA (P1 pages are past-cohort templates) |
| 2 | DR | `deflacion` (unchanged) | No 2026 team measured drift on the senior dataset (P2 pages are templates) |
| 3 | FE intra | cátedra variables + **30 random formulas**, created before FE histórico | P7 E2−E0 +2,85 M, 16/20, p 0,010; E6 (30) +3,41 M; flat from 3 to 100 |
| 4 | FE hist | lag1, lag2, delta1, delta2 (unchanged) + **window 9, tendencia + ratioavg + ratiomax** (min/max/avg off) | P4B: 9 m beats 6 m 9/9 (p 0,004), beats 6 m without ratios (p 0,010); 9 ≈ 12 m but 9 steadier. P4A: deltas are what matters most (keep) |
| 5 | FE RF | **off** | P6B: no-RF = baseline (+1,7 M, p 0,557), fewer columns, faster; no config beats baseline |
| 6 | Canaritos | **off** | P7 workflow 635: E5−E0 +4,56 M, 12/12, Holm 0,003 (strongest result in the whole set) |
| 7 | Training strategy (BO) | unchanged: training 201901-202105 at 20 % CONTINUA, validate 202107 | P5 is on the JUNIOR dataset and contradicts itself: P5A's winner (validate 2 months) is WF9101 in P5B's 19-seed test, p 0,86. P5B's one-month training never tested on senior |
| 8 | BO | unchanged: AUC, 30 iterations, 5 hyperparameters | P4A: BO_AMPLIADA (60 it, 9 hp) lost −11,5 M (Holm 0,029); BO on gain tied |
| 9 | Target / weights | positives BAJA+1 + BAJA+2, no temporal weights, foto_mes kept (unchanged) | P4A: LABEL_BAJA2 and PONDERACION lost (Holm 0,029); P7 E9 0,95^k n.s.; SIN_FOTO_MES tied |
| 10 | Final train | unchanged: 201901-202107, all CONTINUA | P7 lab: negative bagging won July, lost May → rejected |
| 11 | Semillerío | **30 models** (user asked 20-30); resumable, usable from 20 | P7/Eoin: ensembling +2 to +6 M, saturates at 5-10; 30 gives the per-model distribution |
| 12 | Ensemble | probability average for the submit (z635); rank average computed alongside | Eoin rank 592,9 vs prob 586,9 is one measurement; P7 prob-average ensembles also gained (591,0). Backtest mode measures both |
| 13 | Cut | Kaggle files 9.000-13.000 by 500; **final pick 11.000** | 202107 optimum 11-12k (P4B, P6B, Eoin, P7); 202109 has ~18 % fewer bajas (P7) |
| 14 | Judging a run | `PARAM$modo = "backtest"`: grupo B timeline (predict 202107), per-model and ensemble meseta 8.000-12.000 | P7/P6B: the public LB cannot rank runs; 202107 meseta references: single model 582-587 M, ensemble 589-593 M |

Risk not measured: RAM. Estimated ~1.850 columns × 4,88 M rows × 8 B ≈ 72 GB
for the dataset, plus ~67 GB for the final-train matrix → over 128 GB. To be
confirmed with the column count from a smoke test before choosing the VM.

## Discarded / do not repeat

(none yet)

## Next step

On GCP, VM with ≥ 256 GB (estimate ~150 GB peak): run `PARAM$modo <-
"backtest"` first (WF9701). Check the output line "FE historico completo"
and the "columnas" line, time the first 2 final-train models before
committing to 30. If the ensemble meseta is in the 589-593 M band, run
`"kaggle"` (WF9700) and submit 11.000.

## Open questions

- ~~z635 or z739?~~ Same notebook; built on z635.
- Does the unmodified z635 lose `_tend6` columns too? If yes, every team's
  "tendencia" results measured a partial trend set.
- E6 (30 random formulas) .env not found in repo history; mechanism assumed
  equal to E2.
