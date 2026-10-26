#!/usr/bin/env python3
"""
LC_Coop — Servidor de coordinación (relay UDP)
==============================================

Todos los jugadores se conectan HACIA el servidor (salida), y el servidor reenvía
los paquetes entre ellos. Así no importa que una máquina no acepte entrantes:
solo necesita poder salir al servidor.

Uso:
  python3 relay_server.py [PUERTO]        # default 27020

Protocolo: reenvía cada datagrama tal cual a los DEMÁS clientes.
(sin salas: una sola "sala" por instancia; corré varias instancias para varias)
"""

import os
import socket
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("PORT", "27020"))
TIMEOUT = int(os.environ.get("TIMEOUT", "30"))  # segundos sin actividad para olvidar un cliente


def log(msg):
    print(f"[LC_Coop-relay] {time.strftime('%H:%M:%S')} {msg}", flush=True)


def make_socket(port):
    try:
        s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        s.bind(("::", port))
        return s
    except OSError:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("0.0.0.0", port))
        return s


def main():
    sock = make_socket(PORT)
    clients = {}  # addr -> last_seen
    log(f"escuchando en :{PORT} (IPv4+IPv6)")

    while True:
        try:
            data, addr = sock.recvfrom(2048)
        except OSError:
            break
        if not data:
            continue

        now = time.time()
        is_new = addr not in clients
        clients[addr] = now
        if is_new:
            log(f"cliente conectado: {addr[0]}:{addr[1]}  (total={len(clients)})")

        # reenviar a los demás
        for c in list(clients.keys()):
            if c == addr:
                continue
            try:
                sock.sendto(data, c)
            except OSError:
                pass

        # limpiar clientes viejos
        for c in list(clients.keys()):
            if now - clients[c] > TIMEOUT:
                del clients[c]
                log(f"cliente expirado: {c[0]}:{c[1]}  (total={len(clients)})")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
