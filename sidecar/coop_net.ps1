# LC_Coop — sidecar de red en PowerShell (viene en Windows, no instala nada).
# Lee la IP/nombre de lc_peer.txt (lo escribe el juego con `lc_connect <IP|dominio>`).
# Soporta IPv4, IPv6 y nombres/dominios (Tailscale MagicDNS).

param(
    [string]$Dir = ".",
    [string]$PeerFile = "lc_peer.txt",
    [int]$Port = 27015,
    [int]$PeerPort = 0,
    [switch]$WatchGame
)

$ErrorActionPreference = "SilentlyContinue"
if ($PeerPort -le 0) { $PeerPort = $Port }

$coordsOut = Join-Path $Dir "coords_out.txt"
$coordsIn  = Join-Path $Dir "coords_in.txt"
$eventOut  = Join-Path $Dir "event_out.txt"
$eventIn   = Join-Path $Dir "event_in.txt"
$peerPath  = Join-Path $Dir $PeerFile
$logPath   = Join-Path $Dir "lc_sidecar.log"

function Write-Log([string]$m) {
    Write-Host $m
    try { Add-Content -Path $logPath -Value ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m) } catch {}
}

Write-Log "[LC_Coop-ps] escuchando UDP $Port (IPv4+IPv6) | dir=$Dir"

# Socket dual-stack
try {
    $sock = New-Object System.Net.Sockets.Socket(
        [System.Net.Sockets.AddressFamily]::InterNetworkV6,
        [System.Net.Sockets.SocketType]::Dgram,
        [System.Net.Sockets.ProtocolType]::Udp)
    $sock.DualMode = $true
    $sock.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::IPv6Any, $Port)))
} catch {
    $sock = New-Object System.Net.Sockets.Socket(
        [System.Net.Sockets.AddressFamily]::InterNetwork,
        [System.Net.Sockets.SocketType]::Dgram,
        [System.Net.Sockets.ProtocolType]::Udp)
    $sock.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $Port)))
}
$sock.ReceiveTimeout = 50

$remote = $null
$replyAddr = $null
$lastPeer = ""
$gameGone = 0
$gameSeen = $false
$lastGameCheck = Get-Date

# Handshake liviano (HELLO/ACK) y estado visible para el menú F9.
$clientId = -join ((1..12) | ForEach-Object { "0123456789abcdef"[(Get-Random -Maximum 16)] })
$clientName = $env:COMPUTERNAME
if (-not $clientName) { $clientName = [System.Net.Dns]::GetHostName() }
$clientName = ($clientName -replace '[;\r\n]', '')
if (-not $clientName) { $clientName = "lc-client" }
if ($clientName.Length -gt 32) { $clientName = $clientName.Substring(0, 32) }
$statusPath = Join-Path $Dir "lc_net_status.txt"
$lastHelloSent = [DateTime]::MinValue
$lastStatusWrite = [DateTime]::MinValue
$lastAck = $null
$lastHelloRx = $null
$lastRx = $null
$lastPos = $null
$peerName = ""
$lastState = ""
$txPos = 0; $txEvent = 0
$rxPos = 0; $rxEvent = 0; $rxAck = 0; $rxHello = 0

function Clean-Host([string]$h) {
    if (-not $h) { return "" }
    $h = $h.Trim().Trim('"').Trim("'")
    # IPv6 entre corchetes: [fd7a::1] o [fd7a::1]:27015
    if ($h -match '^\[([0-9A-Fa-f:.]+)\](?::\d+)?$') { return $matches[1] }
    # quitar puerto pegado (solo si no es IPv6, que tiene 2+ ':')
    $parts = $h.Split(':')
    if ($parts.Count -eq 2 -and $parts[1] -match '^\d+$') { $h = $parts[0] }
    # extraer IPv4 si viene con basura; si no, dejar tal cual (IPv6/dominio)
    $m = [regex]::Match($h, '([0-9]{1,3}\.){3}[0-9]{1,3}')
    if ($m.Success) { return $m.Value }
    return ($h -replace '\s', '')
}

