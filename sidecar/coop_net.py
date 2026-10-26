#!/usr/bin/env python3
"""
LC_Coop — sidecar de red (Python)
=================================

Puente entre el mod Lua (archivos IPC) y la red (UDP).

Soporta IPv4, IPv6 y nombres/dominios (se resuelven por DNS; útil con Tailscale MagicDNS).

IP:
  - Fija:      --peer 100.x.y.z   (o un nombre: --peer pc-juan)
  - Dinámica:  --peer-file lc_peer.txt   (la escribe el juego con `lc_connect <IP|nombre>`)

Paquete (little-endian; independiente de la familia de direcciones):
  [0]      uint8  tipo (1 = posición, 2 = evento, 3 = HELLO, 4 = ACK)
  tipo 1:  float32 x, y, z, yaw ; uint32 seq   (21 bytes)
  tipo 2:  resto = texto UTF-8 del evento
  tipo 3:  "LCCOOP/1;<id>;<nombre>;"        (HELLO liviano)
  tipo 4:  "LCCOOP/1;<id>;<nombre>;<target>" (ACK a un HELLO)

El HELLO/ACK confirma que el otro cliente está escuchando y escribe
`lc_net_status.txt` (lo lee el menú F9). Para probar sin abrir el juego:
  python3 coop_net.py --probe <IP-o-nombre> [--port 27015]
"""

import argparse
import json
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid

PKT_POS = 1
PKT_EVENT = 2
PKT_HELLO = 3
PKT_ACK = 4
PKT_STATE = 6
PKT_POS_AREA = 7
POS_FMT = "<BffffI"
POS_SIZE = struct.calcsize(POS_FMT)
EVT_HDR = struct.Struct("<B")
POS = struct.Struct(POS_FMT)

HELLO_MAGIC = "LCCOOP/1"
HELLO_INTERVAL = 2.0   # segundos entre HELLO (paquete liviano)
ACK_TIMEOUT = 5.0      # sin ACK por este tiempo => "sin confirmar"
STATUS_INTERVAL = 1.0  # cada cuánto se escribe lc_net_status.txt


LOG_PATH = None


