// LC_Coop — servidor dedicado de coordinación (Rust).
//
// Los clientes se conectan con `server:host:puerto` (en lc_peer.txt / F9).
// El servidor:
//   - registra clientes (HELLO/ACK),
//   - guarda la última posición de cada uno,
//   - guarda el estado de las puertas (eventos DOOR),
//   - manda STATE (JSON) a cada cliente con los otros jugadores y las puertas,
//   - persiste todo en un JSON (posiciones + puertas) y lo recarga al arrancar.
//
// No hostea el mundo del juego: cada cliente sigue corriendo su partida. Es el
// servidor de coordinación del mod, no un server target de UE5.
//
// Compilar estático:
//   cargo build --release --target x86_64-unknown-linux-musl

use serde::{Deserialize, Serialize};
use socket2::{Domain, Protocol, Socket, Type};
use std::collections::{HashMap, VecDeque};
use std::env;
use std::fs;
use std::io::{self, ErrorKind};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};
use std::path::{Path, PathBuf};
use std::process;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const PKT_POS: u8 = 1;
const PKT_EVENT: u8 = 2;
const PKT_HELLO: u8 = 3;
const PKT_ACK: u8 = 4;
const PKT_STATE: u8 = 6;
const PKT_POS_AREA: u8 = 7;
const PKT_CHAT: u8 = 8;

const DEFAULT_CHAT_RADIUS: f32 = 2500.0;
const CHAT_MAX_CHARS: usize = 240;
const CHAT_RATE_WINDOW: Duration = Duration::from_secs(5);
const CHAT_RATE_MAX: u32 = 10;

#[derive(Serialize, Deserialize, Clone, Default)]
struct SavedPos {
    #[serde(default)]
    x: f32,
    #[serde(default)]
    y: f32,
    #[serde(default)]
    z: f32,
    #[serde(default)]
    yaw: f32,
    #[serde(default)]
    seq: u32,
    #[serde(default)]
    last_seen: u64,
}

#[derive(Serialize, Deserialize, Clone, Default)]
struct SavedPlayer {
    #[serde(default)]
    id: String,
    #[serde(default)]
    name: String,
    /// Última área/dimensión conocida.
    #[serde(default)]
    area: String,
    /// Última posición en cada área/dimensión.
    #[serde(default)]
    positions: HashMap<String, SavedPos>,
    #[serde(default)]
    last_seen: u64,
}

#[derive(Serialize, Deserialize, Clone, Default)]
struct SavedContainer {
    #[serde(default)]
    id: String,
    #[serde(default)]
    area: String,
    #[serde(default)]
    items: HashMap<String, i32>,
    #[serde(default)]
    last_seen: u64,
}

#[derive(Deserialize, Default)]
struct ChatIn {
    #[serde(default)]
    scope: String,
    #[serde(default)]
    text: String,
    #[serde(default)]
    msg_id: String,
}

#[derive(Serialize)]
struct ChatOut {
    v: u8,
    scope: String,
    id: String,
    name: String,
    area: String,
    x: f32,
    y: f32,
    z: f32,
    text: String,
    ts: u64,
    msg_id: String,
}

fn default_version() -> u32 {
    1
}

#[derive(Serialize, Deserialize)]
struct SaveFile {
    #[serde(default = "default_version")]
    version: u32,
    #[serde(default)]
    updated_at: u64,
    #[serde(default)]
    players: HashMap<String, SavedPlayer>,
    #[serde(default)]
    doors: HashMap<String, i32>,
    #[serde(default)]
    containers: HashMap<String, SavedContainer>,
}

impl Default for SaveFile {
    fn default() -> Self {
        Self {
            version: 1,
            updated_at: 0,
            players: HashMap::new(),
            doors: HashMap::new(),
            containers: HashMap::new(),
        }
    }
}

#[derive(Serialize)]
struct PlayerOut {
    id: String,
    name: String,
    area: String,
    x: f32,
    y: f32,
    z: f32,
    yaw: f32,
    seq: u32,
    online: bool,
    age: f32,
}

#[derive(Serialize)]
struct StateOut<'a> {
    v: u8,
    server: &'a str,
    players: Vec<PlayerOut>,
    doors: &'a HashMap<String, i32>,
    online_players: usize,
    saved_players: usize,
    saved_containers: usize,
    saved_at: u64,
    chat_radius: f32,
}

struct Client {
    id: String,
    name: String,
    area: String,
    last_seen: Instant,
    chat_times: VecDeque<Instant>,
}

struct Config {
    port: u16,
    save_path: PathBuf,
    timeout: Duration,
    state_interval: Duration,
    save_interval: Duration,
    name: String,
    chat_radius: f32,
    dump_save: bool,
}

