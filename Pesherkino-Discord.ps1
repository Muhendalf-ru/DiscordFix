$Action = "Menu"
$AllowedActions = @("Menu","Install","InstallDiscord","Repair","Uninstall","Status","Report","Help","About","Compatibility","Happ","Zapret")

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

$DiscordDownloadUrl = "https://discord.com/api/downloads/distributions/app/installers/latest?arch=x64&channel=stable&platform=win"

$ReleaseApi = "https://api.github.com/repos/hdrover/discord-drover/releases/latest"
$LocalDir   = Join-Path $env:LOCALAPPDATA "Pesherkino\DiscordDrover"
$script:SessionEvents = New-Object System.Collections.Generic.List[string]
$script:ProxySnapshot = $null
$script:LastDiagnostic = @()
$script:UseAnsi = $false
$script:MenuLayout = $null
$script:OriginalBackground = $null
$script:OriginalForeground = $null
try {
    $script:OriginalBackground = $Host.UI.RawUI.BackgroundColor
    $script:OriginalForeground = $Host.UI.RawUI.ForegroundColor
    $Host.UI.RawUI.BackgroundColor = [ConsoleColor]::Black
    $Host.UI.RawUI.ForegroundColor = [ConsoleColor]::Gray
} catch {}
try { $script:UseAnsi = [bool]$Host.UI.SupportsVirtualTerminal -and -not [Console]::IsOutputRedirected } catch {}
$script:Accent = [ConsoleColor]::DarkYellow

function Protect-ReportText {
    param([string]$Text)
    foreach ($entry in @(
        @{ Value = $env:LOCALAPPDATA; Label = "%LOCALAPPDATA%" },
        @{ Value = $env:USERPROFILE; Label = "%USERPROFILE%" }
    )) {
        if ($entry.Value) { $Text = $Text -replace [regex]::Escape($entry.Value), $entry.Label }
    }
    $Text = $Text -replace '(?i)(https?://)[^/\s@]+@', '$1[credentials]@'
    $Text = $Text -replace '(?im)((?:authorization|cookie)\s*[=:]\s*)[^\r\n]+', '$1[hidden]'
    return ($Text -replace '(?i)((?:token|password)\s*[=:]\s*)[^\s;]+', '$1[hidden]')
}

function Write-Accent {
    param([string]$Text, [switch]$NoNewline)
    if ($script:UseAnsi) {
        $esc = [char]27
        Write-Host ("${esc}[38;2;255;171;88m" + $Text + "${esc}[0m") -NoNewline:$NoNewline
    }
    else { Write-Host $Text -ForegroundColor $script:Accent -NoNewline:$NoNewline }
}

function Get-TuiWidth {
    $available = 72
    try { if ([Console]::WindowWidth -gt 0) { $available = [Console]::WindowWidth - 5 } } catch {}
    return [Math]::Max(24, [Math]::Min(72, $available))
}

function Write-InstallStage {
    param([int]$Step, [int]$Total, [string]$Text)
    Write-Accent ("[$Step/$Total] $Text")
    $script:SessionEvents.Add(("{0:HH:mm:ss} | {1}/{2} | {3}" -f [DateTime]::Now,$Step,$Total,$Text))
}

function Show-ActionError {
    param([string]$Message, [string]$Advice = "Выберите «Проверить соединение», затем сохраните отчёт для @pesherkino_support.")
    Write-C ("[Ошибка] " + $Message) Red
    Write-C ("Что сделать: " + $Advice) Yellow
}

function Write-C {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    $script:SessionEvents.Add(("{0:HH:mm:ss} | {1}" -f [DateTime]::Now,(Protect-ReportText $Text)))
    # Keep reports compact during long sessions.
    if ($script:SessionEvents.Count -gt 300) { $script:SessionEvents.RemoveAt(0) }
    if ($Color -eq [ConsoleColor]::Cyan) { Write-Accent $Text }
    else { Write-Host $Text -ForegroundColor $Color }
}