def log(msg):
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(f"[LC_Coop-net] {msg}", flush=True)
    if LOG_PATH:
        try:
            with open(LOG_PATH, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            pass


def read_text(path, retries=3):
    for _ in range(retries):
        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as f:
                return f.read()
        except (FileNotFoundError, PermissionError, OSError):
            time.sleep(0.002)
    return ""


def write_text_atomic(path, text):
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except OSError:
        pass


def truncate(path):
    try:
        open(path, "w").close()
    except OSError:
        pass


def sanitize_name(name):
    """Nombre corto y seguro para el handshake (sin ; ni saltos de línea)."""
    name = re.sub(r"[;\r\n]", "", name or "")
    return (name.strip() or "lc-client")[:32]


def clean_area(raw):
    """Token de área/dimensión (sin comas/; para no romper los formatos)."""
    s = re.sub(r"[^0-9A-Za-z_.:/-]", "_", (raw or "").strip())
    return (s[:40] or "?")


def load_client_id(directory):
    """ID estable del cliente entre reinicios (para el save del servidor)."""
    path = os.path.join(directory, "lc_client_id.txt")
    cid = read_text(path).strip()
    if re.fullmatch(r"[0-9a-fA-F]{8,32}", cid):
        return cid.lower()
    cid = uuid.uuid4().hex[:12]
    write_text_atomic(path, cid + "\n")
    return cid


def split_host_port(rest, default_port):
    """Separa host[:puerto], con soporte para IPv6 [fd7a::1]:27020."""
    m = re.match(r"^\[([0-9a-fA-F:.]+)\](?::(\d+))?$", rest)
    if m:
        return m.group(1), int(m.group(2) or default_port)
    if rest.count(":") == 1:
        h, _, p = rest.rpartition(":")
        if p.isdigit():
            return h, int(p)
    return rest, default_port


def make_handshake(kind, client_id, client_name, target_id=""):
    """Paquete de control liviano: HELLO o ACK."""
    text = f"{HELLO_MAGIC};{client_id};{client_name};{target_id}"
    return bytes([kind]) + text.encode("utf-8")


def parse_handshake(data):
    """Devuelve (kind, sender_id, sender_name, target_id) o None."""
    if len(data) < 2 or data[0] not in (PKT_HELLO, PKT_ACK):
        return None
    try:
        text = data[1:].decode("utf-8", "ignore").strip()
    except Exception:
        return None
    parts = text.split(";")
    if len(parts) < 3 or parts[0] != HELLO_MAGIC:
        return None
    sender_id = parts[1][:32]
    sender_name = sanitize_name(parts[2])
    target_id = parts[3][:32] if len(parts) > 3 else ""
    return data[0], sender_id, sender_name, target_id


def format_addr(sa):
    """Formatea un sockaddr para logs/estado, sin ::ffff: en IPv4."""
    try:
        host = sa[0].replace("::ffff:", "")
        port = sa[1]
        if ":" in host:
            return f"[{host}]:{port}"
        return f"{host}:{port}"
    except Exception:
        return str(sa)


def unique_addrs(addrs):
    """Quita duplicados IPv4/IPv6 de getaddrinfo."""
    seen = set()
    out = []
    for sa in addrs:
        key = (sa[0].replace("::ffff:", ""), sa[1])
        if key in seen:
            continue
        seen.add(key)
        out.append(sa)
    return out


def parse_coords(text):
    if not text:
        return None
    line = text.strip().splitlines()[0] if text.strip() else ""
    parts = line.split(",")
    if len(parts) < 3:
        return None
    try:
        x, y, z = float(parts[0]), float(parts[1]), float(parts[2])
        yaw = float(parts[3]) if len(parts) > 3 and parts[3] != "" else 0.0
        seq = int(parts[4]) if len(parts) > 4 and parts[4] != "" else 0
    except ValueError:
        return None
    return x, y, z, yaw, seq


def clean_host(raw):
    """Normaliza lo leído de lc_peer.txt: quita CR/espacios/comillas/puerto."""
    host = (raw or "").strip().strip('"').strip("'")
    # IPv6 entre corchetes: [fd7a::1] o [fd7a::1]:27015
    m = re.match(r"^\[([0-9a-fA-F:.]+)\](?::\d+)?$", host)
    if m:
        return m.group(1)
    # quitar puerto pegado solo si NO es IPv6 (IPv6 tiene 2+ ':')
    if host.count(":") == 1:
        h, _, p = host.rpartition(":")
        if p.isdigit():
            host = h
    # si hay una IPv4 embebida (por CR u otra basura), extraerla
    m = re.search(r"(\d{1,3}\.){3}\d{1,3}", host)
    if m:
        host = m.group(0)
    else:
        host = re.sub(r"\s+", "", host)
    return host


def local_ips():
    """IPs propias, para no mandarnos paquetes a nosotros mismos (evita loopback)."""
    addrs = {"127.0.0.1", "::1"}
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None):
            addrs.add(info[4][0])
    except OSError:
        pass
    try:
        tmp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        tmp.connect(("8.8.8.8", 80))
        addrs.add(tmp.getsockname()[0])
        tmp.close()
    except OSError:
        pass
    # Todas las IPs de las interfaces (incluye Tailscale): hostname -I
    try:
        out = subprocess.check_output(["hostname", "-I"], text=True, timeout=2)
        addrs.update(out.split())
    except Exception:
        pass
    # Tailscale explícito
    for cmd in (["tailscale", "ip", "-4"], ["tailscale", "ip", "-6"]):
        try:
            out = subprocess.check_output(cmd, text=True, timeout=2)
            addrs.update(out.split())
        except Exception:
            pass
    return addrs


def game_running():
    """¿Está corriendo el juego? (para que el sidecar salga cuando se cierra)."""
    if not os.path.isdir("/proc"):
        return True  # no es Linux: no podemos chequear
    try:
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            try:
                with open(f"/proc/{pid}/cmdline", "rb") as f:
                    parts = f.read().decode("utf-8", "ignore").split("\0")
            except OSError:
                continue
            # Solo el ejecutable real del juego (argv[0]). Así no confundimos
            # wrappers de Steam/Proton ni una terminal que mencione el nombre
            # en sus argumentos: eso mantenía vivo al sidecar tras cerrar.
            if parts and "VoyageSteam-Win64-Shipping" in parts[0]:
                return True
    except OSError:
        return True
    return False


def resolve_addrs(host, port):
    """Devuelve una lista de sockaddr (IPv4 primero, luego IPv6)."""
    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_UDP)
    except OSError:
        return []
    infos.sort(key=lambda i: 0 if i[0] == socket.AF_INET else 1)
    return unique_addrs([i[4] for i in infos])