fn timestamp() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!(
        "{:02}:{:02}:{:02}",
        (secs / 3600) % 24,
        (secs / 60) % 60,
        secs % 60
    )
}

fn now_epoch() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn log(msg: &str) {
    println!("[LC_Coop-server] {} {}", timestamp(), msg);
}

fn fmt_addr(addr: &SocketAddr) -> String {
    match addr {
        SocketAddr::V4(a) => format!("{}:{}", a.ip(), a.port()),
        SocketAddr::V6(a) => {
            if let Some(v4) = a.ip().to_ipv4_mapped() {
                format!("{}:{}", v4, a.port())
            } else {
                format!("[{}]:{}", a.ip(), a.port())
            }
        }
    }
}

fn sanitize(s: &str, max: usize) -> String {
    let mut out = String::new();
    for c in s.chars() {
        if c == ';' || c == '\r' || c == '\n' || c == '\t' {
            continue;
        }
        if out.len() + c.len_utf8() > max {
            break;
        }
        out.push(c);
    }
    out.trim().to_string()
}

/// Texto de chat: conserva `;` y acentos, pero quita controles/saltos de línea.
fn sanitize_chat(s: &str, max: usize) -> String {
    let mut out = String::new();
    for c in s.chars() {
        let c = if c == '\r' || c == '\n' || c == '\t' || c.is_control() {
            ' '
        } else {
            c
        };
        if out.len() + c.len_utf8() > max {
            break;
        }
        out.push(c);
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn short_text(s: &str, max: usize) -> String {
    let mut out = String::new();
    for c in s.chars() {
        if out.chars().count() >= max {
            out.push('…');
            break;
        }
        out.push(c);
    }
    out
}

fn normalize_scope(raw: &str) -> &'static str {
    match raw.trim().to_ascii_lowercase().as_str() {
        "global" | "g" | "all" | "world" => "global",
        _ => "local",
    }
}

fn usage(program: &str) {
    println!("LC_Coop servidor de coordinación {VERSION}");
    println!("Uso: {program} [OPCIONES]");
    println!("  --port N            UDP (default: env PORT o 27020)");
    println!("  --save PATH         JSON de estado (default: env SAVE o lc-coop-server-save.json)");
    println!("  --timeout S         segundos sin actividad para expirar cliente (default: 30)");
    println!("  --state-hz N        frecuencia de STATE (default: 60)");
    println!("  --save-interval S   cada cuántos segundos guardar (default: 1)");
    println!("  --name STR          nombre visible del servidor (default: {})", "LC_Coop Server");
    println!("  --chat-radius N     radio del chat local en unidades UE (default: 2500)");
    println!("  --dump-save         imprime el save y sale");
    println!("  -h, --help          esta ayuda");
    println!("  -V, --version       version");
}

fn clamp_env_u64(name: &str, default: u64, min: u64, max: u64) -> u64 {
    env::var(name)
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(default)
        .clamp(min, max)
}

fn parse_args() -> Config {
    let program = env::args()
        .next()
        .unwrap_or_else(|| "lc-coop-server".to_string());

    let mut port: u16 = env::var("PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(27020);
    let mut save_path = PathBuf::from(
        env::var("SAVE").unwrap_or_else(|_| "lc-coop-server-save.json".to_string()),
    );
    let mut timeout_secs = clamp_env_u64("TIMEOUT", 30, 5, 3600);
    let mut state_hz = clamp_env_u64("STATE_HZ", 60, 1, 60);
    let mut save_interval_secs = clamp_env_u64("SAVE_INTERVAL", 1, 1, 60);
    let mut name = env::var("NAME").unwrap_or_else(|_| "LC_Coop Server".to_string());
    let mut chat_radius = env::var("CHAT_RADIUS")
        .ok()
        .and_then(|v| v.parse::<f32>().ok())
        .filter(|v| v.is_finite())
        .unwrap_or(DEFAULT_CHAT_RADIUS)
        .clamp(0.0, 100_000.0);
    let mut dump_save = false;

    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "-h" | "--help" => {
                usage(&program);
                process::exit(0);
            }
            "-V" | "--version" => {
                println!("lc-coop-server {VERSION}");
                process::exit(0);
            }
            "--dump-save" => dump_save = true,
            "--port" => {
                let v = args.next().unwrap_or_else(|| {
                    eprintln!("falta valor para --port");
                    process::exit(2);
                });
                port = v.parse().unwrap_or_else(|_| {
                    eprintln!("puerto invalido: {v}");
                    process::exit(2);
                });
            }
            "--save" => {
                save_path = PathBuf::from(args.next().unwrap_or_else(|| {
                    eprintln!("falta valor para --save");
                    process::exit(2);
                }));
            }
            "--timeout" => {
                timeout_secs = args
                    .next()
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or_else(|| {
                        eprintln!("valor invalido para --timeout");
                        process::exit(2);
                    })
                    .clamp(5, 3600);
            }
            "--state-hz" => {
                state_hz = args
                    .next()
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or_else(|| {
                        eprintln!("valor invalido para --state-hz");
                        process::exit(2);
                    })
                    .clamp(1, 60);
            }
            "--save-interval" => {
                save_interval_secs = args
                    .next()
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or_else(|| {
                        eprintln!("valor invalido para --save-interval");
                        process::exit(2);
                    })
                    .clamp(1, 60);
            }
            "--name" => {
                name = args.next().unwrap_or_else(|| {
                    eprintln!("falta valor para --name");
                    process::exit(2);
                });
            }
            "--chat-radius" => {
                let raw = args.next().unwrap_or_else(|| {
                    eprintln!("falta valor para --chat-radius");
                    process::exit(2);
                });
                chat_radius = raw
                    .parse::<f32>()
                    .ok()
                    .filter(|v| v.is_finite())
                    .unwrap_or_else(|| {
                        eprintln!("valor invalido para --chat-radius: {raw}");
                        process::exit(2);
                    })
                    .clamp(0.0, 100_000.0);
            }
            other => match other.parse::<u16>() {
                Ok(p) => port = p,
                Err(_) => {
                    eprintln!("opcion desconocida: {other}");
                    usage(&program);
                    process::exit(2);
                }
            },
        }
    }

    let name = {
        let n = sanitize(&name, 32);
        if n.is_empty() {
            "LC_Coop Server".to_string()
        } else {
            n
        }
    };

    Config {
        port,
        save_path,
        timeout: Duration::from_secs(timeout_secs),
        state_interval: Duration::from_millis((1000 / state_hz).max(10)),
        save_interval: Duration::from_secs(save_interval_secs),
        name,
        chat_radius,
        dump_save,
    }
}