function Show-Header {
    Clear-Host
    Write-Host "PESHERKINO " -NoNewline -ForegroundColor White
    Write-Accent "DISCORD"
    Write-Host "Работаем ради вас" -ForegroundColor Gray
    Write-Host ("─" * (Get-TuiWidth)) -ForegroundColor DarkGray
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

function Test-OfficialDiscordDownloadUri {
    param([uri]$Uri)

    if (-not $Uri.IsAbsoluteUri -or $Uri.Scheme -ne "https" -or
        $Uri.Port -ne 443 -or $Uri.UserInfo) { return $false }

    foreach ($domain in @("discord.com", "discordapp.com", "discordapp.net")) {
        if ($Uri.DnsSafeHost -ieq $domain -or
            $Uri.DnsSafeHost.EndsWith("." + $domain, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Receive-DiscordInstaller {
    param([string]$OutFile, [switch]$UseProxy)

    # Validate every redirect; never follow an HTTP URL or a third-party mirror.
    $uri = [uri]$DiscordDownloadUrl
    $oldTls = [Net.ServicePointManager]::SecurityProtocol
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        [Net.ServicePointManager]::SecurityProtocol = $oldTls -bor [Net.SecurityProtocolType]::Tls12
        for ($hop = 0; $hop -lt 10; $hop++) {
            if (-not (Test-OfficialDiscordDownloadUri -Uri $uri)) {
                throw "Загрузка перенаправлена на неофициальный или небезопасный адрес: $uri"
            }
            $request = [Net.HttpWebRequest]::Create($uri)
            $request.AllowAutoRedirect = $false
            $request.Timeout = 30000
            $request.ReadWriteTimeout = 30000
            $request.UserAgent = "Pesherkino-Discord-Installer"
            $request.Proxy = $null
            if ($UseProxy) { $request.Proxy = New-Object Net.WebProxy($ProxyUri) }
            $response = $null
            $inputStream = $null
            $outputStream = $null
            try {
                $response = $request.GetResponse()
                $code = [int]$response.StatusCode
                if ($code -in @(301,302,303,307,308)) {
                    $location = $response.Headers["Location"]
                    if (-not $location) { throw "Discord вернул перенаправление без адреса." }
                    $uri = New-Object Uri($uri, $location)
                    continue
                }
                if ($code -ne 200) { throw "Сервер загрузки Discord вернул HTTP $code." }
                if ($response.ContentLength -gt 512MB) { throw "Установщик Discord слишком большой." }

                $inputStream = $response.GetResponseStream()
                $outputStream = [IO.File]::Create($OutFile)
                $buffer = New-Object byte[] 65536
                $total = 0L
                $lastProgressMs = -1000
                while (($read = $inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                    $total += $read
                    if ($total -gt 512MB -or $watch.Elapsed.TotalMinutes -ge 5) {
                        throw "Превышен лимит размера или времени загрузки Discord."
                    }
                    $outputStream.Write($buffer,0,$read)
                    if (($watch.ElapsedMilliseconds - $lastProgressMs) -ge 200) {
                        $lastProgressMs = $watch.ElapsedMilliseconds
                        $speed = $total / [Math]::Max(0.1,$watch.Elapsed.TotalSeconds)
                        $status = "{0:N1} МБ · {1:N1} МБ/с" -f ($total / 1MB),($speed / 1MB)
                        $progress = @{ Activity = "Скачивание Discord"; Status = $status }
                        if ($response.ContentLength -gt 0) {
                            $progress.Status = "{0:N1} / {1:N1} МБ · {2:N1} МБ/с" -f ($total / 1MB),($response.ContentLength / 1MB),($speed / 1MB)
                            $progress.PercentComplete = [int][Math]::Min(100, ($total * 100.0 / $response.ContentLength))
                            $progress.SecondsRemaining = [int][Math]::Max(0,($response.ContentLength - $total) / [Math]::Max(1,$speed))
                        }
                        Write-Progress @progress
                    }
                }
                if ($total -eq 0 -or ($response.ContentLength -gt 0 -and $total -ne $response.ContentLength)) {
                    throw "Установщик Discord скачан не полностью."
                }
                return
            }
            finally {
                if ($outputStream) { $outputStream.Dispose() }
                if ($inputStream) { $inputStream.Dispose() }
                if ($response) { $response.Close() }
            }
        }
        throw "Слишком много перенаправлений при загрузке Discord."
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $oldTls
        Write-Progress -Activity "Скачивание Discord" -Completed
    }
}

function Assert-DiscordInstallerSignature {
    param([string]$Path)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne "Valid" -or -not $signature.SignerCertificate) {
        throw ("Цифровая подпись DiscordSetup.exe не прошла проверку: " + $signature.Status)
    }
    $publisher = $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    if ($publisher -notmatch '^Discord,? Inc\.?$') {
        throw "Установщик подписан неизвестным издателем: $publisher"
    }
    Write-C ("[OK] Действительная цифровая подпись: " + $publisher) Green
}

function Install-DiscordApplication {
    # Only install Stable; existing PTB/Canary installations are left in place.
    if (@(Get-DiscordDirs | Where-Object {
        Test-Path -LiteralPath (Join-Path $_ "Discord.exe") -PathType Leaf
    }).Count -gt 0) {
        Write-C "[OK] Discord Stable уже установлен. Настраиваю подключение." Green
        return $true
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
        -not [Environment]::Is64BitOperatingSystem) {
        Show-ActionError "Установка Discord поддерживается на 64-битной Windows." "Запустите скрипт на компьютере с 64-битной Windows."
        return $false
    }

    $work = Join-Path ([IO.Path]::GetTempPath()) ("pesherkino-discord-" + [Guid]::NewGuid().ToString("N"))
    $setupProcess = $null
    $keepWork = $false
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $setup = Join-Path $work "DiscordSetup.exe"
        Write-InstallStage 1 7 "Скачивание Discord"
        Write-C "[*] Скачиваю оригинальный Discord Stable через Pesherkino proxy..." Cyan
        try {
            Receive-DiscordInstaller -OutFile $setup -UseProxy
        }
        catch {
            Write-C ("[!] Загрузка через proxy не удалась: " + $_.Exception.Message) Yellow
            Write-C "[*] Пробую прямое подключение к официальным серверам Discord..." Cyan
            Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue
            Receive-DiscordInstaller -OutFile $setup
        }
        Write-InstallStage 2 7 "Проверка цифровой подписи"
        Assert-DiscordInstallerSignature -Path $setup
        Stop-Discord
        Write-InstallStage 3 7 "Установка приложения"
        Write-C "Дождитесь завершения официального установщика Discord." Gray
        $setupProcess = Start-Process -FilePath $setup -PassThru
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $setupProcess.WaitForExit(1000)) {
            if ($watch.Elapsed.TotalMinutes -ge 5) {
                $keepWork = $true
                throw "Установщик ещё работает. Завершите установку в его окне, затем выберите основное действие в меню."
            }
        }
        if ($setupProcess.ExitCode -ne 0) {
            throw ("Установщик Discord завершился с кодом " + $setupProcess.ExitCode + ". Лог: %LOCALAPPDATA%\SquirrelTemp\SquirrelSetup.log")
        }
        # Some installers delegate extraction to a child process.
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        do {
            $stableDirs = @(Get-DiscordDirs | Where-Object {
                Test-Path -LiteralPath (Join-Path $_ "Discord.exe") -PathType Leaf
            })
            if ($stableDirs.Count -gt 0) { break }
            Start-Sleep -Seconds 1
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($stableDirs.Count -eq 0) { throw "Установщик завершился, но Discord.exe не найден. Проверьте окно и лог установки." }

        Stop-Discord
        Write-C "[OK] Discord Stable установлен. Далее устанавливаю Drover." Green
        return $true
    }
    catch {
        Show-ActionError $_.Exception.Message "Проверьте окно установщика и соединение. Для загрузки прокси должен разрешать discord.com и *.discordapp.net. Сохраните отчёт при повторной ошибке."
        return $false
    }
    finally {
        if ($setupProcess -and -not $setupProcess.HasExited) { $keepWork = $true }
        if (-not $keepWork) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Start-DiscordForLogin {
    $candidates = @()
    foreach ($dir in @(Get-ActiveDiscordDirs)) {
        if ((Get-DroverState -Dir $dir) -ne "Pesherkino") { continue }
        foreach ($exe in @("Discord.exe","DiscordPTB.exe","DiscordCanary.exe")) {
            $path = Join-Path $dir $exe
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $candidates += [pscustomobject]@{ Directory = $dir; Path = $path; Stable = ($exe -eq "Discord.exe") }
                break
            }
        }
    }
    $target = $candidates | Sort-Object Stable -Descending | Select-Object -First 1
    if (-not $target) { throw "Актуальная версия Discord с настроенным подключением не найдена. Выберите «Восстановить подключение»." }
    # Launch the patched executable directly for the first login.
    Start-Process -FilePath $target.Path -WorkingDirectory $target.Directory | Out-Null
    Write-C "[OK] Discord запущен через Pesherkino proxy." Green
    Write-C "Войдите в окне Discord: почта/пароль и 2FA либо QR-код с телефона." White
}

function Install-DiscordAndDrover {
    Show-Header
    if (Install-DiscordApplication) {
        if (Deploy-Drover -Mode Install -ContinueInstallation) {
            try { Start-DiscordForLogin }
            catch { Show-ActionError $_.Exception.Message "Запустите Discord вручную или выберите «Восстановить подключение»." }
        }
    }
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

    $network = Get-ProxySnapshot -Refresh
    $discord = $network.Discord

    if (-not $discord.Success) {
        if (-not $Quiet) {
            Write-C ("[ERROR] CONNECT discord.com:443 не прошёл: " + $discord.StatusLine) Red
            if ($discord.StatusCode -eq 407) {
                Write-C "[ERROR] Сервер требует Proxy Authentication, а публичный установщик не содержит credentials." Red
            }
        }
        return $false
    }

    $blocked = $network.Blocked

    if ($blocked.StatusCode -ne 403) {
        if (-not $Quiet) {
            if ($blocked.Success) { Show-ActionError "Прокси разрешает example.com." "Проверьте FilterDefaultDeny Yes и список разрешённых доменов Tinyproxy." }
            else { Show-ActionError ("Запрет посторонних сайтов не подтверждён: " + $blocked.StatusLine) "Повторите проверку соединения. Для подтверждения запрета ожидается HTTP 403 от прокси." }
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
        [string]$Mode,
        [switch]$ContinueInstallation
    )

    if (-not $ContinueInstallation) { Show-Header }

    $newDiscord = $false
    $combined = [bool]$ContinueInstallation
    $dirs = @(Get-DiscordDirs)
    if ($dirs.Count -eq 0 -and $Mode -eq "Install") {
        Write-C "[*] Discord не найден. Сначала устанавливаю приложение." Cyan
        if (-not (Install-DiscordApplication)) { return $false }
        $newDiscord = $true
        $combined = $true
        $dirs = @(Get-DiscordDirs)
    }

    $steps = if ($combined) { 7 } else { 4 }
    $offset = if ($combined) { 3 } else { 0 }
    Write-InstallStage (1 + $offset) $steps "Проверка подключения"
    if (-not (Test-PesherkinoProxy)) {
        Write-Host ""
        Write-C "Поддержка: @pesherkino_support" Yellow
        return $false
    }

    if ($dirs.Count -eq 0) {
        Write-Host ""
        Write-C "[ERROR] Discord Stable / PTB / Canary не найден." Red
        Write-C "Проверены стандартные пути, реестр Windows и Discord URI registration." DarkGray
        Write-C "Выберите «Установить Discord» в меню." Yellow
        return $false
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
        Write-InstallStage (2 + $offset) $steps "Загрузка компонентов подключения"
        $files = Download-Drover -WorkDir $work
        Write-InstallStage (3 + $offset) $steps "Настройка подключения"
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
            Write-C "[OK] Подключение восстановлено." Green
        }
        else {
            Write-C "[OK] Подключение Pesherkino настроено." Green
        }

        Write-C ("[OK] Версия компонентов подключения: " + $files.Version) Green
        Write-C ("[OK] Обработано папок Discord: " + $count) Green
        Write-Host ""
        Write-InstallStage $steps $steps "Готово. Discord готов к запуску"
        Write-C "Откройте Discord обычным способом или основным действием в меню." White
        if ($newDiscord) {
            try { Start-DiscordForLogin }
            catch { Show-ActionError $_.Exception.Message "Запустите Discord вручную или выберите «Восстановить подключение»." }
        }
        return $true
    }
    catch {
        Write-Host ""
        Show-ActionError $_.Exception.Message
        return $false
    }
    finally {
        Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Uninstall-PesherkinoDiscord {
    Show-Header

    Write-C "Будут удалены компоненты и настройки подключения Pesherkino." Yellow
    Write-C "Приложение Discord останется установленным." White
    if ((Read-Host "Для подтверждения введите ДА") -ine "ДА") {
        Write-C "Удаление отменено." Gray
        return
    }

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

    Write-C ("[OK] Подключение Pesherkino удалено. Обработано папок: " + $count) Green
}

function Get-ActiveDiscordDirs {
    $groups = @(Get-DiscordDirs) | Group-Object {
        if ((Split-Path -Leaf $_) -like "app-*") { Split-Path -Parent $_ } else { $_ }
    }
    foreach ($group in $groups) {
        $group.Group | Sort-Object {
            try { [version](Split-Path -Leaf $_).Substring(4) } catch { [version]"0.0" }
        } -Descending | Select-Object -First 1
    }
}

function Get-ProxySnapshot {
    param([switch]$Refresh)
    if (-not $Refresh -and $script:ProxySnapshot -and
        ([DateTime]::UtcNow - $script:ProxySnapshot.CheckedAt).TotalSeconds -lt 30) {
        return $script:ProxySnapshot
    }
    $discord = Test-ProxyConnect -TargetHost "discord.com"
    $blocked = $null
    $state = "Недоступен"
    $color = [ConsoleColor]::Red
    if ($discord.Success) {
        $blocked = Test-ProxyConnect -TargetHost "example.com"
        if ($blocked.StatusCode -eq 403) { $state = "Доступен · CONNECT"; $color = [ConsoleColor]::Green }
        elseif ($blocked.Success) { $state = "Посторонние сайты разрешены"; $color = [ConsoleColor]::Yellow }
        else { $state = "Фильтр не удалось проверить"; $color = [ConsoleColor]::Yellow }
    }
    $script:ProxySnapshot = [pscustomobject]@{
        CheckedAt = [DateTime]::UtcNow; Discord = $discord; Blocked = $blocked; State = $state; Color = $color
    }
    return $script:ProxySnapshot
}

function Get-MenuSnapshot {
    param([switch]$RefreshNetwork, [switch]$SkipNetwork)
    $dirs = @(Get-ActiveDiscordDirs)
    $states = @($dirs | ForEach-Object { Get-DroverState -Dir $_ })
    $primaryLabel = "Установить Discord"
    $primaryHint = "И настроить подключение"
    $primaryAction = "InstallDiscord"
    $droverState = "Не настроено"
    $droverColor = [ConsoleColor]::Gray
    if ($dirs.Count -gt 0) {
        $primaryLabel = "Настроить подключение"; $primaryHint = "Через прокси Pesherkino"; $primaryAction = "Install"
        if (@($states | Where-Object { $_ -ne "Pesherkino" }).Count -eq 0) {
            $droverState = "Настроено"; $droverColor = [ConsoleColor]::Green
            $primaryLabel = "Открыть Discord"; $primaryHint = "Войти в аккаунт или продолжить"; $primaryAction = "Launch"
        }
        elseif ($states -contains "Pesherkino" -or $states -contains "PesherkinoPartial" -or $states -contains "Partial") {
            $droverState = "Нужно восстановить"; $droverColor = [ConsoleColor]::Yellow
            $primaryLabel = "Восстановить подключение"; $primaryHint = "Настроить актуальную версию"; $primaryAction = "Repair"
        }
        elseif ($states -contains "OtherDrover") { $droverState = "Другие настройки"; $droverColor = [ConsoleColor]::Yellow }
        # A Discord update creates a new app-* directory without our files.
        elseif (@(Get-DiscordDirs | Where-Object { (Get-DroverState -Dir $_) -eq "Pesherkino" }).Count -gt 0) {
            $droverState = "Нужно восстановить"; $droverColor = [ConsoleColor]::Yellow
            $primaryLabel = "Восстановить подключение"; $primaryHint = "После обновления Discord"; $primaryAction = "Repair"
        }
    }
    $network = $script:ProxySnapshot
    if (-not $SkipNetwork) { $network = Get-ProxySnapshot -Refresh:$RefreshNetwork }
    return [pscustomobject]@{
        ProxyState = if ($network) { $network.State } else { "Не проверен" }
        ProxyColor = if ($network) { $network.Color } else { [ConsoleColor]::Gray }
        DiscordState = if ($dirs.Count -gt 0) { "Установлен · вариантов: " + $dirs.Count } else { "Не установлен" }
        DiscordColor = if ($dirs.Count -gt 0) { [ConsoleColor]::Green } else { [ConsoleColor]::Gray }
        DroverState = $droverState; DroverColor = $droverColor
        PrimaryLabel = $primaryLabel; PrimaryHint = $primaryHint; PrimaryAction = $primaryAction
        Directories = $dirs
    }
}

function Test-DiscordWebRequest {
    param([string]$Uri, [string]$Method = "Get")
    $oldTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $oldTls -bor [Net.SecurityProtocolType]::Tls12
        $response = Invoke-WebRequest -Uri $Uri -Method $Method -Proxy $ProxyUri -UseBasicParsing -TimeoutSec 20 -MaximumRedirection 8
        return [pscustomobject]@{ Success = $true; StatusCode = [int]$response.StatusCode; Detail = "HTTPS доступен" }
    }
    catch {
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        return [pscustomobject]@{ Success = $false; StatusCode = $code; Detail = Protect-ReportText $_.Exception.Message }
    }
    finally { [Net.ServicePointManager]::SecurityProtocol = $oldTls }
}

function Show-Status {
    Show-Header
    Write-C "Проверяю соединение. Это может занять около минуты." Cyan
    $network = Get-ProxySnapshot -Refresh
    $gateway = Test-ProxyConnect -TargetHost "gateway.discord.gg"
    $api = Test-DiscordWebRequest -Uri "https://discord.com/api/v10/gateway"
    $download = Test-DiscordWebRequest -Uri $DiscordDownloadUrl -Method Head
    $script:LastDiagnostic = @(
        [pscustomobject]@{ Name = "Прокси → discord.com"; Good = $network.Discord.Success; Code = $network.Discord.StatusCode; Detail = $network.Discord.StatusLine },
        [pscustomobject]@{ Name = "Посторонние сайты запрещены"; Good = ($network.Blocked -and $network.Blocked.StatusCode -eq 403); Code = if ($network.Blocked) { $network.Blocked.StatusCode } else { 0 }; Detail = if ($network.Blocked) { $network.Blocked.StatusLine } else { "Не проверено: прокси недоступен" } },
        [pscustomobject]@{ Name = "Gateway · CONNECT"; Good = $gateway.Success; Code = $gateway.StatusCode; Detail = $gateway.StatusLine },
        [pscustomobject]@{ Name = "API Discord · HTTPS"; Good = $api.Success; Code = $api.StatusCode; Detail = $api.Detail },
        [pscustomobject]@{ Name = "Установщик · HTTPS и CDN"; Good = $download.Success; Code = $download.StatusCode; Detail = $download.Detail }
    )
    Write-Host ""
    foreach ($check in $script:LastDiagnostic) {
        $mark = if ($check.Good) { "[OK]" } else { "[!]" }
        $color = if ($check.Good) { [ConsoleColor]::Green } else { [ConsoleColor]::Yellow }
        Write-C ("$mark " + $check.Name + " · HTTP " + $check.Code) $color
        if (-not $check.Good) { Write-C ("    " + $check.Detail) Gray }
    }
    $snapshot = Get-MenuSnapshot -SkipNetwork
    Write-C ("Discord: " + $snapshot.DiscordState) $snapshot.DiscordColor
    Write-C ("Подключение: " + $snapshot.DroverState) $snapshot.DroverColor
    Write-C "Проверка Gateway подтверждает CONNECT, вход и голос проверяются в приложении." Gray
    if (@($script:LastDiagnostic | Where-Object { -not $_.Good }).Count -gt 0) {
        Write-C "Что сделать: проверьте интернет, доступ к прокси и его список разрешённых доменов." Yellow
        Write-C "Для поддержки выберите «Сохранить отчёт»." Yellow
    }
}

function Save-DiagnosticReport {
    try {
        $folder = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
        if ([string]::IsNullOrWhiteSpace($folder)) { $folder = Join-Path $env:LOCALAPPDATA "Pesherkino" }
        $folder = Join-Path $folder "Pesherkino-Reports"
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $path = Join-Path $folder ("Pesherkino-Discord-" + [DateTime]::Now.ToString("yyyyMMdd-HHmmss-fff") + ".txt")
        $snapshot = Get-MenuSnapshot -SkipNetwork
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("Pesherkino Discord | интерфейс 2.1")
        $lines.Add("Дата: " + [DateTimeOffset]::Now.ToString("o"))
        $lines.Add("PowerShell: " + $PSVersionTable.PSVersion)
        $lines.Add("ОС: " + [Environment]::OSVersion.Version + "; x64: " + [Environment]::Is64BitOperatingSystem)
        $lines.Add("Прокси: " + $ProxyHost + ":" + $ProxyPort)
        $lines.Add("Discord: " + $snapshot.DiscordState + "; подключение: " + $snapshot.DroverState)
        foreach ($dir in $snapshot.Directories) { $lines.Add("Версия Discord: " + (Protect-ReportText $dir)) }
        $lines.Add(""); $lines.Add("Последняя диагностика:")
        if ($script:LastDiagnostic.Count -eq 0) { $lines.Add("Не выполнялась. Выберите «Проверить соединение» для подробностей.") }
        foreach ($check in $script:LastDiagnostic) {
            $lines.Add(("{0}: {1}; HTTP {2}; {3}" -f $check.Name,$check.Good,$check.Code,(Protect-ReportText $check.Detail)))
        }
        $lines.Add(""); $lines.Add("События этой сессии:")
        foreach ($event in $script:SessionEvents) { $lines.Add((Protect-ReportText $event)) }
        [IO.File]::WriteAllLines($path,$lines.ToArray(),(New-Object Text.UTF8Encoding($true)))
        Write-C "[OK] Отчёт сохранён:" Green
        Write-C $path White
        Write-C "Просмотрите файл и при необходимости отправьте его в @pesherkino_support." Gray
        return $path
    }
    catch { Show-ActionError $_.Exception.Message "Проверьте доступ к папке документов и попробуйте сохранить отчёт ещё раз." }
}

function Get-CompatibilityHome {
    $path = Join-Path $LocalDir "Compatibility"
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}

function New-CompatibilityBackup {
    param([string]$Kind)
    $name = $Kind + "-" + [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + [guid]::NewGuid().ToString("N").Substring(0,8)
    $path = Join-Path (Get-CompatibilityHome) $name
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}

function Write-CompatibilityJson {
    param([string]$Path, [object]$Value)
    [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 64),(New-Object Text.UTF8Encoding($false)))
}

function ConvertTo-ProxyCidrs {
    param([string[]]$Addresses)
    $result = @()
    foreach ($address in $Addresses) {
        $ip = $null
        if (-not [Net.IPAddress]::TryParse($address.Trim(),[ref]$ip)) { throw "Некорректный IP прокси: $address" }
        $bytes = $ip.GetAddressBytes()
        if ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
            # Reject FakeDNS/benchmark ranges, loopback and non-public answers.
            if ($bytes[0] -eq 0 -or $bytes[0] -eq 10 -or $bytes[0] -eq 127 -or $bytes[0] -ge 224 -or
                ($bytes[0] -eq 169 -and $bytes[1] -eq 254) -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
                ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or ($bytes[0] -eq 198 -and $bytes[1] -ge 18 -and $bytes[1] -le 19)) {
                throw "DNS вернул локальный или FakeDNS IP $ip. Нужен настоящий публичный IP сервера прокси."
            }
            $result += $ip.ToString() + "/32"
        }
        elseif ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
            if (($bytes[0] -band 0xE0) -ne 0x20 -or $ip.ScopeId -ne 0) { throw "Нужен публичный IPv6 прокси: $ip" }
            $result += $ip.ToString() + "/128"
        }
    }
    if (-not $result.Count) { throw "IP сервера прокси не указан." }
    return @($result | Sort-Object -Unique)
}

function Get-CompatibilityProxyCidrs {
    $addresses = @()
    try {
        $lookup = [Net.Dns]::GetHostAddressesAsync($ProxyHost)
        if (-not $lookup.Wait(5000)) { throw "DNS timeout" }
        $addresses = @($lookup.Result | ForEach-Object { $_.ToString() })
        $cidrs = @(ConvertTo-ProxyCidrs $addresses)
        Write-C ("IP прокси: " + ($cidrs -join ", ")) Gray
        return $cidrs
    }
    catch {
        Write-C "Не удалось получить настоящий IP прокси. Happ может подменять DNS." Yellow
        $answer = Read-Host "Укажите публичный IP сервера $ProxyHost (несколько через запятую), Enter — отмена"
        if ([string]::IsNullOrWhiteSpace($answer)) { return @() }
        return @(ConvertTo-ProxyCidrs ($answer -split '\s*,\s*'))
    }
}

function Read-HappRoutingProfile {
    param([string]$Text)
    $Text = $Text.Trim().TrimStart([char]0xFEFF)
    if ($Text -match '^happ://routing/(?:onadd|add)/([^\s]+)$') {
        $base64 = [Uri]::UnescapeDataString($Matches[1]).Replace('-','+').Replace('_','/')
        $base64 = $base64.PadRight($base64.Length + ((4 - $base64.Length % 4) % 4),'=')
        $Text = (New-Object Text.UTF8Encoding($false,$true)).GetString([Convert]::FromBase64String($base64))
    }
    if ($Text.Length -gt 262144) { throw "Профиль маршрутизации слишком большой." }
    $profile = $Text | ConvertFrom-Json
    if ($null -eq $profile -or $profile -isnot [pscustomobject] -or
        [string]::IsNullOrWhiteSpace([string]$profile.Name) -or $null -eq $profile.PSObject.Properties['GlobalProxy']) {
        throw "Нужен экспорт профиля маршрутизации Happ с Name и GlobalProxy, а не ключ VPN или подписка."
    }
    foreach ($key in @('inbounds','outbounds','routing','servers','password','token')) {
        if ($null -ne $profile.PSObject.Properties[$key]) { throw "Это конфигурация подключения. Экспортируйте только профиль маршрутизации Happ." }
    }
    foreach ($key in @('DirectSites','DirectIp','ProxySites','ProxyIp','BlockSites','BlockIp')) {
        $property = $profile.PSObject.Properties[$key]
        if ($property -and $null -ne $property.Value) {
            if ($property.Value -isnot [array]) { throw "Поле $key должно быть массивом." }
            foreach ($entry in $property.Value) { if ($entry -isnot [string]) { throw "Некорректное правило в $key." } }
        }
    }
    return $profile
}

function ConvertTo-HappRoutingLink {
    param([object]$Profile)
    $json = $Profile | ConvertTo-Json -Depth 64 -Compress
    return "happ://routing/add/" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

function Add-HappProxyRules {
    param([object]$Profile, [string[]]$Cidrs)
    # Clone before editing: exported settings are also the rollback source.
    $copy = Read-HappRoutingProfile ($Profile | ConvertTo-Json -Depth 64)
    $domainRule = "full:" + $ProxyHost
    foreach ($pair in @(@{Key='DirectSites'; Values=@($domainRule)},@{Key='DirectIp'; Values=$Cidrs})) {
        $values = @($copy.($pair.Key) | Where-Object { $null -ne $_ }) + @($pair.Values)
        $copy | Add-Member NoteProperty $pair.Key @($values | Select-Object -Unique) -Force
    }
    # Only remove exact conflicting rules; broad geosite/geoip rules remain intact.
    foreach ($key in @('ProxySites','BlockSites')) {
        if ($copy.PSObject.Properties[$key]) {
            $values = @($copy.$key | Where-Object { $_ -ine $ProxyHost -and $_ -ine $domainRule -and $_ -ine ('domain:' + $ProxyHost) })
            $copy.$key = $values
        }
    }
    foreach ($key in @('ProxyIp','BlockIp')) {
        if ($copy.PSObject.Properties[$key]) {
            $values = @($copy.$key | Where-Object { $rule = $_; -not (@($Cidrs | ForEach-Object { $_; ($_ -split '/')[0] }) -contains $rule) })
            $copy.$key = $values
        }
    }
    $hosts = $copy.DnsHosts
    if ($null -eq $hosts) { $hosts = [pscustomobject]@{} }
    if ($hosts -isnot [pscustomobject]) { throw "DnsHosts должен быть JSON-объектом." }
    $ips = @($Cidrs | ForEach-Object { ($_ -split '/')[0] })
    $hostValue = if ($ips.Count -eq 1) { $ips[0] } else { $ips }
    $hosts | Add-Member NoteProperty $ProxyHost $hostValue -Force
    $copy | Add-Member NoteProperty DnsHosts $hosts -Force
    return $copy
}

function Open-HappRoutingLink {
    param([string]$Link)
    try { Set-Clipboard -Value $Link -ErrorAction Stop; Write-C "Ссылка маршрутизации скопирована. В Happ её можно импортировать из буфера." Gray } catch {}
    try { Start-Process -FilePath $Link -ErrorAction Stop | Out-Null }
    catch { Write-C "Не удалось открыть Happ автоматически. Импортируйте сохранённую ссылку из файла routing-link.txt." Yellow }
}

function Set-HappCompatibility {
    Show-Header
    Write-C "Happ TUN · исключение для прокси Pesherkino" Cyan
    Write-C "В Happ экспортируйте активный профиль маршрутизации нужной подписки." White
    Write-C "Потребуется ссылка happ://routing/add/... или JSON-файл этого профиля." Gray
    Write-C "При JSON-подписке, запрещающей импорт маршрутизации, используйте исключение по приложению ниже." Yellow
    $answer = Read-Host "Вставьте ссылку / путь к JSON-файлу; C — взять из буфера; Enter — показать исключение Discord из TUN"
    if ([string]::IsNullOrWhiteSpace($answer)) { Show-HappAppBypass; return }
    if ($answer -ieq 'C') { $answer = [string](Get-Clipboard -Raw -ErrorAction Stop) }
    $candidate = $answer.Trim().Trim('"')
    if ($candidate -notmatch '^(happ://|\{)' -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        if ((Get-Item -LiteralPath $candidate).Length -gt 262144) { throw "JSON-файл слишком большой." }
        $answer = [IO.File]::ReadAllText($candidate)
    }
    $profile = Read-HappRoutingProfile $answer
    $cidrs = @(Get-CompatibilityProxyCidrs)
    if (-not $cidrs.Count) { return }
    $updated = Add-HappProxyRules $profile $cidrs
    $backup = New-CompatibilityBackup "Happ"
    Write-CompatibilityJson (Join-Path $backup 'before.json') $profile
    Write-CompatibilityJson (Join-Path $backup 'routing.json') $updated
    $link = ConvertTo-HappRoutingLink $updated
    [IO.File]::WriteAllText((Join-Path $backup 'routing-link.txt'),$link,(New-Object Text.UTF8Encoding($false)))
    Write-CompatibilityJson (Join-Path $backup 'manifest.json') ([ordered]@{Kind='Happ'; Name=[string]$profile.Name; Created=[DateTime]::UtcNow.ToString('o')})
    Write-C ("[OK] Профиль подготовлен: " + $profile.Name) Green
    Write-C ("Резервная копия и ссылка: " + $backup) Gray
    Open-HappRoutingLink $link
    Write-C "Завершите импорт в нужную подписку Happ, выберите этот профиль и переподключите TUN." White
    Write-C "Порядок правил сохранён. Если широкое Proxy/Block-правило перехватывает прокси, проверьте приоритет Direct в Happ." Yellow
    Write-C "IP закреплён в DnsHosts: при смене IP сервера повторите настройку." Gray
    Show-HappAppBypass
}

function Show-HappAppBypass {
    Write-C "Для голоса: Happ → настройки прокси для приложений → режим исключений (Bypass)." Cyan
    Write-C "Добавьте установленные Discord / Discord PTB / Discord Canary и переподключите TUN." White
    Write-C "В актуальном Happ используйте Xray TUN с поддержкой исключений приложений." Gray
    foreach ($dir in @(Get-ActiveDiscordDirs)) {
        foreach ($name in @('Discord.exe','DiscordPTB.exe','DiscordCanary.exe')) {
            $exe = Join-Path $dir $name
            if (Test-Path -LiteralPath $exe) { Write-C $exe Gray }
        }
    }
    Write-C "После обновления Discord проверьте путь исключения. Затем проверьте вход и голосовой канал." Gray
    Write-C "Импорт маршрутизации не меняет список приложений автоматически." Gray
}

function Get-ZapretService {
    try { return Get-CimInstance Win32_Service -Filter "Name='zapret'" -ErrorAction Stop } catch { return $null }
}

function Get-WinwsExecutable {
    param([string]$CommandLine)
    if ($CommandLine -match '^\s*"([^"]*\\winws\.exe)"(?:\s|$)') { return $Matches[1] }
    if ($CommandLine -match '^\s*([^\s"]*\\winws\.exe)(?:\s|$)') { return $Matches[1] }
    return $null
}

function Test-FlowsealFolder {
    param([string]$Path)
    return ((Test-Path -LiteralPath (Join-Path $Path 'service.bat') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path 'bin\winws.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path 'lists') -PathType Container) -and
        @((Get-ChildItem -LiteralPath $Path -Filter 'general*.bat' -File -ErrorAction SilentlyContinue)).Count -gt 0)
}

function Get-ZapretFolders {
    $candidates = @()
    $service = Get-ZapretService
    if ($service) {
        $exe = Get-WinwsExecutable $service.PathName
        if ($exe) { $candidates += Split-Path (Split-Path $exe -Parent) -Parent }
    }
    try {
        foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='winws.exe'" -ErrorAction Stop)) {
            if ($process.ExecutablePath) { $candidates += Split-Path (Split-Path $process.ExecutablePath -Parent) -Parent }
        }
    } catch {}
    foreach ($path in @($candidates | Select-Object -Unique)) { if (Test-FlowsealFolder $path) { $path } }
}

function Select-ZapretFolder {
    $found = @(Get-ZapretFolders)
    for ($i=0; $i -lt $found.Count; $i++) { Write-C (([string]($i+1)) + ". " + $found[$i]) White }
    Write-C "Папка может находиться на любом диске. Укажите корень сборки с service.bat, bin и lists." Gray
    $answer = Read-Host "Введите путь или номер найденной папки; Enter — отмена"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $null }
    $number = 0
    if ([int]::TryParse($answer,[ref]$number) -and $number -ge 1 -and $number -le $found.Count) { $answer = $found[$number-1] }
    $path = (Resolve-Path -LiteralPath $answer.Trim().Trim('"') -ErrorAction Stop).ProviderPath
    if (-not (Test-FlowsealFolder $path)) { throw "В этой папке не найдена сборка Flowseal: нужны service.bat, bin\winws.exe, lists и general*.bat." }
    # Flowseal's cmd/service parser expands these characters even inside quotes.
    if ($path -match '[%!\r\n"]') { throw "Для Flowseal нужен путь без %, ! и кавычек. Переместите папку и повторите." }
    return $path
}

function Read-ZapretBatch {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt 1048576) { throw "Слишком большой BAT: $Path" }
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
    $encoding = New-Object Text.UTF8Encoding($bom,$true)
    try { $text = $encoding.GetString($bytes).TrimStart([char]0xFEFF) }
    catch { throw "BAT должен быть в UTF-8, как актуальная сборка Flowseal: $Path" }
    return [pscustomobject]@{Text=$text; Encoding=$encoding}
}

function Add-ZapretCompatibilityProfiles {
    param([string]$Text, [string]$IpSetPath, [switch]$Batch)
    if ($Text.Contains('pesherkino-proxy-ip.txt')) { return $Text }
    $checkPath = if ($Batch) { $IpSetPath -replace '^%LISTS%', '' } else { $IpSetPath }
    if ($checkPath -match '[%!\r\n"]') { throw "Некорректный путь списка IP." }
    # An action-free profile passes matching packets unchanged. Profiles are first-match.
    $profiles = '--filter-tcp=' + $ProxyPort + ' --ipset="' + $IpSetPath + '" --new '
    $profiles += '--filter-udp=19294-19344,50000-65535 --filter-l7=discord,stun --new '
    $searchStart = 0
    if ($Batch) {
        $launches = [regex]::Matches($Text,'(?im)^\s*start\s+[^\r\n]*"%BIN%winws\.exe"[^\r\n]*')
        if ($launches.Count -ne 1 -or $Text -notmatch '(?im)^\s*set\s+"LISTS=%~dp0lists\\"\s*$') {
            throw "Неподдерживаемый формат BAT. Ожидается актуальная стратегия Flowseal с одним запуском winws.exe."
        }
        $searchStart = $launches[0].Index + $launches[0].Length
        if (-not $launches[0].Value.TrimEnd().EndsWith('^')) { throw "Параметры winws должны продолжаться на следующей строке." }
        $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $profiles = $profiles.Replace(' --new ',(' --new ^' + $newline))
    }
    $match = [regex]::Match($Text.Substring($searchStart),'--filter-(?:tcp|udp|l7|l3)=')
    if (-not $match.Success) { throw "Не найдены профили фильтрации winws." }
    $position = $searchStart + $match.Index
    if ($Batch -and $Text.Substring($searchStart,$match.Index) -notmatch '^\s*$') { throw "Неизвестные параметры перед первым профилем BAT." }
    return $Text.Insert($position,$profiles)
}

function Test-CompatibilityAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Set-ZapretServicePath {
    param([string]$PathName)
    $service = Get-ZapretService
    if (-not $service) { throw "Служба zapret больше не найдена." }
    $running = $service.State -eq 'Running'
    if ($running) { Stop-Service -Name zapret -ErrorAction Stop }
    try {
        $result = Invoke-CimMethod -InputObject $service -MethodName Change -Arguments @{PathName=$PathName} -ErrorAction Stop
        if ($result.ReturnValue -ne 0) { throw "Не удалось изменить службу zapret, код $($result.ReturnValue)." }
    }
    finally { if ($running) { Start-Service -Name zapret -ErrorAction Stop } }
}

function Restore-ZapretBackup {
    param([string]$Backup)
    $manifest = [IO.File]::ReadAllText((Join-Path $Backup 'manifest.json')) | ConvertFrom-Json
    if ($manifest.Kind -ne 'Zapret') { throw "Это не резервная копия Zapret." }
    # Preflight everything: never overwrite edits made after our configuration.
    foreach ($file in $manifest.Files) {
        if (Test-Path -LiteralPath $file.Path) {
            $hash = (Get-FileHash -LiteralPath $file.Path -Algorithm SHA256).Hash
            if ($hash -ne $file.AfterHash -and $hash -ne $file.BeforeHash) { throw "Файл изменён после настройки: $($file.Path). Сохраните свои изменения перед откатом." }
        }
        elseif ($file.BeforeExists) { throw "Исходный файл перемещён или удалён: $($file.Path)." }
        if ($file.BeforeExists -and (Get-FileHash -LiteralPath (Join-Path $Backup $file.Copy) -Algorithm SHA256).Hash -ne $file.BeforeHash) {
            throw "Резервная копия повреждена: $($file.Copy)."
        }
    }
    $service = $null
    if ($manifest.ServiceBefore) {
        $service = Get-ZapretService
        if (-not $service -or ($service.PathName -ne $manifest.ServiceAfter -and $service.PathName -ne $manifest.ServiceBefore)) { throw "Конфигурация службы zapret изменилась. Автоматический откат остановлен." }
        if (-not (Test-CompatibilityAdmin)) { throw "Для отката службы запустите PowerShell от администратора." }
    }
    foreach ($file in $manifest.Files) {
        if ($file.BeforeExists) { [IO.File]::Copy((Join-Path $Backup $file.Copy),$file.Path,$true) }
        elseif (Test-Path -LiteralPath $file.Path) { Remove-Item -LiteralPath $file.Path -ErrorAction Stop }
    }
    if ($service -and $service.PathName -ne $manifest.ServiceBefore) { Set-ZapretServicePath $manifest.ServiceBefore }
    if ($service -and $manifest.ServiceWasRunning -and (Get-ZapretService).State -ne 'Running') { Start-Service -Name zapret -ErrorAction Stop }
    $manifest | Add-Member NoteProperty Restored $true -Force
    Write-CompatibilityJson (Join-Path $Backup 'manifest.json') $manifest
}

function Set-ZapretCompatibility {
    Show-Header
    Write-C "Flowseal Zapret · совместимость с Pesherkino" Cyan
    $folder = Select-ZapretFolder
    if (-not $folder) { return }
    $service = Get-ZapretService
    $serviceExe = if ($service) { Get-WinwsExecutable $service.PathName } else { $null }
    $ownsService = $serviceExe -and $serviceExe -ieq (Join-Path $folder 'bin\winws.exe')
    if ($ownsService -and -not (Test-CompatibilityAdmin)) { throw "Для изменения установленной службы Zapret запустите PowerShell от администратора и повторите этот пункт." }
    foreach ($directory in @(Get-ChildItem -LiteralPath (Get-CompatibilityHome) -Directory)) {
        $manifestPath = Join-Path $directory.FullName 'manifest.json'
        if (Test-Path -LiteralPath $manifestPath) {
            $old = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
            if ($old.Kind -eq 'Zapret' -and $old.Folder -ieq $folder -and -not $old.Restored) {
                Write-C "Эта папка уже настроена. Для смены IP или обновлённой сборки сначала отмените прежние изменения." Yellow
                return
            }
        }
    }
    $cidrs = @(Get-CompatibilityProxyCidrs)
    if (-not $cidrs.Count) { return }
    $ipset = Join-Path $folder 'lists\pesherkino-proxy-ip.txt'
    $changes = @([pscustomobject]@{Path=$ipset; Text=($cidrs -join "`r`n") + "`r`n"; Encoding=(New-Object Text.UTF8Encoding($false))})
    # Prepare every strategy before changing any file, including installed-service arguments.
    foreach ($bat in @(Get-ChildItem -LiteralPath $folder -Filter 'general*.bat' -File)) {
        $source = Read-ZapretBatch $bat.FullName
        $updated = Add-ZapretCompatibilityProfiles $source.Text '%LISTS%pesherkino-proxy-ip.txt' -Batch
        if ($updated -ne $source.Text) { $changes += [pscustomobject]@{Path=$bat.FullName; Text=$updated; Encoding=$source.Encoding} }
    }
    $serviceAfter = if ($ownsService) { Add-ZapretCompatibilityProfiles $service.PathName $ipset } else { $null }
    $backup = New-CompatibilityBackup 'Zapret'
    $records = @()
    foreach ($change in $changes) {
        $exists = Test-Path -LiteralPath $change.Path -PathType Leaf
        $copy = [string]$records.Count + '.bak'
        $beforeHash = $null
        if ($exists) {
            [IO.File]::Copy($change.Path,(Join-Path $backup $copy),$false)
            $beforeHash = (Get-FileHash -LiteralPath $change.Path -Algorithm SHA256).Hash
        }
        $records += [pscustomobject]@{Path=$change.Path; Copy=$copy; BeforeExists=$exists; BeforeHash=$beforeHash; AfterHash=$beforeHash}
    }
    $manifest = [pscustomobject]@{Kind='Zapret'; Folder=$folder; Created=[DateTime]::UtcNow.ToString('o'); Files=$records;
        ServiceBefore=$(if ($ownsService) { $service.PathName } else { $null }); ServiceAfter=$serviceAfter;
        ServiceWasRunning=($ownsService -and $service.State -eq 'Running'); Restored=$false}
    $manifestPath = Join-Path $backup 'manifest.json'
    Write-CompatibilityJson $manifestPath $manifest
    try {
        for ($i=0; $i -lt $changes.Count; $i++) {
            [IO.File]::WriteAllText($changes[$i].Path,$changes[$i].Text,$changes[$i].Encoding)
            $records[$i].AfterHash = (Get-FileHash -LiteralPath $changes[$i].Path -Algorithm SHA256).Hash
            Write-CompatibilityJson $manifestPath $manifest
        }
        if ($ownsService -and $serviceAfter -ne $service.PathName) { Set-ZapretServicePath $serviceAfter }
    }
    catch {
        $failure = $_.Exception.Message
        try { Restore-ZapretBackup $backup }
        catch { Write-C ("Автоматический откат не завершён: " + $_.Exception.Message + ". Копии: " + $backup) Red }
        throw "Настройка Zapret не завершена: $failure"
    }
    Write-C ("[OK] Добавлены правила в стратегий: " + ($changes.Count-1)) Green
    Write-C "Соединение с прокси и распознанный Discord/STUN UDP проходят без дополнительной обработки Zapret." White
    Write-C ("Резервная копия: " + $backup) Gray
    if ($ownsService) { Write-C "Параметры службы обновлены; работающая служба перезапущена." Green }
    else { Write-C "Перезапустите запущенный general*.bat из этой папки, чтобы применить параметры." Yellow }
    Write-C "Проверьте вход в Discord и голос. После обновления сборки проверьте совместимость повторно." Gray
}

function Restore-Compatibility {
    $backups = @(Get-ChildItem -LiteralPath (Get-CompatibilityHome) -Directory | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json')
    } | Sort-Object Name -Descending)
    if (-not $backups.Count) { Write-C "Резервных копий пока нет." Gray; return }
    for ($i=0; $i -lt $backups.Count; $i++) { Write-C (([string]($i+1)) + '. ' + $backups[$i].Name) White }
    $answer = Read-Host "Номер копии для отката; Enter — отмена"
    $number = 0
    if (-not [int]::TryParse($answer,[ref]$number) -or $number -lt 1 -or $number -gt $backups.Count) { return }
    $backup = $backups[$number-1].FullName
    $manifest = [IO.File]::ReadAllText((Join-Path $backup 'manifest.json')) | ConvertFrom-Json
    if ($manifest.Kind -eq 'Happ') {
        $profile = Read-HappRoutingProfile ([IO.File]::ReadAllText((Join-Path $backup 'before.json')))
        Open-HappRoutingLink (ConvertTo-HappRoutingLink $profile)
        Write-C "Импортируйте прежний профиль в ту же подписку Happ и переподключите TUN." White
        Write-C "Исключения приложений, добавленные вручную, убираются в настройках Happ." Gray
    }
    elseif ($manifest.Kind -eq 'Zapret') {
        Restore-ZapretBackup $backup
        Write-C "[OK] Файлы и параметры службы восстановлены." Green
        Write-C "Если Zapret запускался через BAT, перезапустите его для применения." Gray
    }
}

function Show-Compatibility {
    while ($true) {
        Show-Header
        Write-C "Совместимость" Cyan
        Write-C "1. Happ TUN — исключения для прокси и инструкция для голоса" White
        Write-C "2. Flowseal Zapret — настроить выбранную папку" White
        Write-C "3. Отменить изменения из резервной копии" White
        Write-C "0. Назад" Gray
        $choice = Read-Host "Выберите действие"
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq '0') { return }
        try {
            switch ($choice) {
                '1' { Set-HappCompatibility }
                '2' { Set-ZapretCompatibility }
                '3' { Restore-Compatibility }
                default { continue }
            }
        } catch { Show-ActionError $_.Exception.Message "Настройки, копии и откат доступны в разделе совместимости." }
        Read-Host "Enter для продолжения" | Out-Null
    }
}

