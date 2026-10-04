[CmdletBinding()]
param(
    [ValidateSet("Menu","Install","Repair","Uninstall","Status","Info")]
    [string]$Action = "Menu"
)

$ErrorActionPreference = "Stop"
try { $Host.UI.RawUI.WindowTitle = "Pesherkino Discord" } catch {}

$ProxyHost = "dearly.netherus.com"
$ProxyPort = 5555
$ProxyUri  = "http://" + $ProxyHost + ":" + $ProxyPort

$ReleaseApi = "https://api.github.com/repos/hdrover/discord-drover/releases/latest"
$LocalDir   = Join-Path $env:LOCALAPPDATA "Pesherkino\DiscordDrover"

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

function Add-UniquePath {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    try {
        $full = [IO.Path]::GetFullPath(
            [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
        ).TrimEnd('\')
    }
    catch { return }

    if (-not (Test-Path -LiteralPath $full -PathType Container)) { return }

    if (-not $List.Contains($full)) {
        $List.Add($full)
    }
}

function Add-RootFromExecutable {
    param(
        [System.Collections.Generic.List[string]]$Roots,
        [string]$ExecutablePath
    )

    if ([string]::IsNullOrWhiteSpace($ExecutablePath)) { return }

    $exe = [Environment]::ExpandEnvironmentVariables($ExecutablePath.Trim().Trim('"'))
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return }

    $dir = Split-Path -Parent $exe
    $name = [IO.Path]::GetFileName($exe)

    if ($name -ieq "Update.exe") {
        Add-UniquePath -List $Roots -Path $dir
        return
    }

    if ($name -in @("Discord.exe","DiscordCanary.exe","DiscordPTB.exe")) {
        $leaf = Split-Path -Leaf $dir
        if ($leaf -like "app-*") {
            Add-UniquePath -List $Roots -Path (Split-Path -Parent $dir)
        }
        else {
            Add-UniquePath -List $Roots -Path $dir
        }
    }
}

function Add-RootFromCommand {
    param(
        [System.Collections.Generic.List[string]]$Roots,
        [string]$Command
    )

    if ([string]::IsNullOrWhiteSpace($Command)) { return }

    $exe = $null

    if ($Command -match '^\s*"([^"]+\.exe)"') {
        $exe = $Matches[1]
    }
    elseif ($Command -match '^\s*([^\s]+\.exe)') {
        $exe = $Matches[1]
    }

    if ($exe) {
        Add-RootFromExecutable -Roots $Roots -ExecutablePath $exe
    }
}

function Get-DiscordBaseDirs {
    $roots = New-Object System.Collections.Generic.List[string]

    foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA "Discord"),
        (Join-Path $env:LOCALAPPDATA "DiscordCanary"),
        (Join-Path $env:LOCALAPPDATA "DiscordPTB")
    )) {
        Add-UniquePath -List $roots -Path $p
    }

    foreach ($key in @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Discord",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DiscordCanary",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DiscordPTB"
    )) {
        if (-not (Test-Path $key)) { continue }

        try {
            $item = Get-ItemProperty -Path $key -ErrorAction Stop

            if ($item.InstallLocation) {
                $loc = [Environment]::ExpandEnvironmentVariables([string]$item.InstallLocation)
                $leaf = Split-Path -Leaf ($loc.TrimEnd('\'))

                if ($leaf -like "app-*") {
                    Add-UniquePath -List $roots -Path (Split-Path -Parent $loc)
                }
                else {
                    Add-UniquePath -List $roots -Path $loc
                }
            }

            if ($item.UninstallString) {
                Add-RootFromCommand -Roots $roots -Command ([string]$item.UninstallString)
            }
        }
        catch {}
    }

    foreach ($key in @(
        "HKCU:\Software\Classes\Discord\shell\open\command",
        "HKCU:\Software\Classes\DiscordCanary\shell\open\command",
        "HKCU:\Software\Classes\DiscordPTB\shell\open\command"
    )) {
        if (-not (Test-Path $key)) { continue }

        try {
            $command = (Get-Item -Path $key -ErrorAction Stop).GetValue("")
            Add-RootFromCommand -Roots $roots -Command ([string]$command)
        }
        catch {}
    }

    try {
        Get-ChildItem -Path $env:LOCALAPPDATA -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "Discord*" } |
            ForEach-Object {
                if ((Test-Path (Join-Path $_.FullName "Update.exe")) -or
                    (Get-ChildItem -Path $_.FullName -Directory -Filter "app-*" -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                    Add-UniquePath -List $roots -Path $_.FullName
                }
            }
    }
    catch {}

    return @($roots)
}

function Get-DiscordDirs {
    $dirs = New-Object System.Collections.Generic.List[string]
    $exeNames = @("Discord.exe","DiscordCanary.exe","DiscordPTB.exe")

    foreach ($root in @(Get-DiscordBaseDirs)) {
        foreach ($exe in $exeNames) {
            if (Test-Path -LiteralPath (Join-Path $root $exe) -PathType Leaf) {
                Add-UniquePath -List $dirs -Path $root
                break
            }
        }

        try {
            Get-ChildItem -Path $root -Directory -Filter "app-*" -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $dir = $_.FullName
                    foreach ($exe in $exeNames) {
                        if (Test-Path -LiteralPath (Join-Path $dir $exe) -PathType Leaf) {
                            Add-UniquePath -List $dirs -Path $dir
                            break
                        }
                    }
                }
        }
        catch {}
    }

    return @($dirs)
}