fn make_socket(port: u16) -> io::Result<(UdpSocket, bool)> {
    let v6 = (|| -> io::Result<UdpSocket> {
        let sock = Socket::new(Domain::IPV6, Type::DGRAM, Some(Protocol::UDP))?;
        sock.set_only_v6(false)?;
        let addr = SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), port);
        let sa: socket2::SockAddr = addr.into();
        sock.bind(&sa)?;
        Ok(sock.into())
    })();

    if let Ok(socket) = v6 {
        return Ok((socket, true));
    }

    let sock = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), port);
    let sa: socket2::SockAddr = addr.into();
    sock.bind(&sa)?;
    Ok((sock.into(), false))
}

fn backup_bad(path: &Path) {
    let mut bad = path.as_os_str().to_os_string();
    bad.push(format!(".bad-{}", now_epoch()));
    let bad = PathBuf::from(bad);
    if fs::rename(path, &bad).is_ok() {
        log(&format!("save corrupto movido a: {}", bad.display()));
    }
}

fn normalize_save(mut save: SaveFile) -> SaveFile {
    if save.version == 0 {
        save.version = 1;
    }
    let keys: Vec<String> = save.players.keys().cloned().collect();
    for k in keys {
        if let Some(p) = save.players.get_mut(&k) {
            if p.id.is_empty() {
                p.id = k.clone();
            }
            if p.name.is_empty() {
                p.name = p.id.clone();
            }
            if p.area.is_empty() {
                p.area = p.positions.keys().next().cloned().unwrap_or_else(|| "?".to_string());
            }
        }
    }
    let ckeys: Vec<String> = save.containers.keys().cloned().collect();
    for k in ckeys {
        if let Some(c) = save.containers.get_mut(&k) {
            if c.id.is_empty() {
                c.id = k.clone();
            }
        }
    }
    save
}