function Show-Help {
    Show-Header
    Write-C "Помощь и поддержка" Cyan
    Write-C "1. Discord отсутствует — выберите «Установить Discord»." White
    Write-C "2. Перестал работать после обновления — «Восстановить подключение»." White
    Write-C "3. Проблемы со входом — «Проверить соединение», затем «Сохранить отчёт»." White
    Write-C "Вход выполняется в Discord: пароль и 2FA либо QR-код с телефона." Gray
    Write-C "Для Happ TUN и Zapret откройте «Совместимость с Happ / Zapret»." Yellow
    Write-C "Поддержка: @pesherkino_support" Cyan
}

function Show-About {
    Show-Header
    Write-C "Pesherkino VPN · Работаем ради вас" Cyan
    Write-C "Бот: https://t.me/pesherkino_bot" White
    Write-C "Новости: https://t.me/pesherkinonews" White
    Write-C "Сайт: https://cabinet.netherus.com" White
    Write-C "Поддержка: https://t.me/pesherkino_support" White
    Write-C "Подключение Discord использует Discord Drover." Gray
    Write-C "Оригинальный проект: https://github.com/hdrover/discord-drover" Gray
}

function Split-TuiText {
    param([string]$Text, [int]$Width)
    $Text = $Text -replace '[\r\n\t]', ' '
    $Width = [Math]::Max(1,$Width)
    while ($Text.Length -gt $Width) {
        $break = $Text.LastIndexOf(' ', $Width - 1, $Width)
        if ($break -le 0) { $break = $Width }
        $Text.Substring(0,$break)
        $Text = $Text.Substring($break).TrimStart()
    }
    $Text
}