function Get-DroverState {
    param([string]$Dir)

    $dll = Join-Path $Dir "version.dll"
    $ini = Join-Path $Dir "drover.ini"
    $packet = Join-Path $Dir "drover-packet.bin"

    $hasDll = Test-Path -LiteralPath $dll -PathType Leaf
    $hasIni = Test-Path -LiteralPath $ini -PathType Leaf
    $hasPacket = Test-Path -LiteralPath $packet -PathType Leaf

    if (-not $hasDll -and -not $hasIni -and -not $hasPacket) {
        return "NotInstalled"
    }

    if ($hasIni) {
        try {
            $text = Get-Content -LiteralPath $ini -Raw -ErrorAction Stop
            if ($text -match [regex]::Escape($ProxyHost)) {
                if ($hasDll) { return "Pesherkino" }
                return "PesherkinoPartial"
            }
        }
        catch {}
    }

    if ($hasDll -and $hasIni) { return "OtherDrover" }
    return "Partial"
}

function Stop-Discord {
    $found = $false

    foreach ($name in @("Discord","DiscordCanary","DiscordPTB")) {
        $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 0) {
            $found = $true
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

    if ($found) {
        Write-C "[*] Запущенный Discord закрыт." Cyan
        Start-Sleep -Milliseconds 1000
    }
}

function Test-ProxyConnect {
    param(
        [Parameter(Mandatory=$true)][string]$TargetHost,
        [int]$TargetPort = 443
    )

    $client = $null
    $reader = $null

    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($ProxyHost,$ProxyPort,$null,$null)

        if (-not $async.AsyncWaitHandle.WaitOne(5000,$false)) {
            $client.Close()
            return [pscustomobject]@{
                Success = $false
                StatusCode = 0
                StatusLine = "Proxy TCP timeout"
            }
        }

        $client.EndConnect($async)

        $stream = $client.GetStream()
        $stream.ReadTimeout = 7000
        $stream.WriteTimeout = 7000

        $nl = [Environment]::NewLine
        $request =
            "CONNECT " + $TargetHost + ":" + $TargetPort + " HTTP/1.1" + $nl +
            "Host: " + $TargetHost + ":" + $TargetPort + $nl +
            "Proxy-Connection: close" + $nl + $nl

        $bytes = [Text.Encoding]::ASCII.GetBytes($request)
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush()

        $reader = New-Object IO.StreamReader($stream,[Text.Encoding]::ASCII,$false,1024,$true)
        $line = $reader.ReadLine()

        $code = 0
        if ($line -match '^HTTP/\d(?:\.\d)?\s+(\d{3})') {
            $code = [int]$Matches[1]
        }

        return [pscustomobject]@{
            Success = ($code -eq 200)
            StatusCode = $code
            StatusLine = [string]$line
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            StatusCode = 0
            StatusLine = $_.Exception.Message
        }
    }
    finally {
        if ($reader) { try { $reader.Dispose() } catch {} }
        if ($client) { try { $client.Close() } catch {} }
    }
}