class CoopNet:
    def __init__(self, peer, port, listen_port, directory, rate_hz, peer_file=None,
                 watch_game=False, client_name=None):
        self.watch_game = watch_game
        self.port = port
        self.peer_file = os.path.join(directory, peer_file) if peer_file else None
        self.peer = peer
        self.local_ips = local_ips()
        self.relay_addrs = []
        self.peer_addrs = unique_addrs([a for a in resolve_addrs(peer, port)
                                        if a[0].replace("::ffff:", "") not in self.local_ips]) if peer else []
        self.dir = directory
        self.interval = 1.0 / max(1, rate_hz)
        self.coords_out = os.path.join(directory, "coords_out.txt")
        self.coords_in = os.path.join(directory, "coords_in.txt")
        self.event_out = os.path.join(directory, "event_out.txt")
        self.event_in = os.path.join(directory, "event_in.txt")
        self.status_path = os.path.join(directory, "lc_net_status.txt")
        self.area_path = os.path.join(directory, "area_out.txt")
        self.client_id = load_client_id(directory)
        self.client_name = sanitize_name(client_name or socket.gethostname())
        self.local_area = clean_area(read_text(self.area_path).strip())

        # Socket dual-stack (recibe IPv4 e IPv6); si falla, cae a IPv4.
        try:
            self.sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
            self.sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            self.sock.bind(("::", listen_port))
        except OSError:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.sock.bind(("0.0.0.0", listen_port))
        self.listen_port = listen_port
        self.running = True
        self.last_peer_addr = None
        self.reply_addr = None  # dirección del último paquete recibido (para responder)
        self.sent = 0
        self.last_send_log = 0.0
        self.last_game_check = 0.0
        self.game_gone = 0
        self.game_seen = False
        self.started_at = time.time()
        self.last_resolve = 0.0
        self.last_relay_resolve = 0.0
        self.last_server_resolve = 0.0
        self.last_area_read = 0.0

        # Modo servidor dedicado (server:host:puerto).
        self.server_mode = False
        self.server_addr = None
        self.server_peer = ""
        self.server_name = ""
        self.remote_name = ""
        self.remote_online = False
        self.last_state_at = 0.0
        self.last_state_log = 0.0
        self.last_doors = {}
        self.last_remote_seq = None
        self.server_players = 0
        self.server_online_players = 0
        self.server_saved_players = 0
        self.server_saved_containers = 0
        self.server_saved_at = 0

        # Handshake / estado visible para el menú F9.
        self.last_hello_sent = 0.0
        self.last_status_write = 0.0
        self.last_ack_at = 0.0
        self.last_hello_rx_at = 0.0
        self.last_pos_at = 0.0
        self.last_rx_at = 0.0
        self.last_hello_log = 0.0
        self.last_ack_log = 0.0
        self.last_pos_log = 0.0
        self.peer_name = ""
        self.net_state_last = ""
        self.tx_pos = 0
        self.tx_event = 0
        self.rx_pos = 0
        self.rx_event = 0
        self.rx_ack = 0
        self.rx_hello = 0

    def _reset_reply(self):
        """Al cambiar de peer no seguir mandando al reply_addr viejo."""
        self.reply_addr = None
        self.last_peer_addr = None
        self.last_ack_at = 0.0
        self.last_hello_rx_at = 0.0
        self.last_pos_at = 0.0
        self.last_rx_at = 0.0
        self.peer_name = ""
        self.net_state_last = ""
        self.server_mode = False
        self.server_addr = None
        self.server_peer = ""
        self.server_name = ""
        self.remote_name = ""
        self.remote_online = False
        self.last_state_at = 0.0
        self.last_state_log = 0.0
        self.last_doors = {}
        self.last_remote_seq = None
        self.server_players = 0
        self.server_online_players = 0
        self.server_saved_players = 0
        self.server_saved_containers = 0
        self.server_saved_at = 0

    def set_peer(self, peer, peer_addrs=None, relay_addrs=None):
        changed = (peer != self.peer)
        self.peer = peer
        if peer_addrs is not None:
            self.peer_addrs = unique_addrs(peer_addrs)
        if relay_addrs is not None:
            self.relay_addrs = unique_addrs(relay_addrs)
        if changed:
            self._reset_reply()

    def refresh_peer(self):
        if not self.peer_file:
            return
        raw = read_text(self.peer_file).strip().strip('"').strip("'")
        raw = re.sub(r"\s+", "", raw)

        # --- modo servidor dedicado: "server:host[:puerto]" ---
        if raw.lower().startswith("server:"):
            host, srv_port = split_host_port(raw[7:], self.port)
            key = f"server:{host}:{srv_port}"
            now = time.time()
            if key == self.peer:
                if self.server_addr:
                    return
                if now - self.last_server_resolve < 10:
                    return  # reintentar DNS cada 10 s si falló
            self.last_server_resolve = now
            addrs = resolve_addrs(host, srv_port)
            if not addrs:
                log(f"servidor: no pude resolver [{host}]")
                self.set_peer(key, [], [])
                self.server_mode = True
                self.server_addr = None
                self.server_peer = f"{host}:{srv_port}"
                return
            self.set_peer(key, [], [])
            self.server_mode = True
            self.server_addr = addrs[0]
            self.server_peer = f"{host}:{srv_port}"
            log(f"modo servidor -> {host}:{srv_port} -> "
                f"{format_addr(addrs[0])}")
            return

        # --- modo relay: "relay:host[:puerto]" ---
        if raw.lower().startswith("relay:"):
            rest = raw[6:]
            m = re.match(r"^\[([0-9a-fA-F:.]+)\](?::(\d+))?$", rest)
            if m:
                host = m.group(1)
                p = m.group(2) or str(self.port)
            elif rest.count(":") == 1:
                h, _, pp = rest.rpartition(":")
                if pp.isdigit():
                    host, p = h, pp
                else:
                    host, p = rest, str(self.port)
            else:
                # hostname sin puerto, o IPv6 sin corchetes
                host, p = rest, str(self.port)
            key = "relay:" + host + ":" + p
            now = time.time()
            if key == self.peer:
                if self.relay_addrs:
                    return
                if now - self.last_relay_resolve < 10:
                    return  # reintentar DNS cada 10 s si falló
            self.last_relay_resolve = now
            addrs = resolve_addrs(host, int(p))
            if not addrs:
                log(f"relay: no pude resolver [{host}]")
                self.set_peer(key, [], [])
                return
            self.set_peer(key, [], addrs)
            log(f"modo relay -> {host}:{p} -> "
                f"{', '.join(format_addr(a) for a in addrs)}")
            return

        # --- modo p2p ---
        host = clean_host(raw)
        same = (host == (self.peer or ""))
        now = time.time()
        if same:
            if not host:
                return
            if self.peer_addrs:
                return
            if now - self.last_resolve < 10:
                return  # reintentar DNS cada 10 s si falló
        self.last_resolve = now
        if not host:
            self.set_peer(None, [], [])
            log("peer vacío: desconectado")
            return
        addrs = resolve_addrs(host, self.port)
        addrs = [a for a in addrs if a[0].replace("::ffff:", "") not in self.local_ips]
        if not addrs:
            log(f"[{host}] es esta misma PC (o no resuelve): ignoro para no hacer loopback")
            self.set_peer(host, [], [])
            return
        self.set_peer(host, addrs, [])
        log(f"peer configurado: {host}:{self.port} -> "
            f"{', '.join(format_addr(a) for a in addrs)}")

    def src_matches_peer(self, src):
        """¿La IP de origen es la del peer configurado (o no hay peer)?"""
        if not self.peer_addrs:
            return True
        src = src.replace("::ffff:", "")
        return src in {sa[0].replace("::ffff:", "") for sa in self.peer_addrs}

    def targets(self):
        # Modo servidor dedicado: todo va a ESE servidor.
        if self.server_mode and self.server_addr:
            return [self.server_addr]
        # Modo relay: todo va al servidor de coordinación.
        if self.relay_addrs:
            return self.relay_addrs
        if self.reply_addr:
            # Responder al remitente real (NAT/puerto efímero), pero solo si
            # coincide con el peer configurado. Si cambiamos de peer (p. ej.
            # de relay a una IP de Tailscale), no seguir mandando al viejo.
            if self.src_matches_peer(self.reply_addr[0]):
                return [self.reply_addr]
        return self.peer_addrs

    def _sendto(self, data, sa):
        try:
            if self.sock.family == socket.AF_INET6 and len(sa) == 2:
                # IPv4 sobre socket IPv6 dual-stack: usar dirección mapeada
                sa = ("::ffff:" + sa[0], sa[1], 0, 0)
            self.sock.sendto(data, sa)
            return True
        except OSError:
            return False

    def send(self, data):
        """Un solo destino (eventos: no queremos duplicarlos)."""
        for sa in self.targets():
            if self._sendto(data, sa):
                self.sent += 1
                return True
        return False

    def send_all(self, data):
        """Todos los destinos (posición/HELLO: toleran duplicados).

        Sirve para descubrir si Tailscale responde por IPv4 o IPv6 cuando el
        nombre resuelve a las dos familias. Una vez que llega un paquete del
        peer, reply_addr queda fijo y se manda solo a esa dirección.
        """
        # En relay mandamos a UNA sola dirección: si el relay se resuelve por
        # IPv4 e IPv6, mandar a las dos crea dos "clientes" y el relay podría
        # reenviarnos nuestros propios paquetes.
        if self.relay_addrs:
            return self.send(data)
        targets = self.targets()
        if not targets:
            return False
        ok = False
        for sa in targets:
            if self._sendto(data, sa):
                ok = True
        if ok:
            self.sent += 1
        return ok

    def send_hello(self):
        if not self.targets():
            return False
        pkt = make_handshake(PKT_HELLO, self.client_id, self.client_name)
        return self.send_all(pkt)

    def send_ack(self, addr, target_id):
        pkt = make_handshake(PKT_ACK, self.client_id, self.client_name, target_id)
        return self._sendto(pkt, addr)

    def net_state(self, now=None):
        now = now or time.time()
        if not self.peer and not self.reply_addr:
            return "no_peer"
        if self.last_ack_at and now - self.last_ack_at <= ACK_TIMEOUT:
            return "confirmed"
        if self.last_rx_at and now - self.last_rx_at <= ACK_TIMEOUT:
            return "one_way"
        return "waiting"

    @staticmethod
    def _age(t, now):
        return f"{now - t:.1f}" if t else "-1"

    def current_peer_addr(self):
        """Dirección efectiva del peer, sin mostrar un reply viejo."""
        if self.server_mode and self.server_addr:
            return self.server_addr
        if self.reply_addr:
            if self.src_matches_peer(self.reply_addr[0]):
                return self.reply_addr
        if self.peer_addrs:
            return self.peer_addrs[0]
        if self.reply_addr:
            return self.reply_addr
        if self.relay_addrs:
            return self.relay_addrs[0]
        return None

    def write_status(self, state_override=None):
        now = time.time()
        state = state_override or self.net_state(now)
        addr_sa = self.current_peer_addr()
        addr = format_addr(addr_sa) if addr_sa else ""
        mode = "server" if self.server_mode else ("relay" if self.relay_addrs else "p2p")
        peer_name = self.remote_name or self.peer_name
        lines = [
            "version=1",
            f"ts={int(now)}",
            f"mode={mode}",
            f"state={state}",
            f"peer={self.peer or ''}",
            f"peer_addr={addr}",
            f"peer_name={peer_name}",
            f"local_area={self.local_area}",
            f"server={self.server_peer}",
            f"server_players={self.server_players}",
            f"server_online_players={self.server_online_players}",
            f"server_saved_players={self.server_saved_players}",
            f"server_saved_containers={self.server_saved_containers}",
            f"server_saved_at={self.server_saved_at}",
            f"remote_name={self.remote_name}",
            f"client_id={self.client_id}",
            f"client_name={self.client_name}",
            f"listen_port={self.listen_port}",
            f"confirmed={1 if state == 'confirmed' else 0}",
            f"last_ack_age={self._age(self.last_ack_at, now)}",
            f"last_rx_age={self._age(self.last_rx_at, now)}",
            f"last_pos_age={self._age(self.last_pos_at, now)}",
            f"tx_pos={self.tx_pos}",
            f"tx_event={self.tx_event}",
            f"rx_pos={self.rx_pos}",
            f"rx_event={self.rx_event}",
            f"rx_ack={self.rx_ack}",
            f"rx_hello={self.rx_hello}",
        ]
        write_text_atomic(self.status_path, "\n".join(lines) + "\n")

    def log_state_change(self, now):
        state = self.net_state(now)
        if state == self.net_state_last:
            return
        self.net_state_last = state
        if state == "confirmed":
            log(f"peer confirmado (escuchando): {self.peer_name or '?'} | "
                f"ACK hace {now - self.last_ack_at:.1f}s")
        elif state == "one_way":
            log("recibo paquetes del peer pero NO recibo ACK: "
                "puede que nuestros paquetes no le lleguen (firewall/Tailscale shields-up)")
        elif state == "waiting":
            log("peer configurado, esperando respuesta...")
        elif state == "no_peer":
            log("sin peer configurado (escuchando igual)")

    def _append_event(self, text):
        try:
            with open(self.event_in, "a", encoding="utf-8") as f:
                f.write(text + "\n")
        except OSError:
            pass

    def handle_server_state(self, data, now):
        """STATE JSON del servidor: jugador remoto (por área) + puertas."""
        try:
            st = json.loads(data[1:].decode("utf-8", "ignore"))
        except Exception as e:
            log(f"STATE invalido: {e}")
            return

        self.last_state_at = now
        self.server_saved_at = int(st.get("saved_at") or 0)
        self.server_saved_players = int(st.get("saved_players") or 0)
        self.server_saved_containers = int(st.get("saved_containers") or 0)
        players = st.get("players") or []
        self.server_players = len(players)
        try:
            self.server_online_players = int(st.get("online_players") or len(players))
        except (TypeError, ValueError):
            self.server_online_players = len(players)

        remote = None
        other_area = None
        for p in players:
            if not isinstance(p, dict):
                continue
            if p.get("id") == self.client_id:
                continue
            if not p.get("online", True):
                continue
            p_area = clean_area(p.get("area") or "?")
            if self.local_area not in ("", "?"):
                if p_area not in ("", "?", self.local_area):
                    other_area = p_area
                    continue
            remote = p
            break

        if remote:
            try:
                x = float(remote.get("x", 0.0))
                y = float(remote.get("y", 0.0))
                z = float(remote.get("z", 0.0))
                yaw = float(remote.get("yaw", 0.0))
                seq = int(remote.get("seq", 0) or 0)
            except (TypeError, ValueError):
                remote = None

        if remote:
            name = sanitize_name(remote.get("name") or "peer")
            area = clean_area(remote.get("area") or "?")
            if not self.remote_online:
                self.remote_online = True
                log(f"jugador remoto online: {name} "
                    f"({remote.get('id', '?')}) area={area}")
            self.remote_name = name
            self.peer_name = name
            if seq != self.last_remote_seq:
                self.last_remote_seq = seq
                self.rx_pos += 1
                self.last_pos_at = now
                write_text_atomic(
                    self.coords_in,
                    f"{x},{y},{z},{yaw},{seq},{area}")
            if now - self.last_pos_log >= 10:
                self.last_pos_log = now
                log(f"estado remoto: {name} area={area} "
                    f"{x:.1f},{y:.1f},{z:.1f} seq={seq}")
        else:
            if self.remote_online:
                self.remote_online = False
                self.remote_name = ""
                self.peer_name = self.server_name or "servidor"
                self.last_remote_seq = None
                self._append_event("PEER_OFFLINE,peer,0")
                suffix = f" (otra area: {other_area})" if other_area else ""
                log("jugador remoto offline" + suffix)

        doors = st.get("doors") or {}
        if isinstance(doors, dict):
            for dname, dval in doors.items():
                try:
                    v = int(dval)
                except (TypeError, ValueError):
                    continue
                if self.last_doors.get(dname) != v:
                    self.last_doors[dname] = v
                    self._append_event(f"DOOR,{dname},{v}")
                    log(f"puerta del servidor: {dname} -> {v}")

        if now - self.last_state_log >= 10:
            self.last_state_log = now
            log(f"servidor: {self.server_players} online, "
                f"{self.server_saved_players} guardados, "
                f"{self.server_saved_containers} contenedores, "
                f"area={self.local_area}, remoto={self.remote_name or '-'}")

    def recv_loop(self):
        while self.running:
            try:
                data, addr = self.sock.recvfrom(8192)
            except OSError:
                break
            if not data:
                continue
            now = time.time()
            src = addr[0].replace("::ffff:", "")
            kind = data[0]
            is_handshake = kind in (PKT_HELLO, PKT_ACK)
            # Los HELLO/ACK locales se permiten para poder probar con
            # `coop_net.py --probe 127.0.0.1`; las posiciones locales se ignoran
            # para no hacer loopback.
            is_local = (not self.relay_addrs and not self.server_mode) and (src in self.local_ips)
            if is_local and not is_handshake:
                continue
            if not is_local:
                if self.last_peer_addr != addr:
                    self.last_peer_addr = addr
                    log(f"peer conectado: {format_addr(addr)}")
                self.reply_addr = addr
                self.last_rx_at = now

            if kind == PKT_POS and len(data) >= POS_SIZE:
                _, x, y, z, yaw, seq = POS.unpack_from(data, 0)
                self.rx_pos += 1
                self.last_pos_at = now
                self.last_rx_at = now
                write_text_atomic(self.coords_in, f"{x},{y},{z},{yaw},{seq}")
                if now - self.last_pos_log >= 10:
                    self.last_pos_log = now
                    log(f"pos de {format_addr(addr)}: "
                        f"{x:.1f},{y:.1f},{z:.1f} yaw={yaw:.1f} seq={seq}")
            elif kind == PKT_EVENT:
                try:
                    text = data[1:].decode("utf-8", errors="ignore").strip()
                except Exception:
                    text = ""
                if text:
                    self.rx_event += 1
                    self.last_rx_at = now
                    try:
                        with open(self.event_in, "a", encoding="utf-8") as f:
                            f.write(text + "\n")
                    except OSError:
                        pass
                    log(f"evento recibido: {text}")
            elif kind == PKT_STATE:
                self.handle_server_state(data, now)
            elif kind == PKT_HELLO:
                parsed = parse_handshake(data)
                if parsed:
                    _, sender_id, sender_name, _ = parsed
                    self.rx_hello += 1
                    self.last_hello_rx_at = now
                    if not is_local and self.src_matches_peer(src):
                        self.peer_name = sender_name
                    self.send_ack(addr, sender_id)
                    if now - self.last_hello_log >= 10:
                        self.last_hello_log = now
                        log(f"HELLO de {format_addr(addr)} ({sender_name}); respondo ACK")
            elif kind == PKT_ACK:
                parsed = parse_handshake(data)
                if parsed:
                    _, sender_id, sender_name, target_id = parsed
                    # En modo relay el ACK puede venir dirigido a otro cliente.
                    if target_id and target_id != self.client_id:
                        continue
                    self.rx_ack += 1
                    self.last_ack_at = now
                    if self.server_mode:
                        self.server_name = sender_name
                        if not self.remote_name:
                            self.peer_name = sender_name
                    elif not is_local and self.src_matches_peer(src):
                        self.peer_name = sender_name
                    if now - self.last_ack_log >= 10:
                        self.last_ack_log = now
                        log(f"ACK de {format_addr(addr)} ({sender_name}) "
                            f"target={target_id or '-'}")

    def send_loop(self):
        while self.running:
            self.refresh_peer()

            now = time.time()
            if now - self.last_area_read >= 1.0:
                self.last_area_read = now
                area = clean_area(read_text(self.area_path).strip())
                if area and area != self.local_area:
                    log(f"área local: {self.local_area} -> {area}")
                    self.local_area = area

            if self.watch_game and now - self.last_game_check >= 1:
                self.last_game_check = now
                if game_running():
                    self.game_seen = True
                    self.game_gone = 0
                elif self.game_seen:
                    # Solo salimos si antes vimos el juego. Así también sirve
                    # si se lanza a mano antes de abrirlo.
                    self.game_gone += 1
                    if self.game_gone >= 2:
                        log("el juego se cerró: salgo")
                        break
                elif now - self.started_at > 60:
                    # Seguridad: si nunca apareció el juego (nombre de proceso
                    # distinto, lanzamiento huérfano), no quedarse colgado.
                    log("no apareció el juego en 60 s: salgo")
                    break
            if now - self.last_status_write >= STATUS_INTERVAL:
                self.last_status_write = now
                self.write_status()
                self.log_state_change(now)

            if now - self.last_hello_sent >= HELLO_INTERVAL:
                self.last_hello_sent = now
                self.send_hello()

            if now - self.last_send_log >= 5:
                self.last_send_log = now
                tgt = self.targets()
                ack_age = f"{now - self.last_ack_at:.1f}" if self.last_ack_at else "-1"
                pos_age = f"{now - self.last_pos_at:.1f}" if self.last_pos_at else "-1"
                extra = ""
                if self.server_mode:
                    extra = (f" srv={self.server_players} "
                             f"saved={self.server_saved_players} "
                             f"cont={self.server_saved_containers} "
                             f"area={self.local_area}")
                log(f"enviando a {tgt} | estado={self.net_state(now)} | "
                    f"tx_pos={self.tx_pos} rx_pos={self.rx_pos} "
                    f"ack={ack_age}s pos={pos_age}s{extra} | enviados={self.sent}")

            parsed = parse_coords(read_text(self.coords_out))
            if parsed is not None:
                x, y, z, yaw, seq = parsed
                area = self.local_area or "?"
                if self.server_mode:
                    ab = area.encode("utf-8")[:40]
                    pkt = (bytes([PKT_POS_AREA, len(ab)]) + ab +
                           POS.pack(PKT_POS, x, y, z, yaw, seq & 0xFFFFFFFF))
                else:
                    pkt = POS.pack(PKT_POS, x, y, z, yaw, seq & 0xFFFFFFFF)
                if self.send_all(pkt):
                    self.tx_pos += 1

            events = read_text(self.event_out)
            if events:
                truncate(self.event_out)
                for line in events.splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    if self.send(EVT_HDR.pack(PKT_EVENT) + line.encode("utf-8")):
                        self.tx_event += 1
                    log(f"evento enviado: {line}")

            time.sleep(self.interval)

    def run(self):
        log(f"escuchando en :{self.listen_port} (IPv4+IPv6) | "
            f"cliente={self.client_name} ({self.client_id})")
        log(f"IPs locales: {', '.join(sorted(self.local_ips)[:8])}")
        log(f"área local inicial: {self.local_area}")
        if self.peer:
            if str(self.peer).startswith("server:"):
                log(f"servidor dedicado: {self.peer}")
            else:
                log(f"enviando a {self.peer}:{self.port}")
        if self.peer_file:
            log(f"IP dinámica desde: {self.peer_file}")
        log(f"carpeta IPC: {self.dir}")
        self.write_status()
        t = threading.Thread(target=self.recv_loop, daemon=True)
        t.start()
        try:
            self.send_loop()
        except KeyboardInterrupt:
            pass
        finally:
            self.running = False
            try:
                self.write_status("stopped")
            except Exception:
                pass
            self.sock.close()
            log("detenido")