function Write-TuiLine {
    param([string]$Text = "", [ConsoleColor]$Color = [ConsoleColor]::Gray, [int]$Width = 64)
    foreach ($line in @(Split-TuiText -Text $Text -Width $Width)) {
        Write-Host "│ " -NoNewline -ForegroundColor DarkGray
        if ($Color -eq $script:Accent) { Write-Accent $line.PadRight($Width) -NoNewline }
        else { Write-Host $line.PadRight($Width) -NoNewline -ForegroundColor $Color }
        Write-Host " │" -ForegroundColor DarkGray
    }
}

function Write-TuiStatus {
    param([string]$Name, [string]$Value, [ConsoleColor]$ValueColor, [int]$Width = 64)
    Write-TuiLine -Text (("  " + $Name + ": ").PadRight(16) + $Value) -Color $ValueColor -Width $Width
}

function Get-MenuItems {
    param([object]$Snapshot)
    return @(
        [pscustomobject]@{ Key = "1"; Label = $Snapshot.PrimaryLabel; Hint = $Snapshot.PrimaryHint; Action = $Snapshot.PrimaryAction },
        [pscustomobject]@{ Key = "2"; Label = "Восстановить подключение"; Hint = "Если Discord перестал работать"; Action = "Repair" },
        [pscustomobject]@{ Key = "3"; Label = "Проверить соединение"; Hint = "Прокси, API и сервер загрузки"; Action = "Status" },
        [pscustomobject]@{ Key = "4"; Label = "Сохранить отчёт"; Hint = "Для обращения в поддержку"; Action = "Report" },
        [pscustomobject]@{ Key = "5"; Label = "Помощь и поддержка"; Hint = ""; Action = "Help" },
        [pscustomobject]@{ Key = "6"; Label = "О Pesherkino"; Hint = ""; Action = "About" },
        [pscustomobject]@{ Key = "7"; Label = "Удалить подключение"; Hint = "Сам Discord останется"; Action = "Uninstall" },
        [pscustomobject]@{ Key = "8"; Label = "Совместимость с Happ / Zapret"; Hint = "Исключения, резервные копии и откат"; Action = "Compatibility" },
        [pscustomobject]@{ Key = "0"; Label = "Выход"; Hint = ""; Action = "Exit" }
    )
}

