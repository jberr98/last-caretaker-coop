#!/usr/bin/env python3
"""
LC_Coop — Bot (jugador falso) para probar el relay con una sola PC.

Se conecta al servidor de coordinación y manda posiciones sintéticas (órbita).
El juego (con el sidecar en modo relay) verá al "otro jugador" orbitando.

Uso:
  python3 bot_client.py --server 127.0.0.1:27020 --origin 0,0,0
  # o, si tenés la posición del jugador real, pasala en --origin para que orbite ahí
"""

import argparse
import math
import os
import socket
import struct
import sys
import time
import uuid

POS = struct.Struct("<BffffI")

# Reusar el handshake del sidecar (HELLO/ACK) para que el juego lo confirme.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sidecar"))
from coop_net import PKT_ACK, PKT_HELLO, make_handshake, parse_handshake  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", required=True, help="host:puerto del relay")
    ap.add_argument("--origin", default="0,0,0", help="x,y,z centro de la órbita")
    ap.add_argument("--radius", type=float, default=400.0)
    ap.add_argument("--speed", type=float, default=0.3)
    ap.add_argument("--hz", type=float, default=20.0)
    args = ap.parse_args()

    host, _, port = args.server.rpartition(":")
    port = int(port) if port.isdigit() else 27020
    origin = [float(x) for x in args.origin.split(",")]

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", 0))
    sock.setblocking(False)
    client_id = "bot-" + uuid.uuid4().hex[:8]
    client_name = "lc-bot"
    t0 = time.time()
    seq = 0
    last_hello = 0.0
    print(f"[LC_Coop-bot] enviando a {host}:{port} (origen {origin}) "
          f"id={client_id}", flush=True)
    while True:
        t = time.time() - t0

        # Responder los HELLO del juego/sidecar (así el otro lado confirma ACK).
        while True:
            try:
                data, addr = sock.recvfrom(2048)
            except BlockingIOError:
                break
            except OSError:
                break
            if data and data[0] == PKT_HELLO:
                h = parse_handshake(data)
                if h:
                    try:
                        sock.sendto(make_handshake(PKT_ACK, client_id, client_name, h[1]), addr)
                    except OSError:
                        pass

        # HELLO propio cada 2 s (el relay lo reenvía al juego).
        if t - last_hello >= 2.0:
            last_hello = t
            try:
                sock.sendto(make_handshake(PKT_HELLO, client_id, client_name), (host, port))
            except OSError:
                pass

        ang = t * args.speed * 2 * math.pi
        x = origin[0] + args.radius * math.cos(ang)
        y = origin[1] + args.radius * math.sin(ang)
        z = origin[2]
        yaw = math.degrees(ang) % 360.0
        seq += 1
        pkt = POS.pack(1, x, y, z, yaw, seq & 0xFFFFFFFF)
        try:
            sock.sendto(pkt, (host, port))
        except OSError as e:
            print(f"[LC_Coop-bot] error: {e}", file=sys.stderr)
        time.sleep(1.0 / max(1, args.hz))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