fn load_save(path: &Path) -> SaveFile {
    match fs::read_to_string(path) {
        Ok(text) => match serde_json::from_str::<SaveFile>(&text) {
            Ok(save) => {
                let save = normalize_save(save);
                log(&format!(
                    "save cargado: {} ({} jugadores, {} puertas, {} contenedores)",
                    path.display(),
                    save.players.len(),
                    save.doors.len(),
                    save.containers.len()
                ));
                for p in save.players.values() {
                    if let Some(pos) = p.positions.get(&p.area) {
                        log(&format!(
                            "  guardado: {} ({}) area={} @ {:.1},{:.1},{:.1} last_seen={}",
                            p.name, p.id, p.area, pos.x, pos.y, pos.z, p.last_seen
                        ));
                    } else {
                        log(&format!(
                            "  guardado: {} ({}) area={} sin posicion aun",
                            p.name, p.id, p.area
                        ));
                    }
                }
                for c in save.containers.values() {
                    log(&format!(
                        "  contenedor guardado: {} area={} items={}",
                        c.id,
                        c.area,
                        c.items.len()
                    ));
                }
                save
            }
            Err(e) => {
                log(&format!("save invalido ({}): {}", path.display(), e));
                backup_bad(path);
                SaveFile::default()
            }
        },
        Err(e) if e.kind() == ErrorKind::NotFound => {
            log(&format!("save nuevo: {}", path.display()));
            SaveFile::default()
        }
        Err(e) => {
            log(&format!("no pude leer save {}: {}", path.display(), e));
            SaveFile::default()
        }
    }
}

fn save_now(path: &Path, save: &mut SaveFile) {
    save.version = 1;
    save.updated_at = now_epoch();
    let text = match serde_json::to_string_pretty(save) {
        Ok(t) => t,
        Err(e) => {
            log(&format!("no pude serializar save: {e}"));
            return;
        }
    };
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            let _ = fs::create_dir_all(parent);
        }
    }
    let mut tmp = path.as_os_str().to_os_string();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    if let Err(e) = fs::write(&tmp, text) {
        log(&format!("no pude escribir save {}: {}", tmp.display(), e));
        return;
    }
    if let Err(e) = fs::rename(&tmp, path) {
        log(&format!("no pude renombrar save {}: {}", path.display(), e));
    }
}

fn parse_handshake(data: &[u8]) -> Option<(String, String, String)> {
    if data.len() < 2 || data[0] != PKT_HELLO {
        return None;
    }
    let text = std::str::from_utf8(&data[1..]).ok()?.trim();
    let parts: Vec<&str> = text.split(';').collect();
    if parts.len() < 3 || parts[0] != "LCCOOP/1" {
        return None;
    }
    let id = sanitize(parts[1], 32);
    let name = sanitize(parts[2], 32);
    if id.is_empty() {
        return None;
    }
    let target = parts.get(3).map(|s| s.to_string()).unwrap_or_default();
    Some((id, name, target))
}

fn parse_pos(data: &[u8]) -> Option<(f32, f32, f32, f32, u32)> {
    if data.len() < 21 || data[0] != PKT_POS {
        return None;
    }
    let x = f32::from_le_bytes(data[1..5].try_into().ok()?);
    let y = f32::from_le_bytes(data[5..9].try_into().ok()?);
    let z = f32::from_le_bytes(data[9..13].try_into().ok()?);
    let yaw = f32::from_le_bytes(data[13..17].try_into().ok()?);
    let seq = u32::from_le_bytes(data[17..21].try_into().ok()?);
    Some((x, y, z, yaw, seq))
}

fn parse_pos_area(data: &[u8]) -> Option<(String, f32, f32, f32, f32, u32)> {
    if data.len() < 2 + 1 + 21 || data[0] != PKT_POS_AREA {
        return None;
    }
    let area_len = data[1] as usize;
    if area_len == 0 || data.len() < 2 + area_len + 21 {
        return None;
    }
    let area = sanitize(
        std::str::from_utf8(&data[2..2 + area_len]).ok()?,
        40,
    );
    if area.is_empty() {
        return None;
    }
    let pos = &data[2 + area_len..2 + area_len + 21];
    let (x, y, z, yaw, seq) = parse_pos(pos)?;
    Some((area, x, y, z, yaw, seq))
}

fn parse_door_event(text: &str) -> Option<(String, i32)> {
    let rest = text.strip_prefix("DOOR,")?;
    let (name, value) = rest.rsplit_once(',')?;
    let name = sanitize(name, 128);
    if name.is_empty() {
        return None;
    }
    let value: i32 = value.trim().parse().ok()?;
    Some((name, value))
}

enum ContainerOp {
    Begin { area: String },
    Item { path: String, count: i32 },
    End { area: String },
}

fn parse_container_event(text: &str) -> Option<(String, ContainerOp)> {
    if !text.starts_with("CONT,") {
        return None;
    }
    let rest = text.strip_prefix("CONT,")?;
    let (id, rest) = rest.split_once(',')?;
    let id = sanitize(id, 64);
    if id.is_empty() {
        return None;
    }
    let mut parts = rest.split(';');
    let area = sanitize(parts.next()?, 40);
    let op = parts.next()?;
    match op {
        "BEGIN" => Some((id, ContainerOp::Begin { area })),
        "ITEM" => {
            let path_raw = parts.next()?;
            let count_raw = parts.next()?;
            let path = sanitize(path_raw, 256);
            let count = count_raw.trim().parse::<i32>().ok()?;
            if path.is_empty() || count < 0 {
                return None;
            }
            Some((id, ContainerOp::Item { path, count }))
        }
        "END" => Some((id, ContainerOp::End { area })),
        _ => None,
    }
}