function Write-TuiOption {
    param([object]$Item, [bool]$Selected, [int]$Width = 64)
    $marker = if ($Selected) { "›" } else { " " }
    $prefix = " $marker [$($Item.Key)] "
    $first = $true
    foreach ($line in @(Split-TuiText $Item.Label ($Width - $prefix.Length))) {
        $text = if ($first) { $prefix + $line } else { (" " * $prefix.Length) + $line }
        $first = $false
        Write-Host "│ " -NoNewline -ForegroundColor DarkGray
        if ($Selected) {
            if ($script:UseAnsi) {
                $esc = [char]27
                Write-Host ("${esc}[48;2;52;39;25m${esc}[38;2;255;171;88m" + $text.PadRight($Width) + "${esc}[0m") -NoNewline
            }
            else { Write-Host $text.PadRight($Width) -NoNewline -ForegroundColor Yellow -BackgroundColor DarkGray }
        }
        else { Write-Host $text.PadRight($Width) -NoNewline -ForegroundColor Gray }
        Write-Host " │" -ForegroundColor DarkGray
    }
    if ($Item.Hint) { Write-TuiLine -Text ((" " * $prefix.Length) + $Item.Hint) -Width $Width -Color DarkGray }
}

function Draw-MainMenu {
    param([int]$Selected, [object]$Snapshot)
    Clear-Host
    $w = Get-TuiWidth
    $items = @(Get-MenuItems $Snapshot)
    # Fit a standard 80x24 terminal; detailed hints remain in Help.
    try {
        if ([Console]::WindowHeight -gt 0 -and [Console]::WindowHeight -lt 32) {
            for ($i = 1; $i -lt $items.Count; $i++) { $items[$i].Hint = "" }
        }
    } catch {}
    Write-Host ("╭" + ("─" * ($w + 2)) + "╮") -ForegroundColor DarkGray
    Write-TuiLine " PESHERKINO DISCORD" $script:Accent $w
    Write-TuiLine " Работаем ради вас" Gray $w
    Write-Host ("├" + ("─" * ($w + 2)) + "┤") -ForegroundColor DarkGray
    Write-TuiStatus "Прокси" $Snapshot.ProxyState $Snapshot.ProxyColor $w
    Write-TuiStatus "Discord" $Snapshot.DiscordState $Snapshot.DiscordColor $w
    Write-TuiStatus "Подключение" $Snapshot.DroverState $Snapshot.DroverColor $w
    Write-Host ("├" + ("─" * ($w + 2)) + "┤") -ForegroundColor DarkGray
    $rows = @()
    for ($i = 0; $i -lt $items.Count; $i++) {
        $top = $null
        try { $top = [Console]::CursorTop } catch {}
        $rows += $top
        Write-TuiOption $items[$i] ($i -eq $Selected) $w
    }
    Write-Host ("├" + ("─" * ($w + 2)) + "┤") -ForegroundColor DarkGray
    Write-TuiLine " @pesherkino_support" Gray $w
    Write-TuiLine " ↑ ↓ / W S · Enter · Esc · R обновить" DarkGray $w
    Write-TuiLine " Действие также можно выбрать цифрой" DarkGray $w
    Write-Host ("╰" + ("─" * ($w + 2)) + "╯") -ForegroundColor DarkGray
    $end = $null
    try { $end = [Console]::CursorTop } catch {}
    $script:MenuLayout = [pscustomobject]@{ Rows = $rows; End = $end; Width = $w; Items = $items }
}