function Resolve-Addr([string]$hostname) {
    try { $addrs = [System.Net.Dns]::GetHostAddresses($hostname) } catch { return $null }
    $v4 = $addrs | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork }
    if ($v4) { return $v4[0] }
    if ($addrs) { return $addrs[0] }
    return $null
}

function Same-IP($a, $b) {
    if (-not $a -or -not $b) { return $false }
    $sa = $a.ToString(); $sb = $b.ToString()
    if ($sa.StartsWith("::ffff:")) { $sa = $sa.Substring(7) }
    if ($sb.StartsWith("::ffff:")) { $sb = $sb.Substring(7) }
    return ($sa -eq $sb)
}

function Get-Target {
    # Preferir replyAddr solo si es el peer configurado (NAT/puerto real).
    if ($remote) {
        if ($replyAddr -and (Same-IP $replyAddr.Address $remote.Address)) { return $replyAddr }
        return $remote
    }
    if ($replyAddr) { return $replyAddr }
    return $null
}

function Send-Bytes([byte[]]$bytes) {
    $target = Get-Target
    if ($target) { try { [void]$sock.SendTo($bytes, $target) } catch {} }
}

function Make-Handshake([byte]$kind, [string]$targetId = "") {
    $txt = "LCCOOP/1;$clientId;$clientName;$targetId"
    $b = [System.Text.Encoding]::UTF8.GetBytes($txt)
    $pkt = New-Object byte[] ($b.Length + 1)
    $pkt[0] = $kind
    $b.CopyTo($pkt, 1)
    return ,$pkt
}

function Parse-Handshake([byte[]]$data) {
    if (-not $data -or $data.Length -lt 2) { return $null }
    $text = [System.Text.Encoding]::UTF8.GetString($data, 1, $data.Length - 1).Trim()
    $parts = $text.Split(";")
    if ($parts.Length -lt 3 -or $parts[0] -ne "LCCOOP/1") { return $null }
    $target = ""
    if ($parts.Length -gt 3) { $target = $parts[3] }
    return [pscustomobject]@{ Id = $parts[1]; Name = $parts[2]; Target = $target }
}

function Format-EndPoint($ep) {
    if (-not $ep) { return "" }
    $addr = $ep.Address.ToString()
    if ($addr.StartsWith("::ffff:")) { $addr = $addr.Substring(7) }
    if ($addr.Contains(":")) { return "[${addr}]:$($ep.Port)" }
    return "${addr}:$($ep.Port)"
}

function Get-NetState {
    if (-not $remote -and -not $replyAddr) { return "no_peer" }
    if ($lastAck -and ((Get-Date) - $lastAck).TotalSeconds -le 5) { return "confirmed" }
    if ($lastRx -and ((Get-Date) - $lastRx).TotalSeconds -le 5) { return "one_way" }
    return "waiting"
}

function Write-NetStatus([string]$stateOverride = "") {
    $now = Get-Date
    $state = $stateOverride
    if (-not $state) { $state = Get-NetState }
    $addr = ""
    if ($replyAddr) { $addr = Format-EndPoint $replyAddr }
    elseif ($remote) { $addr = Format-EndPoint $remote }
    $ackAge = if ($lastAck) { [math]::Round(($now - $lastAck).TotalSeconds, 1) } else { -1 }
    $rxAge = if ($lastRx) { [math]::Round(($now - $lastRx).TotalSeconds, 1) } else { -1 }
    $posAge = if ($lastPos) { [math]::Round(($now - $lastPos).TotalSeconds, 1) } else { -1 }
    $confirmed = if ($state -eq "confirmed") { 1 } else { 0 }
    $epoch = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $lines = @(
        "version=1",
        "ts=$epoch",
        "state=$state",
        "peer=$lastPeer",
        "peer_addr=$addr",
        "peer_name=$peerName",
        "client_id=$clientId",
        "client_name=$clientName",
        "listen_port=$Port",
        "confirmed=$confirmed",
        "last_ack_age=$ackAge",
        "last_rx_age=$rxAge",
        "last_pos_age=$posAge",
        "tx_pos=$txPos",
        "tx_event=$txEvent",
        "rx_pos=$rxPos",
        "rx_event=$rxEvent",
        "rx_ack=$rxAck",
        "rx_hello=$rxHello"
    )
    $tmp = "$statusPath.tmp"
    try {
        [System.IO.File]::WriteAllText($tmp, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding -ArgumentList $false))
        Move-Item -Force $tmp $statusPath
    } catch {}
}