fn parse_chat(data: &[u8]) -> Option<ChatIn> {
    if data.len() < 3 || data[0] != PKT_CHAT {
        return None;
    }
    let chat: ChatIn = serde_json::from_slice(&data[1..]).ok()?;
    if chat.text.trim().is_empty() {
        return None;
    }
    Some(chat)
}

fn distance_to(pos: &SavedPos, x: f32, y: f32, z: f32) -> f32 {
    let dx = pos.x - x;
    let dy = pos.y - y;
    let dz = pos.z - z;
    (dx * dx + dy * dy + dz * dz).sqrt()
}

struct PendingContainer {
    area: String,
    items: HashMap<String, i32>,
}

fn send_event(socket: &UdpSocket, addr: SocketAddr, text: &str) {
    let mut pkt = Vec::with_capacity(text.len() + 1);
    pkt.push(PKT_EVENT);
    pkt.extend_from_slice(text.as_bytes());
    let _ = socket.send_to(&pkt, addr);
}

fn send_container_snapshots(
    socket: &UdpSocket,
    addr: SocketAddr,
    client_area: &str,
    save: &SaveFile,
) {
    for c in save.containers.values() {
        if !client_area.is_empty()
            && client_area != "?"
            && !c.area.is_empty()
            && c.area != "?"
            && c.area != client_area
        {
            continue;
        }
        send_event(socket, addr, &format!("CONT,{},{};BEGIN;0", c.id, c.area));
        for (path, count) in c.items.iter() {
            send_event(
                socket,
                addr,
                &format!("CONT,{},{};ITEM;{};{}", c.id, c.area, path, count),
            );
        }
        send_event(socket, addr, &format!("CONT,{},{};END;0", c.id, c.area));
    }
}

fn state_for<'a>(
    server: &'a str,
    clients: &HashMap<SocketAddr, Client>,
    save: &'a SaveFile,
    recipient_id: &str,
    chat_radius: f32,
) -> StateOut<'a> {
    let now = Instant::now();
    let mut players = Vec::new();
    for c in clients.values() {
        if c.id == recipient_id {
            continue;
        }
        if let Some(p) = save.players.get(&c.id) {
            let area = if p.area.is_empty() { c.area.clone() } else { p.area.clone() };
            if let Some(pos) = p.positions.get(&area) {
                players.push(PlayerOut {
                    id: p.id.clone(),
                    name: p.name.clone(),
                    area,
                    x: pos.x,
                    y: pos.y,
                    z: pos.z,
                    yaw: pos.yaw,
                    seq: pos.seq,
                    online: true,
                    age: now.duration_since(c.last_seen).as_secs_f32(),
                });
            }
        }
    }
    StateOut {
        v: 1,
        server,
        players,
        doors: &save.doors,
        online_players: clients.len(),
        saved_players: save.players.len(),
        saved_containers: save.containers.len(),
        saved_at: save.updated_at,
        chat_radius,
    }
}

fn send_state_to(
    socket: &UdpSocket,
    server: &str,
    clients: &HashMap<SocketAddr, Client>,
    save: &SaveFile,
    addr: SocketAddr,
    client_id: &str,
    chat_radius: f32,
) {
    let state = state_for(server, clients, save, client_id, chat_radius);
    let json = match serde_json::to_vec(&state) {
        Ok(v) => v,
        Err(e) => {
            log(&format!("no pude serializar STATE: {e}"));
            return;
        }
    };
    if json.len() > 8000 {
        log(&format!(
            "STATE demasiado grande ({} bytes); lo salteo",
            json.len()
        ));
        return;
    }
    let mut pkt = Vec::with_capacity(json.len() + 1);
    pkt.push(PKT_STATE);
    pkt.extend_from_slice(&json);
    let _ = socket.send_to(&pkt, addr);
}