function Update-MenuSelection {
    param([int]$Previous, [int]$Selected)
    try {
        $layout = $script:MenuLayout
        if (-not $layout -or $null -eq $layout.End -or $layout.Width -ne (Get-TuiWidth)) { return $false }
        foreach ($index in @($Previous,$Selected)) {
            if ($null -eq $layout.Rows[$index]) { return $false }
            [Console]::SetCursorPosition(0,$layout.Rows[$index])
            Write-TuiOption $layout.Items[$index] ($index -eq $Selected) $layout.Width
        }
        [Console]::SetCursorPosition(0,$layout.End)
        return $true
    }
    catch { return $false }
}

function Wait-TuiKey {
    Write-Host ""
    Write-Host "Нажмите любую клавишу, чтобы вернуться в меню..." -ForegroundColor Gray
    try { [void][Console]::ReadKey($true) } catch { Read-Host "Enter для продолжения" | Out-Null }
}

function Invoke-MenuAction {
    param([string]$Action)
    switch ($Action) {
        "InstallDiscord" { Install-DiscordAndDrover }
        "Install" { Deploy-Drover -Mode Install | Out-Null }
        "Repair" { Deploy-Drover -Mode Repair | Out-Null }
        "Launch" { Show-Header; Start-DiscordForLogin }
        "Status" { Show-Status }
        "Report" { Show-Header; Save-DiagnosticReport | Out-Null }
        "Help" { Show-Help }
        "About" { Show-About }
        "Compatibility" { Show-Compatibility }
        "Happ" { Set-HappCompatibility }
        "Zapret" { Set-ZapretCompatibility }
        "Uninstall" { Uninstall-PesherkinoDiscord }
    }
}

