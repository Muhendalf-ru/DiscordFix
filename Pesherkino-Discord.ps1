$Action = "Menu"
$AllowedActions = @("Menu","Install","Repair","Uninstall","Status")

if ($args.Count -gt 0) {
    for ($i = 0; $i -lt $args.Count; $i++) {
        $argValue = [string]$args[$i]

        if ($argValue -ieq "-Action") {
            if (($i + 1) -lt $args.Count) {
                $candidate = [string]$args[$i + 1]
                if ($AllowedActions -contains $candidate) {
                    $Action = $candidate
                }
                $i++
            }
            continue
        }

        if ($AllowedActions -contains $argValue) {
            $Action = $argValue
        }
    }
}

$ErrorActionPreference = "Stop"
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $OutputEncoding = [Console]::OutputEncoding
} catch {}
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
    $w = 64

    Write-C ("╭" + ("─" * ($w + 2)) + "╮") DarkCyan
    Write-C ("│ " + ("PESHERKINO DISCORD".PadLeft([int](($w + 18) / 2))).PadRight($w) + " │") Cyan
    Write-C ("│ " + ("Discord Fix".PadLeft([int](($w + 11) / 2))).PadRight($w) + " │") White
    Write-C ("├" + ("─" * ($w + 2)) + "┤") DarkCyan
    Write-C ("│ " + "Discord через отдельный Pesherkino proxy".PadRight($w) + " │") White
    Write-C ("│ " + "Не используйте одновременно с Zapret или VPN в TUN-режиме.".PadRight($w) + " │") Yellow
    Write-C ("╰" + ("─" * ($w + 2)) + "╯") DarkCyan
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

function Get-MenuSnapshot {
    $dirs = @(Get-DiscordDirs)

    $discordFound = ($dirs.Count -gt 0)
    $droverState = "NOT INSTALLED"
    $droverColor = [ConsoleColor]::DarkGray

    if ($discordFound) {
        $states = @()
        foreach ($dir in $dirs) {
            $states += (Get-DroverState -Dir $dir)
        }

        if ($states -contains "Pesherkino") {
            $droverState = "INSTALLED"
            $droverColor = [ConsoleColor]::Green
        }
        elseif (($states -contains "PesherkinoPartial") -or ($states -contains "Partial")) {
            $droverState = "REPAIR NEEDED"
            $droverColor = [ConsoleColor]::Yellow
        }
        elseif ($states -contains "OtherDrover") {
            $droverState = "OTHER DROVER"
            $droverColor = [ConsoleColor]::Yellow
        }
    }

    $discordTest = Test-ProxyConnect -TargetHost "discord.com" -TargetPort 443
    $blockedTest = $null

    if ($discordTest.Success) {
        $blockedTest = Test-ProxyConnect -TargetHost "example.com" -TargetPort 443
    }

    $proxyState = "OFFLINE"
    $proxyColor = [ConsoleColor]::Red

    if ($discordTest.Success) {
        if ($blockedTest -and $blockedTest.Success) {
            $proxyState = "UNSAFE"
            $proxyColor = [ConsoleColor]::Yellow
        }
        else {
            $proxyState = "ONLINE"
            $proxyColor = [ConsoleColor]::Green
        }
    }

    return [pscustomobject]@{
        ProxyState   = $proxyState
        ProxyColor   = $proxyColor
        DiscordState = if ($discordFound) { "FOUND (" + $dirs.Count + ")" } else { "NOT FOUND" }
        DiscordColor = if ($discordFound) { [ConsoleColor]::Green } else { [ConsoleColor]::Red }
        DroverState  = $droverState
        DroverColor  = $droverColor
    }
}

function Center-TuiText {
    param(
        [string]$Text,
        [int]$Width
    )

    if ($null -eq $Text) { $Text = "" }
    if ($Text.Length -ge $Width) { return $Text.Substring(0,$Width) }

    $left = [int][Math]::Floor(($Width - $Text.Length) / 2)
    return ((" " * $left) + $Text).PadRight($Width)
}

function Write-TuiLine {
    param(
        [string]$Text = "",
        [ConsoleColor]$Color = [ConsoleColor]::Gray,
        [int]$Width = 64
    )

    if ($null -eq $Text) { $Text = "" }
    if ($Text.Length -gt $Width) {
        $Text = $Text.Substring(0,$Width)
    }

    Write-Host "│ " -NoNewline -ForegroundColor DarkCyan
    Write-Host $Text.PadRight($Width) -NoNewline -ForegroundColor $Color
    Write-Host " │" -ForegroundColor DarkCyan
}

function Write-TuiStatus {
    param(
        [string]$Name,
        [string]$Value,
        [ConsoleColor]$ValueColor,
        [int]$Width = 64
    )

    $prefix = ("  " + $Name).PadRight(14)
    $valueText = "● " + $Value
    $remaining = $Width - $prefix.Length

    if ($valueText.Length -gt $remaining) {
        $valueText = $valueText.Substring(0,$remaining)
    }

    Write-Host "│ " -NoNewline -ForegroundColor DarkCyan
    Write-Host $prefix -NoNewline -ForegroundColor DarkGray
    Write-Host $valueText.PadRight($remaining) -NoNewline -ForegroundColor $ValueColor
    Write-Host " │" -ForegroundColor DarkCyan
}

function Write-TuiOption {
    param(
        [string]$Label,
        [bool]$Selected,
        [int]$Width = 64
    )

    $text = if ($Selected) { "  ▶  " + $Label } else { "     " + $Label }

    if ($text.Length -gt $Width) {
        $text = $text.Substring(0,$Width)
    }

    Write-Host "│ " -NoNewline -ForegroundColor DarkCyan

    if ($Selected) {
        Write-Host $text.PadRight($Width) -NoNewline -ForegroundColor White -BackgroundColor DarkCyan
    }
    else {
        Write-Host $text.PadRight($Width) -NoNewline -ForegroundColor Gray
    }

    Write-Host " │" -ForegroundColor DarkCyan
}