fn broadcast_chat(
    socket: &UdpSocket,
    clients: &HashMap<SocketAddr, Client>,
    save: &SaveFile,
    sender_addr: SocketAddr,
    sender_id: &str,
    chat: &ChatIn,
    radius: f32,
) -> usize {
    let sender = match clients.get(&sender_addr) {
        Some(c) => c,
        None => return 0,
    };
    let sender_name = sender.name.clone();
    let sender_area = sender.area.clone();
    let scope = normalize_scope(&chat.scope);
    let text = sanitize_chat(&chat.text, CHAT_MAX_CHARS);
    if text.is_empty() {
        return 0;
    }

    let sender_pos = save
        .players
        .get(sender_id)
        .and_then(|p| p.positions.get(&sender_area))
        .cloned();
    if scope == "local"
        && (sender_area.is_empty() || sender_area == "?" || sender_pos.is_none())
    {
        return 0;
    }
    let (sx, sy, sz) = sender_pos
        .as_ref()
        .map(|p| (p.x, p.y, p.z))
        .unwrap_or((0.0, 0.0, 0.0));

    let mut recipients = Vec::new();
    for (addr, c) in clients.iter() {
        if c.id == sender_id {
            continue;
        }
        if scope == "local" {
            if c.area.is_empty() || c.area == "?" || c.area != sender_area {
                continue;
            }
            let pos = match save
                .players
                .get(&c.id)
                .and_then(|p| p.positions.get(&c.area))
            {
                Some(p) => p,
                None => continue,
            };
            if distance_to(pos, sx, sy, sz) > radius {
                continue;
            }
        }
        recipients.push(*addr);
    }

    let msg_id = {
        let given = sanitize(&chat.msg_id, 64);
        if given.is_empty() {
            format!("{}:{}:{}", sender_id, now_epoch(), recipients.len())
        } else {
            given
        }
    };
    let out = ChatOut {
        v: 1,
        scope: scope.to_string(),
        id: sender_id.to_string(),
        name: sender_name.clone(),
        area: sender_area.clone(),
        x: sx,
        y: sy,
        z: sz,
        text: text.clone(),
        ts: now_epoch(),
        msg_id,
    };
    let json = match serde_json::to_vec(&out) {
        Ok(v) => v,
        Err(e) => {
            log(&format!("no pude serializar chat: {e}"));
            return 0;
        }
    };
    let mut pkt = Vec::with_capacity(json.len() + 1);
    pkt.push(PKT_CHAT);
    pkt.extend_from_slice(&json);
    for addr in &recipients {
        let _ = socket.send_to(&pkt, addr);
    }
    log(&format!(
        "chat[{}] {}: {} ({} destinatarios)",
        scope,
        sender_name,
        short_text(&text, 80),
        recipients.len()
    ));
    recipients.len()
}

fn send_ack(socket: &UdpSocket, server_name: &str, addr: SocketAddr, client_id: &str) {
    let text = format!("LCCOOP/1;server;{};{}", sanitize(server_name, 32), client_id);
    let mut pkt = Vec::with_capacity(text.len() + 1);
    pkt.push(PKT_ACK);
    pkt.extend_from_slice(text.as_bytes());
    let _ = socket.send_to(&pkt, addr);
}

fn cleanup(clients: &mut HashMap<SocketAddr, Client>, timeout: Duration) -> usize {
    let now = Instant::now();
    let expired: Vec<(SocketAddr, String, String)> = clients
        .iter()
        .filter(|(_, c)| now.saturating_duration_since(c.last_seen) > timeout)
        .map(|(a, c)| (*a, c.id.clone(), c.name.clone()))
        .collect();
    for (addr, id, name) in &expired {
        clients.remove(addr);
        log(&format!(
            "cliente expirado: {} ({}) {} (total={})",
            name,
            id,
            fmt_addr(addr),
            clients.len()
        ));
    }
    expired.len()
}