function Show-FallbackMenu {
    while ($true) {
        Show-Header
        $snapshot = Get-MenuSnapshot
        Write-C ("Прокси: " + $snapshot.ProxyState) $snapshot.ProxyColor
        Write-C ("Discord: " + $snapshot.DiscordState + "; подключение: " + $snapshot.DroverState) White
        $items = @(Get-MenuItems $snapshot)
        foreach ($item in $items) { Write-C ($item.Key + ". " + $item.Label) White }
        Write-C "R. Обновить состояние" Gray
        $choice = Read-Host "Выберите действие"
        # Read-Host returns an empty value at EOF when stdin is redirected.
        if ($null -eq $choice -or ([Console]::IsInputRedirected -and [string]::IsNullOrEmpty($choice))) { return }
        if ($choice -ieq "r") { $null = Get-MenuSnapshot -RefreshNetwork; continue }
        $item = $items | Where-Object Key -eq $choice | Select-Object -First 1
        if (-not $item) { continue }
        if ($item.Action -eq "Exit") { return }
        try { Invoke-MenuAction $item.Action } catch { Show-ActionError $_.Exception.Message }
        Read-Host "Enter для продолжения" | Out-Null
    }
}

function Show-Menu {
    $selected = 0
    try {
        $null = [Console]::KeyAvailable
        if ([Console]::IsInputRedirected -or [Console]::WindowWidth -lt 45 -or [Console]::WindowHeight -lt 24) { throw "Use text menu" }
    }
    catch { Show-FallbackMenu; return }
    $cursorVisible = $true
    try { $cursorVisible = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch {}
    try {
        Show-Header
        Write-Host "Проверяю подключение..." -ForegroundColor Gray
        $snapshot = Get-MenuSnapshot
        Draw-MainMenu $selected $snapshot
        while ($true) {
            try { $key = [Console]::ReadKey($true) } catch { Show-FallbackMenu; return }
            $items = @(Get-MenuItems $snapshot)
            $previous = $selected
            $execute = $false
            switch ([string]$key.Key) {
                "UpArrow" { $selected = ($selected + $items.Count - 1) % $items.Count }
                "W" { $selected = ($selected + $items.Count - 1) % $items.Count }
                "DownArrow" { $selected = ($selected + 1) % $items.Count }
                "S" { $selected = ($selected + 1) % $items.Count }
                "Escape" { return }
                "R" { $snapshot = Get-MenuSnapshot -RefreshNetwork; Draw-MainMenu $selected $snapshot }
                "Enter" { $execute = $true }
                default {
                    for ($i = 0; $i -lt $items.Count; $i++) {
                        if ([string]$key.KeyChar -eq $items[$i].Key) { $selected = $i; $execute = $true; break }
                    }
                }
            }
            if ($execute) {
                if ($items[$selected].Action -eq "Exit") { return }
                try { [Console]::CursorVisible = $true } catch {}
                try { Invoke-MenuAction $items[$selected].Action } catch { Show-ActionError $_.Exception.Message }
                Wait-TuiKey
                try { [Console]::CursorVisible = $false } catch {}
                $snapshot = Get-MenuSnapshot
                Draw-MainMenu $selected $snapshot
            }
            elseif ($previous -ne $selected) {
                if (-not (Update-MenuSelection $previous $selected)) { Draw-MainMenu $selected $snapshot }
            }
        }
    }
    finally { try { [Console]::CursorVisible = $cursorVisible } catch {} }
}

try {
    switch ($Action) {
        "Install" { Deploy-Drover -Mode Install | Out-Null }
        "InstallDiscord" { Install-DiscordAndDrover }
        "Repair" { Deploy-Drover -Mode Repair | Out-Null }
        "Uninstall" { Uninstall-PesherkinoDiscord }
        "Status" { Show-Status }
        "Report" { Save-DiagnosticReport | Out-Null }
        "Help" { Show-Help }
        "About" { Show-About }
        "Compatibility" { Show-Compatibility }
        "Happ" { Set-HappCompatibility }
        "Zapret" { Set-ZapretCompatibility }
        default { Show-Menu }
    }
}
finally {
    try {
        if ($null -ne $script:OriginalBackground) { $Host.UI.RawUI.BackgroundColor = $script:OriginalBackground }
        if ($null -ne $script:OriginalForeground) { $Host.UI.RawUI.ForegroundColor = $script:OriginalForeground }
    } catch {}
}
