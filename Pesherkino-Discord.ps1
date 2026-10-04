[CmdletBinding()]
param(
    [ValidateSet("Menu","Install","Repair","Uninstall","Status","Info")]
    [string]$Action = "Menu"
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = "Pesherkino Discord" } catch {}

$ProxyHost = "dearly.netherus.com"
$ProxyPort = 5555
$ProxyUri = "http://" + $ProxyHost + ":" + $ProxyPort

$ReleaseApi = "https://api.github.com/repos/hdrover/discord-drover/releases/latest"
$LocalDir = Join-Path $env:LOCALAPPDATA "Pesherkino\DiscordDrover"

function Write-C {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Write-Host $Text -ForegroundColor $Color
}

function Show-Header {
    Clear-Host
    Write-C "============================================================" Cyan
    Write-C "                  PESHERKINO DISCORD" Cyan
    Write-C "============================================================" Cyan
    Write-Host ""
    Write-C "Discord через отдельный Pesherkino proxy" White
    Write-Host ""
    Write-C "ВАЖНО:" Yellow
    Write-C "  • Не работает совместно с Zapret." Yellow
    Write-C "  • Не используйте одновременно с VPN в TUN-режиме." Yellow
    Write-C "  • Это не системный VPN и не меняет proxy Windows." DarkGray
    Write-Host ""
}

function Get-DiscordDirs {
    $roots = @(
        (Join-Path $env:LOCALAPPDATA "Discord"),
        (Join-Path $env:LOCALAPPDATA "DiscordCanary"),
        (Join-Path $env:LOCALAPPDATA "DiscordPTB")
    )

    $exeNames = @("Discord.exe","DiscordCanary.exe","DiscordPTB.exe")
    $dirs = New-Object System.Collections.Generic.List[string]

    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }

        Get-ChildItem -Path $root -Directory -Filter "app-*" -ErrorAction SilentlyContinue | ForEach-Object {
            $dir = $_.FullName
            foreach ($exe in $exeNames) {
                if (Test-Path (Join-Path $dir $exe)) {
                    if (-not $dirs.Contains($dir)) { $dirs.Add($dir) }
                    break
                }
            }
        }
    }

    return @($dirs)
}

function Stop-Discord {
    foreach ($name in @("Discord","DiscordCanary","DiscordPTB")) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 800
}

function Test-ProxyPort {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($ProxyHost,$ProxyPort,$null,$null)

        if (-not $async.AsyncWaitHandle.WaitOne(5000,$false)) {
            $client.Close()
            return $false
        }

        $client.EndConnect($async)
        $client.Close()
        return $true
    }
    catch {
        return $false
    }
}

function Download-Drover {
    param([Parameter(Mandatory=$true)][string]$WorkDir)

    $headers = @{
        "User-Agent" = "Pesherkino-Discord-Installer"
        "Accept" = "application/vnd.github+json"
    }

    Write-C "[*] Получаю последний релиз Discord Drover..." Cyan
    $release = Invoke-RestMethod -Uri $ReleaseApi -Headers $headers

    $asset = $release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
    if (-not $asset) { throw "В latest release Discord Drover не найден ZIP-файл." }

    Write-C ("[*] Версия: " + $release.tag_name) Cyan

    $zip = Join-Path $WorkDir $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -Headers $headers -UseBasicParsing

    if ($asset.digest -and ([string]$asset.digest).StartsWith("sha256:")) {
        $expected = ([string]$asset.digest).Substring(7).ToLowerInvariant()
        $actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLowerInvariant()

        if ($actual -ne $expected) { throw "SHA256 Discord Drover не совпал." }
        Write-C "[OK] SHA256 релиза проверен." Green
    }

    $extractDir = Join-Path $WorkDir "drover"
    Expand-Archive -Path $zip -DestinationPath $extractDir -Force

    $dll = Get-ChildItem -Path $extractDir -Recurse -File -Filter "version.dll" | Select-Object -First 1
    if (-not $dll) { throw "В архиве Discord Drover не найден version.dll." }

    $packet = Get-ChildItem -Path $extractDir -Recurse -File -Filter "drover-packet.bin" | Select-Object -First 1

    return @{
        Version = $release.tag_name
        Dll = $dll.FullName
        Packet = if ($packet) { $packet.FullName } else { $null }
    }
}

function Save-LocalCopy {
    try {
        New-Item -ItemType Directory -Path $LocalDir -Force | Out-Null
        if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
            Copy-Item -Path $PSCommandPath -Destination (Join-Path $LocalDir "Pesherkino-Discord.ps1") -Force
        }
    }
    catch {}
}