def probe_peer(host, port, timeout=3.0):
    """Pregunta si el otro cliente está escuchando (HELLO/ACK liviano)."""
    addrs = resolve_addrs(host, port)
    if not addrs:
        print(f"[probe] no pude resolver {host}:{port}")
        return 2
    client_id = uuid.uuid4().hex[:12]
    client_name = sanitize_name(socket.gethostname())
    try:
        sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        sock.bind(("::", 0))
    except OSError:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("0.0.0.0", 0))
    sock.settimeout(0.25)

    print(f"[probe] {host}:{port} -> {', '.join(format_addr(a) for a in addrs)}")
    print(f"[probe] enviando HELLO como {client_name} ({client_id})...")
    deadline = time.time() + max(0.5, timeout)
    next_send = 0.0
    try:
        while time.time() < deadline:
            now = time.time()
            if now >= next_send:
                next_send = now + 0.8
                pkt = make_handshake(PKT_HELLO, client_id, client_name)
                for sa in addrs:
                    try:
                        if sock.family == socket.AF_INET6 and len(sa) == 2:
                            sock.sendto(pkt, ("::ffff:" + sa[0], sa[1], 0, 0))
                        else:
                            sock.sendto(pkt, sa)
                    except OSError:
                        pass
            try:
                data, addr = sock.recvfrom(2048)
            except socket.timeout:
                continue
            except OSError:
                break
            if data and data[0] == PKT_ACK:
                parsed = parse_handshake(data)
                if parsed and parsed[3] == client_id:
                    print(f"[probe] OK: {format_addr(addr)} está escuchando "
                          f"(cliente: {parsed[2]})")
                    return 0
    finally:
        sock.close()

    print(f"[probe] TIMEOUT: {host}:{port} no respondió en {timeout:.0f}s")
    print("[probe] revisá: sidecar/juego abierto, firewall UDP 27015, Tailscale "
          "online y sin shields-up")
    return 1