function Test-PesherkinoProxy {
    param([switch]$Quiet)

    $discord = Test-ProxyConnect -TargetHost "discord.com" -TargetPort 443

    if (-not $discord.Success) {
        if (-not $Quiet) {
            Write-C ("[ERROR] CONNECT discord.com:443 не прошёл: " + $discord.StatusLine) Red
            if ($discord.StatusCode -eq 407) {
                Write-C "[ERROR] Сервер требует Proxy Authentication, а публичный установщик не содержит credentials." Red
            }
        }
        return $false
    }

    $blocked = Test-ProxyConnect -TargetHost "example.com" -TargetPort 443

    if ($blocked.Success) {
        if (-not $Quiet) {
            Write-C "[ERROR] Проверка безопасности провалена: example.com разрешён через proxy." Red
            Write-C "Установка остановлена: proxy должен пропускать только Discord." Yellow
        }
        return $false
    }

    if (-not $Quiet) {
        Write-C "[OK] CONNECT discord.com:443 проходит." Green
        Write-C ("[OK] Посторонний example.com заблокирован (" + $blocked.StatusCode + ").") Green
    }

    return $true
}

function Download-Drover {
    param([Parameter(Mandatory=$true)][string]$WorkDir)

    $headers = @{
        "User-Agent" = "Pesherkino-Discord-Installer"
        "Accept" = "application/vnd.github+json"
    }

    Write-C "[*] Получаю последний релиз Discord Drover..." Cyan
    $release = Invoke-RestMethod -Uri $ReleaseApi -Headers $headers

    $asset = $release.assets |
        Where-Object { $_.name -like "*.zip" } |
        Select-Object -First 1

    if (-not $asset) { throw "В latest release Discord Drover не найден ZIP-файл." }

    Write-C ("[*] Discord Drover: " + $release.tag_name) Cyan

    $zip = Join-Path $WorkDir $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -Headers $headers -UseBasicParsing

    if ($asset.digest -and ([string]$asset.digest).StartsWith("sha256:")) {
        $expected = ([string]$asset.digest).Substring(7).ToLowerInvariant()
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()

        if ($actual -ne $expected) { throw "SHA256 скачанного Discord Drover не совпадает." }
        Write-C "[OK] SHA256 релиза проверен." Green
    }

    $extractDir = Join-Path $WorkDir "drover"
    Expand-Archive -Path $zip -DestinationPath $extractDir -Force

    $dll = Get-ChildItem -Path $extractDir -Recurse -File -Filter "version.dll" |
        Select-Object -First 1

    if (-not $dll) { throw "В архиве Discord Drover не найден version.dll." }

    $packet = Get-ChildItem -Path $extractDir -Recurse -File -Filter "drover-packet.bin" |
        Select-Object -First 1

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

function Deploy-Drover {
    param(
        [ValidateSet("Install","Repair")]
        [string]$Mode
    )

    Show-Header

    Write-C "[*] Проверяю реальное соединение через Pesherkino proxy..." Cyan
    if (-not (Test-PesherkinoProxy)) {
        Write-Host ""
        Write-C "Поддержка: @pesherkino_support" Yellow
        return
    }

    $dirs = @(Get-DiscordDirs)

    if ($dirs.Count -eq 0) {
        Write-Host ""
        Write-C "[ERROR] Discord Stable / PTB / Canary не найден." Red
        Write-C "Проверены стандартные пути, реестр Windows и Discord URI registration." DarkGray
        Write-C "Сначала установи и хотя бы один раз запусти Discord." Yellow
        return
    }

    Write-Host ""
    Write-C ("[*] Найдено папок Discord: " + $dirs.Count) Cyan

    foreach ($dir in $dirs) {
        $state = Get-DroverState -Dir $dir

        switch ($state) {
            "Pesherkino"        { Write-C ("[Pesherkino] " + $dir) Green }
            "OtherDrover"       { Write-C ("[Другой Drover -> будет заменён] " + $dir) Yellow }
            "Partial"           { Write-C ("[Неполная установка -> будет исправлена] " + $dir) Yellow }
            "PesherkinoPartial" { Write-C ("[Pesherkino неполный -> будет исправлен] " + $dir) Yellow }
            default             { Write-C ("[Новая установка] " + $dir) DarkGray }
        }
    }

    Stop-Discord

    $work = Join-Path ([IO.Path]::GetTempPath()) ("pesherkino-drover-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    try {
        $files = Download-Drover -WorkDir $work
        $ini = "[drover]" + [Environment]::NewLine + "proxy = " + $ProxyUri + [Environment]::NewLine
        $count = 0

        foreach ($dir in $dirs) {
            Write-C ("[*] " + $dir) Cyan

            [IO.File]::WriteAllText(
                (Join-Path $dir "drover.ini"),
                $ini,
                [Text.Encoding]::ASCII
            )

            Copy-Item -Path $files.Dll -Destination (Join-Path $dir "version.dll") -Force

            $packetPath = Join-Path $dir "drover-packet.bin"

            if ($files.Packet) {
                Copy-Item -Path $files.Packet -Destination $packetPath -Force
            }
            elseif (Test-Path $packetPath) {
                Remove-Item -LiteralPath $packetPath -Force -ErrorAction SilentlyContinue
            }

            $count++
        }

        Save-LocalCopy

        Write-Host ""
        if ($Mode -eq "Repair") {
            Write-C "[OK] Repair завершён." Green
        }
        else {
            Write-C "[OK] Pesherkino Discord установлен/обновлён." Green
        }

        Write-C ("[OK] Discord Drover: " + $files.Version) Green
        Write-C ("[OK] Обработано папок Discord: " + $count) Green
        Write-Host ""
        Write-C "Теперь запусти Discord обычным способом." White
    }
    catch {
        Write-Host ""
        Write-C ("[ERROR] " + $_.Exception.Message) Red
    }
    finally {
        Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Uninstall-PesherkinoDiscord {
    Show-Header

    $dirs = @(Get-DiscordDirs)

    if ($dirs.Count -eq 0) {
        Write-C "Discord не найден." Yellow
        return
    }

    Stop-Discord
    $count = 0

    foreach ($dir in $dirs) {
        $iniPath = Join-Path $dir "drover.ini"
        $isOurs = $false

        if (Test-Path $iniPath) {
            try {
                $text = Get-Content -LiteralPath $iniPath -Raw
                if ($text -match [regex]::Escape($ProxyHost)) { $isOurs = $true }
            }
            catch {}
        }

        if (-not $isOurs) { continue }

        foreach ($name in @("drover.ini","version.dll","drover-packet.bin")) {
            $path = Join-Path $dir $name
            if (Test-Path $path) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }

        $count++
    }

    if (Test-Path $LocalDir) {
        Remove-Item -LiteralPath $LocalDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-C ("[OK] Pesherkino Discord удалён. Обработано папок: " + $count) Green
}

function Show-Status {
    Show-Header

    Write-C ("Proxy: " + $ProxyHost + ":" + $ProxyPort) White

    $discordTest = Test-ProxyConnect -TargetHost "discord.com" -TargetPort 443
    $blockedTest = Test-ProxyConnect -TargetHost "example.com" -TargetPort 443

    if ($discordTest.Success) {
        Write-C "Discord CONNECT: работает" Green
    }
    else {
        Write-C ("Discord CONNECT: ошибка — " + $discordTest.StatusLine) Red
    }

    if (-not $blockedTest.Success) {
        Write-C ("Ограничение proxy: работает (example.com запрещён, HTTP " + $blockedTest.StatusCode + ")") Green
    }
    else {
        Write-C "Ограничение proxy: ОШИБКА — example.com разрешён" Red
    }

    Write-Host ""

    $dirs = @(Get-DiscordDirs)

    if ($dirs.Count -eq 0) {
        Write-C "Discord не найден." Yellow
        return
    }

    foreach ($dir in $dirs) {
        $state = Get-DroverState -Dir $dir

        switch ($state) {
            "Pesherkino"        { Write-C ("[OK] Pesherkino Drover — " + $dir) Green }
            "PesherkinoPartial" { Write-C ("[!] Неполная Pesherkino-установка — " + $dir) Yellow }
            "OtherDrover"       { Write-C ("[!] Установлен другой Drover — " + $dir) Yellow }
            "Partial"           { Write-C ("[!] Найдены отдельные файлы Drover — " + $dir) Yellow }
            default             { Write-C ("[--] Drover не установлен — " + $dir) DarkGray }
        }
    }
}

function Show-Info {
    Show-Header

    Write-C "Что делает Pesherkino Discord" White
    Write-Host ""
    Write-Host "  Discord Drover заставляет приложение Discord использовать"
    Write-Host "  отдельный HTTP proxy для TCP-соединений."
    Write-Host ""
    Write-Host "  Сервер разрешает через proxy только Discord-домены."
    Write-Host "  Посторонние сайты сервером блокируются."
    Write-Host ""
    Write-C "Установка и Repair" Cyan
    Write-Host ""
    Write-Host "  • Ищет Discord в стандартных папках и через реестр Windows."
    Write-Host "  • Поддерживает Stable, Canary и PTB."
    Write-Host "  • Автоматически закрывает запущенный Discord."
    Write-Host "  • Определяет существующий Discord Drover."
    Write-Host "  • Install/Repair заменяет старые файлы без backup."
    Write-Host "  • Скачивает последний release Discord Drover с GitHub."
    Write-Host "  • Проверяет SHA256 релиза, если GitHub публикует digest."
    Write-Host "  • Проверяет CONNECT к Discord и блокировку постороннего сайта."
    Write-Host ""
    Write-C "Совместимость" Yellow
    Write-Host ""
    Write-Host "  • Не работает совместно с Zapret."
    Write-Host "  • Не используйте одновременно с VPN в TUN-режиме."
    Write-Host ""
    Write-C "Pesherkino VPN" Cyan
    Write-Host ""
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
        Write-C "2. Repair / переустановить Drover" White
        Write-C "3. Удалить Pesherkino Discord" White
        Write-C "4. Статус и проверка proxy" White
        Write-C "5. Информация / Pesherkino VPN" White
        Write-C "0. Выход" DarkGray
        Write-Host ""

        switch (Read-Host "Выберите действие") {
            "1" { Deploy-Drover -Mode Install; Read-Host "Enter для продолжения" | Out-Null }
            "2" { Deploy-Drover -Mode Repair; Read-Host "Enter для продолжения" | Out-Null }
            "3" { Uninstall-PesherkinoDiscord; Read-Host "Enter для продолжения" | Out-Null }
            "4" { Show-Status; Read-Host "Enter для продолжения" | Out-Null }
            "5" { Show-Info; Read-Host "Enter для продолжения" | Out-Null }
            "0" { return }
        }
    }
}

switch ($Action) {
    "Install"   { Deploy-Drover -Mode Install }
    "Repair"    { Deploy-Drover -Mode Repair }
    "Uninstall" { Uninstall-PesherkinoDiscord }
    "Status"    { Show-Status }
    "Info"      { Show-Info }
    default     { Show-Menu }
}
