# Pasa el notebook final a un .R para la VM del launcher de workflow635:
# solo cambian las rutas (/content -> bucket montado), el modo y una marca
# TERMINADO al final, que es lo que vm/startup.sh espera para no relanzar.
import json, sys

NB, OUT, MODO = sys.argv[1], sys.argv[2], sys.argv[3]
B = "/home/ds/buckets/b1"
nb = json.load(open(NB, encoding="utf-8"))
code = "\n\n".join("".join(c["source"]) for c in nb["cells"] if c["cell_type"] == "code")

def sub(old, new):
    global code
    assert code.count(old) == 1, (old, code.count(old))
    code = code.replace(old, new)

sub('"/content/buckets/b1/exp"', f'"{B}/exp"')
sub('paste0("/content/buckets/b1/exp/", experimento_folder )', f'paste0("{B}/exp/", experimento_folder )')
sub('paste0("/content/datasets/", PARAM$dataset)', f'paste0("{B}/datasets/", PARAM$dataset)')
sub('PARAM$modo <- "kaggle"', f'PARAM$modo <- "{MODO}"')

code = ("# Generado desde 635_WorkFlow_01_senior_final.ipynb por make_vm_script.py\n"
        f"# modo {MODO}. No editar a mano: editar el notebook y regenerar.\n\n"
        + code + '\n\nfile.create("TERMINADO")\n')
open(OUT, "w", encoding="utf-8", newline="\n").write(code)
print("ok", MODO)