def find_default_dir():
    c = os.path.expanduser(
        "~/.local/share/Steam/steamapps/common/Voyage/Voyage/Binaries/Win64")
    return c if os.path.isdir(c) else os.getcwd()


def main():
    ap = argparse.ArgumentParser(description="LC_Coop LAN sidecar")
    ap.add_argument("--peer", default=None,
                    help="IP/nombre del otro jugador, relay:... o server:host:puerto")
    ap.add_argument("--peer-file", default=None,
                    help="archivo con la IP/nombre (dinámica; ej. lc_peer.txt)")
    ap.add_argument("--server", default=None, metavar="HOST:PUERTO",
                    help="servidor dedicado de coordinación (atajo de --peer server:...)")
    ap.add_argument("--client-name", default=None,
                    help="nombre visible de este cliente (default: hostname)")
    ap.add_argument("--port", type=int, default=27015, help="puerto UDP (default 27015)")
    ap.add_argument("--listen-port", type=int, default=None,
                    help="puerto UDP local (default: igual a --port)")
    ap.add_argument("--dir", default=None, help="carpeta Binaries/Win64 del juego")
    ap.add_argument("--rate", type=int, default=30, help="paquetes por segundo (default 30)")
    ap.add_argument("--watch-game", action="store_true",
                    help="salir automáticamente cuando se cierre el juego")
    ap.add_argument("--probe", default=None, metavar="HOST",
                    help="probar si ese peer está escuchando (HELLO/ACK) y salir")
    ap.add_argument("--probe-timeout", type=float, default=3.0,
                    help="segundos de espera del probe (default 3)")
    args = ap.parse_args()

    if args.probe:
        sys.exit(probe_peer(args.probe, args.port, args.probe_timeout))

    if args.server:
        args.peer = "server:" + args.server
        args.peer_file = None

    if not args.peer and not args.peer_file:
        ap.error("necesitás --peer, --peer-file o --server")

    directory = args.dir or find_default_dir()
    if not os.path.isdir(directory):
        log(f"ERROR: la carpeta no existe: {directory}")
        sys.exit(1)

    global LOG_PATH
    LOG_PATH = os.path.join(directory, "lc_sidecar.log")
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(f"\n=== {time.strftime('%Y-%m-%d %H:%M:%S')} sidecar iniciado ===\n")
    except OSError:
        pass

    CoopNet(args.peer, args.port, args.listen_port or args.port,
            directory, args.rate, args.peer_file, args.watch_game,
            client_name=args.client_name).run()


if __name__ == "__main__":
    main()