while ($true) {
    # 0) si nos pidieron, salir cuando cierre el juego
    if ($WatchGame -and ((Get-Date) - $lastGameCheck).TotalSeconds -ge 3) {
        $lastGameCheck = Get-Date
        $proc = Get-Process -Name "VoyageSteam-Win64-Shipping","Voyage" -ErrorAction SilentlyContinue
        if ($proc) {
            $gameSeen = $true
            $gameGone = 0
        } elseif ($gameSeen) {
            # Solo salimos si antes vimos el juego (sirve si se lanza a mano).
            $gameGone++
            if ($gameGone -ge 2) { Write-Log "[LC_Coop-ps] el juego se cerro: salgo"; break }
        }
    }

    # 1) refrescar peer
    if (Test-Path $peerPath) {
        $ip = Clean-Host (Get-Content $peerPath -Raw)
        if ($ip -ne $lastPeer) {
            $lastPeer = $ip
            # Al cambiar de peer, no seguir respondiendo al replyAddr viejo.
            $replyAddr = $null
            $lastAck = $null
            $lastRx = $null
            $lastPos = $null
            $peerName = ""
            $lastState = ""
            if ($ip) {
                $addr = Resolve-Addr $ip
                if ($addr -and [System.Net.IPAddress]::IsLoopback($addr)) {
                    $remote = $null
                    Write-Log "[LC_Coop-ps] '$ip' es esta misma PC: ignoro (evita loopback)"
                } elseif ($addr) {
                    $remote = New-Object System.Net.IPEndPoint($addr, $PeerPort)
                    Write-Log "[LC_Coop-ps] peer = $($addr.IPAddressToString):$PeerPort"
                } else {
                    $remote = $null
                    Write-Log "[LC_Coop-ps] no pude resolver: [$ip]  (len=$($ip.Length))"
                }
            } else {
                $remote = $null
                Write-Log "[LC_Coop-ps] peer vacio (desconectado)"
            }
        }
    }

    # 2) recibir
    try {
        [System.Net.EndPoint]$ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::IPv6Any, 0)
        $buf = New-Object byte[] 2048
        $n = $sock.ReceiveFrom($buf, [ref]$ep)
        $remoteEp = [System.Net.IPEndPoint]$ep
        $data = $null
        if ($n -gt 0) { [byte[]]$data = $buf[0..($n - 1)] }
        $fromLoopback = $false
        if ($remoteEp -and $remoteEp.Address) {
            $fromAddr = $remoteEp.Address
            if ($fromAddr.IsIPv4MappedToIPv6) { $fromAddr = $fromAddr.MapToIPv4() }
            $fromLoopback = [System.Net.IPAddress]::IsLoopback($fromAddr)
            if (-not $fromLoopback) {
                $replyAddr = $remoteEp
                $lastRx = Get-Date
            }
        }
        if ($data -and $data.Length -ge 1) {
            if ($data[0] -eq 3) {
                $h = Parse-Handshake $data
                if ($h) {
                    $rxHello++
                    $lastHelloRx = Get-Date
                    if (-not $fromLoopback) { $peerName = $h.Name }
                    $ack = Make-Handshake 4 $h.Id
                    try { [void]$sock.SendTo($ack, $remoteEp) } catch {}
                    if (-not $fromLoopback) {
                        Write-Log "[LC_Coop-ps] HELLO de $(Format-EndPoint $remoteEp) ($($h.Name)); ACK"
                    }
                }
            }
            elseif ($data[0] -eq 4) {
                $h = Parse-Handshake $data
                if ($h -and (-not $h.Target -or $h.Target -eq $clientId)) {
                    $rxAck++
                    if (-not $fromLoopback) {
                        $lastAck = Get-Date
                        $peerName = $h.Name
                    }
                }
            }
            elseif ($data[0] -eq 1 -and $data.Length -ge 21) {
                $x = [BitConverter]::ToSingle($data, 1)
                $y = [BitConverter]::ToSingle($data, 5)
                $z = [BitConverter]::ToSingle($data, 9)
                $yaw = [BitConverter]::ToSingle($data, 13)
                $seq = [BitConverter]::ToUInt32($data, 17)
                Set-Content -Path $coordsIn -Value "$x,$y,$z,$yaw,$seq" -NoNewline
                $rxPos++
                $lastPos = Get-Date
            }
            elseif ($data[0] -eq 2 -and $data.Length -gt 1) {
                $text = [System.Text.Encoding]::UTF8.GetString($data, 1, $data.Length - 1).Trim()
                if ($text) {
                    Add-Content -Path $eventIn -Value $text
                    $rxEvent++
                }
            }
        }
    } catch {}

    # 3) HELLO periódico (confirmar que el otro lado está escuchando)
    $target = Get-Target
    if ($target -and ((Get-Date) - $lastHelloSent).TotalSeconds -ge 2) {
        $lastHelloSent = Get-Date
        Send-Bytes (Make-Handshake 3)
    }

    # 4) enviar posicion (también si solo tenemos replyAddr, sin peer file)
    if ($target -and (Test-Path $coordsOut)) {
        $txt = (Get-Content $coordsOut -Raw).Trim()
        if ($txt) {
            $parts = $txt.Split(",")
            if ($parts.Length -ge 3) {
                $x = [single]$parts[0]; $y = [single]$parts[1]; $z = [single]$parts[2]
                $yaw = 0.0; if ($parts.Length -gt 3 -and $parts[3]) { $yaw = [single]$parts[3] }
                $seq = [uint32]0; if ($parts.Length -gt 4 -and $parts[4]) { $seq = [uint32]$parts[4] }
                $pkt = New-Object byte[] 21
                $pkt[0] = 1
                [BitConverter]::GetBytes($x).CopyTo($pkt, 1)
                [BitConverter]::GetBytes($y).CopyTo($pkt, 5)
                [BitConverter]::GetBytes($z).CopyTo($pkt, 9)
                [BitConverter]::GetBytes($yaw).CopyTo($pkt, 13)
                [BitConverter]::GetBytes($seq).CopyTo($pkt, 17)
                Send-Bytes $pkt
                $txPos++
            }
        }
    }

    # 5) enviar eventos
    if ($target -and (Test-Path $eventOut)) {
        $lines = Get-Content $eventOut
        if ($lines) {
            Clear-Content $eventOut
            foreach ($line in $lines) {
                $line = $line.Trim()
                if ($line) {
                    $b = [System.Text.Encoding]::UTF8.GetBytes($line)
                    $pkt = New-Object byte[] ($b.Length + 1)
                    $pkt[0] = 2
                    $b.CopyTo($pkt, 1)
                    Send-Bytes $pkt
                    $txEvent++
                }
            }
        }
    }

    # 6) estado para el menú F9
    if (((Get-Date) - $lastStatusWrite).TotalSeconds -ge 1) {
        $lastStatusWrite = Get-Date
        $state = Get-NetState
        if ($state -ne $lastState) {
            $lastState = $state
            if ($state -eq "confirmed") {
                Write-Log "[LC_Coop-ps] peer confirmado (escuchando): $peerName"
            } elseif ($state -eq "one_way") {
                Write-Log "[LC_Coop-ps] recibo del peer pero sin ACK: posible firewall"
            } elseif ($state -eq "waiting") {
                Write-Log "[LC_Coop-ps] esperando respuesta del peer..."
            }
        }
        Write-NetStatus
    }

    Start-Sleep -Milliseconds 33
}

Write-NetStatus "stopped"