function Install-PesherkinoDiscord {
    Show-Header

    Write-C ("[*] Проверяю " + $ProxyHost + ":" + $ProxyPort + "...") Cyan
    if (-not (Test-ProxyPort)) {
        Write-C "[ERROR] Сервер Pesherkino Discord сейчас недоступен." Red
        Write-C "Поддержка: @pesherkino_support" Yellow
        return
    }

    Write-C "[OK] Сервер доступен." Green

    $dirs = @(Get-DiscordDirs)
    if ($dirs.Count -eq 0) {
        Write-C "[ERROR] Discord Stable / PTB / Canary не найден." Red
        Write-C "Сначала установи и хотя бы один раз запусти Discord." Yellow
        return
    }

    Write-C "[*] Закрываю Discord..." Cyan
    Stop-Discord

    $work = Join-Path ([IO.Path]::GetTempPath()) ("pesherkino-drover-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    try {
        $files = Download-Drover -WorkDir $work
        $ini = "[drover]" + [Environment]::NewLine + "proxy = " + $ProxyUri + [Environment]::NewLine
        $count = 0

        foreach ($dir in $dirs) {
            Write-C ("[*] Устанавливаю в: " + $dir) Cyan

            [IO.File]::WriteAllText((Join-Path $dir "drover.ini"),$ini,[Text.Encoding]::ASCII)
            Copy-Item -Path $files.Dll -Destination (Join-Path $dir "version.dll") -Force

            if ($files.Packet) {
                Copy-Item -Path $files.Packet -Destination (Join-Path $dir "drover-packet.bin") -Force
            }

            $count++
        }

        Save-LocalCopy

        Write-Host ""
        Write-C "[OK] Pesherkino Discord установлен." Green
        Write-C ("[OK] Discord Drover: " + $files.Version) Green
        Write-C ("[OK] Обработано папок Discord: " + $count) Green
        Write-Host ""
        Write-C "Теперь запусти Discord обычным способом." White
        Write-C "Если после обновления Discord перестанет работать — выбери Repair." DarkGray
    }
    catch {
        Write-C ("[ERROR] " + $_.Exception.Message) Red
    }
    finally {
        Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Uninstall-PesherkinoDiscord {
    Show-Header
    Stop-Discord

    $dirs = @(Get-DiscordDirs)
    $count = 0

    foreach ($dir in $dirs) {
        $iniPath = Join-Path $dir "drover.ini"
        $ours = $false

        if (Test-Path $iniPath) {
            try {
                $content = Get-Content -Path $iniPath -Raw
                if ($content -match [regex]::Escape($ProxyHost)) { $ours = $true }
            }
            catch {}
        }

        if ($ours) {
            foreach ($name in @("drover.ini","version.dll","drover-packet.bin")) {
                $path = Join-Path $dir $name
                if (Test-Path $path) { Remove-Item -Path $path -Force -ErrorAction SilentlyContinue }
            }
            $count++
        }
    }

    if (Test-Path $LocalDir) {
        Remove-Item -Path $LocalDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-C ("[OK] Pesherkino Discord удалён. Обработано папок: " + $count) Green
}

function Show-Status {
    Show-Header

    Write-C ("Proxy: " + $ProxyHost + ":" + $ProxyPort) White
    if (Test-ProxyPort) { Write-C "Сервер: доступен" Green }
    else { Write-C "Сервер: недоступен" Red }

    Write-Host ""

    $dirs = @(Get-DiscordDirs)
    if ($dirs.Count -eq 0) {
        Write-C "Discord не найден." Yellow
        return
    }

    foreach ($dir in $dirs) {
        $ini = Join-Path $dir "drover.ini"
        $dll = Join-Path $dir "version.dll"
        $packet = Join-Path $dir "drover-packet.bin"

        if ((Test-Path $ini) -and (Test-Path $dll)) {
            Write-C ("[OK] " + $dir) Green
            if (Test-Path $packet) { Write-C "     drover-packet.bin: установлен" DarkGray }
        }
        else {
            Write-C ("[--] " + $dir) DarkGray
        }
    }
}

function Show-Info {
    Show-Header

    Write-C "Что делает Pesherkino Discord" White
    Write-Host ""
    Write-Host "  Discord Drover заставляет только приложение Discord использовать"
    Write-Host "  отдельный HTTP proxy для TCP-соединений."
    Write-Host ""
    Write-Host "  Сервер разрешает через proxy только Discord-домены."
    Write-Host "  Обычные сайты через него заблокированы."
    Write-Host ""
    Write-C "Совместимость" Yellow
    Write-Host ""
    Write-Host "  • Не работает совместно с Zapret."
    Write-Host "  • Не используйте одновременно с VPN в TUN-режиме."
    Write-Host ""
    Write-C "Pesherkino VPN" Cyan
    Write-Host ""
    Write-Host "  Если нужен полноценный VPN для всего устройства:"
    Write-Host "  Бот:       https://t.me/pesherkino_bot"
    Write-Host "  Новости:   https://t.me/pesherkinonews"
    Write-Host "  Поддержка: https://t.me/pesherkino_support"
    Write-Host ""
    Write-C "Discord Drover" Cyan
    Write-Host "  https://github.com/hdrover/discord-drover"
}

function Show-Menu {
    while ($true) {
        Show-Header

        Write-C "1. Установить / обновить" White
        Write-C "2. Repair" White
        Write-C "3. Удалить" White
        Write-C "4. Статус" White
        Write-C "5. Информация / Pesherkino VPN" White
        Write-C "0. Выход" DarkGray
        Write-Host ""

        switch (Read-Host "Выберите действие") {
            "1" { Install-PesherkinoDiscord; Read-Host "Enter для продолжения" | Out-Null }
            "2" { Install-PesherkinoDiscord; Read-Host "Enter для продолжения" | Out-Null }
            "3" { Uninstall-PesherkinoDiscord; Read-Host "Enter для продолжения" | Out-Null }
            "4" { Show-Status; Read-Host "Enter для продолжения" | Out-Null }
            "5" { Show-Info; Read-Host "Enter для продолжения" | Out-Null }
            "0" { return }
        }
    }
}

switch ($Action) {
    "Install"   { Install-PesherkinoDiscord }
    "Repair"    { Install-PesherkinoDiscord }
    "Uninstall" { Uninstall-PesherkinoDiscord }
    "Status"    { Show-Status }
    "Info"      { Show-Info }
    default     { Show-Menu }
}
