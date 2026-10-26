# LC_Coop — instalador para Windows.
# Detecta Steam (registro + libraryfolders.vdf), encuentra el juego,
# copia el mod y el sidecar, y los habilita.
#
# Uso:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install_lc_coop.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File install_lc_coop.ps1 -GameBin "D:\...\Voyage\Binaries\Win64"

param([string]$GameBin = "")

$ErrorActionPreference = "SilentlyContinue"

# --- Raíz del paquete (un nivel arriba de esta carpeta 'windows') ---
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$root      = Split-Path -Parent $scriptDir
$modSrc    = Join-Path $root "mods\LC_Coop"
$sidecarDir = Join-Path $root "sidecar"

if (-not (Test-Path (Join-Path $modSrc "Scripts\main.lua"))) {
    Write-Host "ERROR: no encuentro el mod en: $modSrc"
    Write-Host "Asegurate de descomprimir el .zip COMPLETO y correr el instalador de adentro."
    exit 1
}

# --- Detectar Steam ---
function Get-SteamPath {
    $candidates = @()
    foreach ($key in @("HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam", "HKLM:\SOFTWARE\Valve\Steam")) {
        $v = (Get-ItemProperty -Path $key).SteamPath
        if (-not $v) { $v = (Get-ItemProperty -Path $key).InstallPath }
        if ($v) { $candidates += $v }
    }
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Get-SteamLibraries([string]$steamPath) {
    $libs = @()
    if ($steamPath) {
        $vdf = Join-Path $steamPath "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            $content = Get-Content $vdf -Raw
            foreach ($m in [regex]::Matches($content, '"path"\s+"([^"]+)"')) {
                $p = $m.Groups[1].Value -replace '\\\\', '\'
                if (Test-Path $p) { $libs += $p }
            }
        }
        $libs += $steamPath
    }
    return ($libs | Select-Object -Unique)
}

function Find-GameBin {
    $steam = Get-SteamPath
    if ($steam) { Write-Host "Steam detectado en: $steam" } else { Write-Host "No detecte Steam por registro." }
    $libs = Get-SteamLibraries $steam
    # candidatos por biblioteca
    foreach ($lib in $libs) {
        $cand = Join-Path $lib "steamapps\common\Voyage\Voyage\Binaries\Win64"
        if (Test-Path $cand) { return $cand }
    }
    # candidatos tipicos por si acaso
    $fallbacks = @(
        "${env:ProgramFiles(x86)}\Steam\steamapps\common\Voyage\Voyage\Binaries\Win64",
        "$env:ProgramFiles\Steam\steamapps\common\Voyage\Voyage\Binaries\Win64",
        "D:\SteamLibrary\steamapps\common\Voyage\Voyage\Binaries\Win64",
        "D:\Steam\steamapps\common\Voyage\Voyage\Binaries\Win64",
        "E:\SteamLibrary\steamapps\common\Voyage\Voyage\Binaries\Win64"
    )
    foreach ($c in $fallbacks) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

if (-not $GameBin) { $GameBin = Find-GameBin }

if (-not $GameBin -or -not (Test-Path $GameBin)) {
    Write-Host ""
    Write-Host "No encontre el juego automaticamente."
    Write-Host "La carpeta es la que contiene Voyage.exe (Voyage\Binaries\Win64),"
    Write-Host "dentro de:  <biblioteca Steam>\steamapps\common\Voyage\Voyage\Binaries\Win64"
    $inp = Read-Host "Pega la ruta y apreta Enter (Enter vacio = cancelar)"
    if ($inp) { $GameBin = $inp.Trim('"').Trim() }
    if (-not $GameBin -or -not (Test-Path $GameBin)) {
        Write-Host "Ruta invalida. Saliendo."
        exit 1
    }
}

Write-Host "Juego: $GameBin"

$ue4ss = Join-Path $GameBin "ue4ss"
if (-not (Test-Path $ue4ss)) {
    Write-Host ""
    Write-Host "ERROR: no existe $ue4ss"
    Write-Host "Primero instala UE4SS (Nexus: thelastcaretaker/mods/4) en ESA carpeta."
    exit 1
}

# --- Copiar mod ---
$modDst = Join-Path $ue4ss "Mods\LC_Coop"
New-Item -ItemType Directory -Force -Path $modDst | Out-Null
Copy-Item -Recurse -Force (Join-Path $modSrc "*") $modDst
Write-Host "Mod copiado a: $modDst"

# --- Copiar sidecar a la carpeta del juego (se auto-lanza) ---
if (Test-Path (Join-Path $sidecarDir "coop_net.ps1")) {
    Copy-Item -Force (Join-Path $sidecarDir "coop_net.ps1") $GameBin
    Copy-Item -Force (Join-Path $sidecarDir "run_sidecar.bat") $GameBin
    Write-Host "Sidecar PowerShell copiado a: $GameBin"
}
# El modo servidor (server:host:puerto) y el chat necesitan el sidecar Python.
if (Test-Path (Join-Path $sidecarDir "coop_net.py")) {
    Copy-Item -Force (Join-Path $sidecarDir "coop_net.py") $GameBin
    foreach ($bat in @("run_sidecar_server.bat", "run_sidecar_auto.bat")) {
        if (Test-Path (Join-Path $sidecarDir $bat)) {
            Copy-Item -Force (Join-Path $sidecarDir $bat) $GameBin
        }
    }
    Write-Host "Sidecar Python + lanzadores copiados a: $GameBin"
}
if (-not (Get-Command python -ErrorAction SilentlyContinue) -and -not (Get-Command py -ErrorAction SilentlyContinue)) {
    Write-Host "AVISO: Python 3 no encontrado. P2P usara PowerShell; server: y chat requieren Python."
}

# --- Habilitar en mods.txt ---
$modsTxt = Join-Path $ue4ss "Mods\mods.txt"
if (-not (Select-String -Path $modsTxt -Pattern '^\s*LC_Coop\s*:' -Quiet)) {
    Add-Content -Path $modsTxt -Value "LC_Coop : 1"
}
Write-Host "Habilitado en mods.txt"

# --- Habilitar en mods.json ---
$modsJson = Join-Path $ue4ss "Mods\mods.json"
if (Test-Path $modsJson) {
    try {
        $json = @(Get-Content $modsJson -Raw | ConvertFrom-Json)
        $found = $false
        foreach ($e in $json) { if ($e.mod_name -eq "LC_Coop") { $e.mod_enabled = $true; $found = $true } }
        if (-not $found) { $json += [pscustomobject]@{ mod_name = "LC_Coop"; mod_enabled = $true } }
        $json | ConvertTo-Json -Depth 5 | Set-Content $modsJson
        Write-Host "Habilitado en mods.json"
    } catch { Write-Host "(no pude editar mods.json; revisalo a mano)" }
}

Write-Host ""
Write-Host "LISTO. El sidecar se auto-lanza desde el juego (no hace falta terminal)."
Write-Host "Para jugar P2P:"
Write-Host "  1) Lanza The Last Caretaker."
Write-Host "  2) En el juego: F9, escribe la IP del otro jugador, clic en Conectar."
Write-Host ""
Write-Host "Para el servidor dedicado (server:host:puerto) o chat:"
Write-Host "  - Instala Python 3 (marca 'Add Python to PATH')."
Write-Host "  - En config.lua: autoStartSidecar = false."
Write-Host "  - Corre: run_sidecar_server.bat `"$GameBin`""
Write-Host "  - En el juego: F9 -> server:server.jeba.cc:8766"
