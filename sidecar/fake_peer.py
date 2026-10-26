#!/usr/bin/env python3
"""
LC_Coop — fake peer (probar SOLO, con una sola instancia del juego)
===================================================================

Simula al "otro jugador" escribiendo <dir>/coords_in.txt (lo que normalmente
haría el sidecar al recibir UDP). No usa red. Sirve para validar:

  - que el mod Lua carga sin errores
  - que el ghost player spawnea y se mueve
  - que la sincronización de puertas aplica (con --event)

NO corras esto junto con coop_net.py: ambos escriben coords_in.txt.

Modos:
  orbit   el ghost orbita alrededor de tu posición (muy visual)
  mirror  el ghost aparece desplazado de tu posición
  static  el ghost queda fijo en una posición

Uso:
  python3 fake_peer.py --dir "<...>/Binaries/Win64" --mode orbit --radius 400
  python3 fake_peer.py --dir "<...>/Binaries/Win64" --mode mirror --offset 200,0,0
  python3 fake_peer.py --dir "<...>/Binaries/Win64" --event DOOR,NombrePuerta,1
"""

import argparse
import math
import os
import sys
import time


def read_coords(path):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            parts = f.read().strip().split(",")
        if len(parts) >= 3:
            return float(parts[0]), float(parts[1]), float(parts[2])
    except (FileNotFoundError, ValueError, OSError):
        pass
    return None


def write_text(path, text):
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except OSError:
        pass


def main():
    ap = argparse.ArgumentParser(description="LC_Coop fake peer (sin red)")
    ap.add_argument("--dir", required=True, help="carpeta Binaries/Win64 del juego")
    ap.add_argument("--mode", choices=["orbit", "mirror", "static"], default="orbit")
    ap.add_argument("--radius", type=float, default=400.0, help="radio de la órbita (unidades UE)")
    ap.add_argument("--speed", type=float, default=1.0, help="vueltas por segundo de la órbita")
    ap.add_argument("--offset", default="200,0,0", help="dx,dy,dz para el modo mirror")
    ap.add_argument("--pos", default="0,0,0", help="x,y,z para el modo static")
    ap.add_argument("--hz", type=float, default=20.0, help="frecuencia de escritura")
    ap.add_argument("--event", action="append", default=[],
                    help="evento a inyectar (ej. DOOR,NombrePuerta,1); repetible")
    ap.add_argument("--event-every", type=float, default=5.0, help="cada cuántos s reinyectar eventos")
    args = ap.parse_args()

    if not os.path.isdir(args.dir):
        print(f"[fake-peer] ERROR: no existe la carpeta: {args.dir}", file=sys.stderr)
        sys.exit(1)

    coords_out = os.path.join(args.dir, "coords_out.txt")
    coords_in = os.path.join(args.dir, "coords_in.txt")
    event_in = os.path.join(args.dir, "event_in.txt")

    offset = [float(x) for x in args.offset.split(",")]
    static_pos = [float(x) for x in args.pos.split(",")]

    print(f"[fake-peer] modo={args.mode} dir={args.dir}", flush=True)
    print("[fake-peer] asegurate de NO tener coop_net.py corriendo a la vez.", flush=True)

    seq = 0
    interval = 1.0 / max(0.1, args.hz)
    t0 = time.time()
    last_event = 0.0

    while True:
        t = time.time() - t0
        player = read_coords(coords_out) or (0.0, 0.0, 0.0)

        if args.mode == "mirror":
            x, y, z = player[0] + offset[0], player[1] + offset[1], player[2] + offset[2]
            yaw = 0.0
        elif args.mode == "static":
            x, y, z = static_pos
            yaw = 0.0
        else:  # orbit
            ang = t * args.speed * 2 * math.pi
            x = player[0] + args.radius * math.cos(ang)
            y = player[1] + args.radius * math.sin(ang)
            z = player[2]
            yaw = math.degrees(ang) % 360.0

        seq += 1
        write_text(coords_in, f"{x},{y},{z},{yaw},{seq}")

        if args.event and (t - last_event) >= args.event_every:
            last_event = t
            try:
                with open(event_in, "a", encoding="utf-8") as f:
                    for ev in args.event:
                        f.write(ev + "\n")
            except OSError:
                pass
            print(f"[fake-peer] eventos inyectados: {args.event}", flush=True)

        time.sleep(interval)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
