// LC_Coop — relay UDP standalone (Rust).
//
// Reenvía cada datagrama a los demás clientes. Una sola "sala" por instancia.
// Pensado para correr en un servidor/VPS sin Python ni Docker.
//
// Uso:
//   lc-coop-relay [PUERTO]
//   PORT=27020 TIMEOUT=30 lc-coop-relay
//
// Compilar estático:
//   cargo build --release --target x86_64-unknown-linux-musl

use socket2::{Domain, Protocol, Socket, Type};
use std::collections::HashMap;
use std::env;
use std::io::{self, ErrorKind};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};
use std::process;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const VERSION: &str = env!("CARGO_PKG_VERSION");

fn timestamp() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{:02}:{:02}:{:02}", (secs / 3600) % 24, (secs / 60) % 60, secs % 60)
}

fn log(msg: &str) {
    println!("[LC_Coop-relay] {} {}", timestamp(), msg);
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

fn usage(program: &str) {
    println!("LC_Coop relay {VERSION}");
    println!("Uso: {program} [PUERTO]");
    println!("  PUERTO            UDP (default: env PORT o 27020)");
    println!("  TIMEOUT=segundos  inactividad para olvidar un cliente (default 30)");
    println!("  -h, --help        esta ayuda");
    println!("  -V, --version     version");
}

fn make_socket(port: u16) -> io::Result<(UdpSocket, bool)> {
    // Intento dual-stack (IPv4 + IPv6).
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

    // Fallback IPv4.
    let sock = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
    let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), port);
    let sa: socket2::SockAddr = addr.into();
    sock.bind(&sa)?;
    Ok((sock.into(), false))
}

fn cleanup(clients: &mut HashMap<SocketAddr, Instant>, timeout: Duration) {
    let now = Instant::now();
    let expired: Vec<SocketAddr> = clients
        .iter()
        .filter(|(_, seen)| now.saturating_duration_since(**seen) > timeout)
        .map(|(addr, _)| *addr)
        .collect();

    for addr in expired {
        clients.remove(&addr);
        log(&format!(
            "cliente expirado: {} (total={})",
            fmt_addr(&addr),
            clients.len()
        ));
    }
}

fn main() {
    let program = env::args()
        .next()
        .unwrap_or_else(|| "lc-coop-relay".to_string());

    let mut port: u16 = env::var("PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(27020);
    let timeout_secs: u64 = env::var("TIMEOUT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(30);

    for arg in env::args().skip(1) {
        match arg.as_str() {
            "-h" | "--help" => {
                usage(&program);
                return;
            }
            "-V" | "--version" => {
                println!("lc-coop-relay {VERSION}");
                return;
            }
            other => match other.parse::<u16>() {
                Ok(p) => port = p,
                Err(_) => {
                    eprintln!("puerto invalido: {other}");
                    usage(&program);
                    process::exit(2);
                }
            },
        }
    }

    let timeout = Duration::from_secs(timeout_secs.max(1));
    let (socket, dual) = match make_socket(port) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("no pude bindear UDP :{port}: {e}");
            process::exit(1);
        }
    };
    let _ = socket.set_read_timeout(Some(Duration::from_secs(1)));

    log(&format!(
        "escuchando en :{port} ({}) timeout={}s",
        if dual { "IPv4+IPv6" } else { "IPv4" },
        timeout_secs.max(1)
    ));

    let mut clients: HashMap<SocketAddr, Instant> = HashMap::new();
    let mut buf = [0u8; 2048];

    loop {
        match socket.recv_from(&mut buf) {
            Ok((n, addr)) => {
                if n == 0 {
                    cleanup(&mut clients, timeout);
                    continue;
                }

                let is_new = clients.insert(addr, Instant::now()).is_none();
                if is_new {
                    log(&format!(
                        "cliente conectado: {} (total={})",
                        fmt_addr(&addr),
                        clients.len()
                    ));
                }

                // Reenviar a los demás (sin salas, como el relay Python).
                for (&client, _) in clients.iter() {
                    if client != addr {
                        let _ = socket.send_to(&buf[..n], client);
                    }
                }

                cleanup(&mut clients, timeout);
            }
            Err(e) if e.kind() == ErrorKind::WouldBlock || e.kind() == ErrorKind::TimedOut => {
                cleanup(&mut clients, timeout);
            }
            Err(e) => {
                log(&format!("error de socket: {e}"));
                break;
            }
        }
    }
}
