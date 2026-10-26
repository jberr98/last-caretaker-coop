#!/usr/bin/env python3
"""
Fuerza el override 'dwmapi = native,builtin' en el prefix de Proton de Steam.

Sin esto, Proton carga su propia dwmapi.dll (builtin) y UE4SS nunca se inyecta
(no aparece UE4SS.log). Necesario solo en Linux/Proton; en Windows no hace falta.

Uso:
  python3 fix_proton_override.py                 # prefix por defecto (TLC)
  python3 fix_proton_override.py /ruta/al/pfx
"""

import os
import re
import shutil
import sys

DEFAULT_PFX = "~/.local/share/Steam/steamapps/compatdata/1783560/pfx"
LINE = '"dwmapi"="native,builtin"\n'


def main():
    pfx = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PFX)
    reg = os.path.join(pfx, "user.reg")
    if not os.path.isfile(reg):
        sys.exit(f"ERROR: no existe {reg}")

    with open(reg, encoding="utf-8", errors="surrogateescape") as f:
        text = f.read()

    if re.search(r'^"dwmapi"="', text, re.M):
        print("Ya estaba aplicado. Nada que hacer.")
        return

    shutil.copy2(reg, reg + ".lc_backup")

    lines = text.splitlines(keepends=True)
    out = []
    in_section = False
    inserted = False
    for line in lines:
        out.append(line)
        if re.match(r"\[Software\\+Wine\\+DllOverrides\]", line) and "AppDefaults" not in line:
            in_section = True
        elif in_section and line.startswith("#time="):
            out.append(LINE)
            inserted = True
            in_section = False

    if not inserted:
        out.append("\n[Software\\\\Wine\\\\DllOverrides]\n#time=0\n" + LINE)

    with open(reg, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write("".join(out))

    print(f"Override aplicado en {reg}")
    print(f"Backup: {reg}.lc_backup")


if __name__ == "__main__":
    main()