function Draw-MainMenu {
    param(
        [int]$Selected,
        [object]$Snapshot
    )

    $w = 64
    $items = @(
        "Установить / обновить",
        "Repair / переустановить Drover",
        "Статус и диагностика",
        "Удалить Pesherkino Discord",
        "Выход"
    )

    Clear-Host

    Write-C ("╭" + ("─" * ($w + 2)) + "╮") DarkCyan
    Write-TuiLine -Text (Center-TuiText -Text "PESHERKINO" -Width $w) -Color Cyan -Width $w
    Write-TuiLine -Text (Center-TuiText -Text "Discord Fix" -Width $w) -Color White -Width $w
    Write-C ("├" + ("─" * ($w + 2)) + "┤") DarkCyan

    Write-TuiLine -Text "  Состояние" -Color White -Width $w
    Write-TuiStatus -Name "Proxy"   -Value $Snapshot.ProxyState   -ValueColor $Snapshot.ProxyColor   -Width $w
    Write-TuiStatus -Name "Discord" -Value $Snapshot.DiscordState -ValueColor $Snapshot.DiscordColor -Width $w
    Write-TuiStatus -Name "Drover"  -Value $Snapshot.DroverState  -ValueColor $Snapshot.DroverColor  -Width $w

    Write-C ("├" + ("─" * ($w + 2)) + "┤") DarkCyan
    Write-TuiLine -Text "  Действия" -Color White -Width $w

    for ($i = 0; $i -lt $items.Count; $i++) {
        Write-TuiOption -Label $items[$i] -Selected ($i -eq $Selected) -Width $w
    }

    Write-C ("├" + ("─" * ($w + 2)) + "┤") DarkCyan
    Write-TuiLine -Text "  Pesherkino VPN — полноценный VPN до 10 устройств" -Color Cyan -Width $w
    Write-TuiLine -Text "  Бот: @pesherkino_bot    Поддержка: @pesherkino_support" -Color White -Width $w
    Write-TuiLine -Text "  Новости: t.me/pesherkinonews" -Color DarkGray -Width $w
    Write-TuiLine -Text "  Сайт: cabinet.netherus.com" -Color DarkGray -Width $w
    Write-C ("├" + ("─" * ($w + 2)) + "┤") DarkCyan
    Write-TuiLine -Text (Center-TuiText -Text "↑ ↓ выбрать   •   Enter подтвердить   •   Esc выйти" -Width $w) -Color DarkGray -Width $w
    Write-C ("╰" + ("─" * ($w + 2)) + "╯") DarkCyan
}

function Wait-TuiKey {
    Write-Host ""
    Write-C "Нажмите любую клавишу, чтобы вернуться в меню..." DarkGray

    try {
        [void][Console]::ReadKey($true)
    }
    catch {
        Read-Host "Enter для продолжения" | Out-Null
    }
}

function Show-FallbackMenu {
    while ($true) {
        Show-Header
        Write-C "1. Установить / обновить" White
        Write-C "2. Repair / переустановить Drover" White
        Write-C "3. Статус и диагностика" White
        Write-C "4. Удалить Pesherkino Discord" White
        Write-C "0. Выход" DarkGray
        Write-Host ""

        switch (Read-Host "Выберите действие") {
            "1" { Deploy-Drover -Mode Install; Read-Host "Enter для продолжения" | Out-Null }
            "2" { Deploy-Drover -Mode Repair; Read-Host "Enter для продолжения" | Out-Null }
            "3" { Show-Status; Read-Host "Enter для продолжения" | Out-Null }
            "4" { Uninstall-PesherkinoDiscord; Read-Host "Enter для продолжения" | Out-Null }
            "0" { return }
        }
    }
}

function Show-Menu {
    $selected = 0

    try {
        $null = [Console]::KeyAvailable
    }
    catch {
        Show-FallbackMenu
        return
    }

    while ($true) {
        $snapshot = Get-MenuSnapshot
        $redraw = $true

        while ($redraw) {
            Draw-MainMenu -Selected $selected -Snapshot $snapshot

            try {
                $key = [Console]::ReadKey($true)
            }
            catch {
                Show-FallbackMenu
                return
            }

            switch ($key.Key) {
                "UpArrow" {
                    $selected--
                    if ($selected -lt 0) { $selected = 4 }
                }

                "DownArrow" {
                    $selected++
                    if ($selected -gt 4) { $selected = 0 }
                }

                "W" {
                    $selected--
                    if ($selected -lt 0) { $selected = 4 }
                }

                "S" {
                    $selected++
                    if ($selected -gt 4) { $selected = 0 }
                }

                "Escape" {
                    return
                }

                "Enter" {
                    $redraw = $false
                }
            }
        }

        switch ($selected) {
            0 { Deploy-Drover -Mode Install; Wait-TuiKey }
            1 { Deploy-Drover -Mode Repair; Wait-TuiKey }
            2 { Show-Status; Wait-TuiKey }
            3 { Uninstall-PesherkinoDiscord; Wait-TuiKey }
            4 { return }
        }
    }
}

switch ($Action) {
    "Install"   { Deploy-Drover -Mode Install }
    "Repair"    { Deploy-Drover -Mode Repair }
    "Uninstall" { Uninstall-PesherkinoDiscord }
    "Status"    { Show-Status }
    default     { Show-Menu }
}