fn main() {
    let config = parse_args();

    if config.dump_save {
        match fs::read_to_string(&config.save_path) {
            Ok(text) => match serde_json::from_str::<SaveFile>(&text) {
                Ok(save) => {
                    let save = normalize_save(save);
                    println!(
                        "{}",
                        serde_json::to_string_pretty(&save)
                            .unwrap_or_else(|_| "{}".to_string())
                    );
                }
                Err(e) => {
                    eprintln!("save invalido: {e}");
                    process::exit(1);
                }
            },
            Err(e) => {
                eprintln!(
                    "no pude leer {}: {}",
                    config.save_path.display(),
                    e
                );
                process::exit(1);
            }
        }
        return;
    }

    let (socket, dual) = match make_socket(config.port) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("no pude bindear UDP :{}: {}", config.port, e);
            process::exit(1);
        }
    };
    let _ = socket.set_read_timeout(Some(Duration::from_millis(5)));

    log(&format!(
        "escuchando en :{} ({}) name={} save={} chat_radius={:.0}",
        config.port,
        if dual { "IPv4+IPv6" } else { "IPv4" },
        config.name,
        config.save_path.display(),
        config.chat_radius
    ));

    let mut save = load_save(&config.save_path);
    let mut clients: HashMap<SocketAddr, Client> = HashMap::new();
    let mut pending_containers: HashMap<String, PendingContainer> = HashMap::new();
    let mut dirty = false;
    let mut packets: u64 = 0;
    let mut last_state = Instant::now();
    let mut last_save = Instant::now();
    let mut last_cleanup = Instant::now();
    let mut last_stats = Instant::now();

    let stop = Arc::new(AtomicBool::new(false));
    let stop_handler = stop.clone();
    if let Err(e) = ctrlc::set_handler(move || {
        stop_handler.store(true, Ordering::SeqCst);
    }) {
        log(&format!("aviso: no pude instalar handler de senal: {e}"));
    }

    let mut buf = [0u8; 8192];

    while !stop.load(Ordering::SeqCst) {
        match socket.recv_from(&mut buf) {
            Ok((n, addr)) => {
                if n == 0 {
                    continue;
                }
                packets += 1;
                let now = Instant::now();

                // HELLO: registrar/actualizar cliente.
                if let Some((id, name, _target)) = parse_handshake(&buf[..n]) {
                    let existed = clients
                        .get(&addr)
                        .map(|c| c.id == id && c.name == name)
                        .unwrap_or(false);
                    let area = {
                        let entry = save.players.entry(id.clone()).or_insert_with(|| {
                            SavedPlayer {
                                id: id.clone(),
                                name: name.clone(),
                                ..Default::default()
                            }
                        });
                        entry.id = id.clone();
                        entry.name = name.clone();
                        entry.last_seen = now_epoch();
                        if entry.area.is_empty() {
                            entry.area = "?".to_string();
                        }
                        entry.area.clone()
                    };
                    // Si el mismo ID cambió de dirección, sacar la vieja.
                    clients.retain(|a, c| *a == addr || c.id != id);
                    let chat_times = clients
                        .get(&addr)
                        .map(|c| c.chat_times.clone())
                        .unwrap_or_default();
                    clients.insert(
                        addr,
                        Client {
                            id: id.clone(),
                            name: name.clone(),
                            area: area.clone(),
                            last_seen: now,
                            chat_times,
                        },
                    );
                    dirty = true;

                    send_ack(&socket, &config.name, addr, &id);
                    send_state_to(&socket, &config.name, &clients, &save, addr, &id, config.chat_radius);
                    if !existed {
                        send_container_snapshots(&socket, addr, &area, &save);
                        log(&format!(
                            "cliente conectado: {} ({}) {} area={} (total={})",
                            name,
                            id,
                            fmt_addr(&addr),
                            area,
                            clients.len()
                        ));
                    }
                    continue;
                }

                // Cualquier otro paquete requiere un cliente registrado.
                if let Some(c) = clients.get_mut(&addr) {
                    c.last_seen = now;
                }
                let cid = clients.get(&addr).map(|c| c.id.clone());
                let cid = match cid {
                    Some(v) => v,
                    None => continue,
                };

                match buf[0] {
                    PKT_POS_AREA => {
                        if let Some((area, x, y, z, yaw, seq)) = parse_pos_area(&buf[..n]) {
                            let old_area = clients
                                .get(&addr)
                                .map(|c| c.area.clone())
                                .unwrap_or_default();
                            if let Some(c) = clients.get_mut(&addr) {
                                c.area = area.clone();
                            }
                            if let Some(p) = save.players.get_mut(&cid) {
                                p.area = area.clone();
                                p.positions.insert(
                                    area.clone(),
                                    SavedPos {
                                        x,
                                        y,
                                        z,
                                        yaw,
                                        seq,
                                        last_seen: now_epoch(),
                                    },
                                );
                                p.last_seen = now_epoch();
                                dirty = true;
                            }
                            if old_area != area {
                                send_container_snapshots(&socket, addr, &area, &save);
                            }
                        }
                    }
                    PKT_POS => {
                        let client_area = clients
                            .get(&addr)
                            .map(|c| c.area.clone())
                            .unwrap_or_else(|| "?".to_string());
                        let area = if client_area.is_empty() {
                            "?".to_string()
                        } else {
                            client_area
                        };
                        if let Some((x, y, z, yaw, seq)) = parse_pos(&buf[..n]) {
                            if let Some(p) = save.players.get_mut(&cid) {
                                p.area = area.clone();
                                p.positions.insert(
                                    area,
                                    SavedPos {
                                        x,
                                        y,
                                        z,
                                        yaw,
                                        seq,
                                        last_seen: now_epoch(),
                                    },
                                );
                                p.last_seen = now_epoch();
                                dirty = true;
                            }
                        }
                    }
                    PKT_EVENT if n > 1 => {
                        let text = String::from_utf8_lossy(&buf[1..n]).trim().to_string();
                        if let Some((name, value)) = parse_door_event(&text) {
                            save.doors.insert(name.clone(), value);
                            dirty = true;
                            log(&format!("puerta: {} -> {}", name, value));
                        } else if let Some((cont_id, op)) = parse_container_event(&text) {
                            // Reenviar el snapshot en vivo a los demás clientes.
                            for (other_addr, other) in clients.iter() {
                                if other.id != cid {
                                    let _ = socket.send_to(&buf[..n], other_addr);
                                }
                            }
                            match op {
                                ContainerOp::Begin { area } => {
                                    pending_containers.insert(
                                        cont_id,
                                        PendingContainer {
                                            area,
                                            items: HashMap::new(),
                                        },
                                    );
                                }
                                ContainerOp::Item { path, count } => {
                                    if let Some(p) = pending_containers.get_mut(&cont_id) {
                                        p.items.insert(path, count);
                                    }
                                }
                                ContainerOp::End { area } => {
                                    if let Some(p) = pending_containers.remove(&cont_id) {
                                        let area = if p.area.is_empty() { area } else { p.area };
                                        save.containers.insert(
                                            cont_id.clone(),
                                            SavedContainer {
                                                id: cont_id.clone(),
                                                area: area.clone(),
                                                items: p.items,
                                                last_seen: now_epoch(),
                                            },
                                        );
                                        dirty = true;
                                        if let Some(c) = save.containers.get(&cont_id) {
                                            log(&format!(
                                                "contenedor: {} area={} items={}",
                                                cont_id,
                                                area,
                                                c.items.len()
                                            ));
                                        }
                                    }
                                }
                            }
                        } else {
                            // Eventos no-puerta/no-contenedor (INV/STAT/...) se reenvían.
                            for (other_addr, other) in clients.iter() {
                                if other.id != cid {
                                    let _ = socket.send_to(&buf[..n], other_addr);
                                }
                            }
                        }
                    }
                    PKT_CHAT => {
                        if let Some(chat) = parse_chat(&buf[..n]) {
                            let allowed = if let Some(c) = clients.get_mut(&addr) {
                                c.chat_times.retain(|t| {
                                    now.saturating_duration_since(*t) < CHAT_RATE_WINDOW
                                });
                                if c.chat_times.len() >= CHAT_RATE_MAX as usize {
                                    false
                                } else {
                                    c.chat_times.push_back(now);
                                    true
                                }
                            } else {
                                false
                            };
                            if allowed {
                                broadcast_chat(
                                    &socket,
                                    &clients,
                                    &save,
                                    addr,
                                    &cid,
                                    &chat,
                                    config.chat_radius,
                                );
                            } else {
                                log(&format!(
                                    "chat: limite de frecuencia para {}",
                                    fmt_addr(&addr)
                                ));
                            }
                        }
                    }
                    _ => {}
                }
            }
            Err(e) if e.kind() == ErrorKind::WouldBlock || e.kind() == ErrorKind::TimedOut => {}
            Err(e) => {
                log(&format!("error de socket: {e}"));
                break;
            }
        }

        let now = Instant::now();

        if now.saturating_duration_since(last_cleanup) >= Duration::from_secs(1) {
            cleanup(&mut clients, config.timeout);
            last_cleanup = now;
        }

        if now.saturating_duration_since(last_state) >= config.state_interval {
            let recipients: Vec<(SocketAddr, String)> = clients
                .iter()
                .map(|(addr, c)| (*addr, c.id.clone()))
                .collect();
            for (addr, id) in recipients {
                send_state_to(&socket, &config.name, &clients, &save, addr, &id, config.chat_radius);
            }
            last_state = now;
        }

        if dirty && now.saturating_duration_since(last_save) >= config.save_interval {
            save_now(&config.save_path, &mut save);
            dirty = false;
            last_save = now;
        }

        if now.saturating_duration_since(last_stats) >= Duration::from_secs(10) {
            log(&format!(
                "estado: clientes={} jugadores={} puertas={} contenedores={} paquetes={}",
                clients.len(),
                save.players.len(),
                save.doors.len(),
                save.containers.len(),
                packets
            ));
            last_stats = now;
        }
    }

    if stop.load(Ordering::SeqCst) {
        log("senal recibida: guardando y saliendo");
    }
    save_now(&config.save_path, &mut save);
    log(&format!(
        "detenido | guardados={} puertas={} save={}",
        save.players.len(),
        save.doors.len(),
        config.save_path.display()
    ));
}
