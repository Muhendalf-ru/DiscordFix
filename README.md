# DiscordFix

Скрипт автоматически находит установленный Discord, закрывает его перед изменением файлов, скачивает актуальный релиз Discord Drover, устанавливает нужные файлы и создаёт `drover.ini`.

## Быстрый запуск

Откройте PowerShell и выполните:

```powershell
iex (irm 'https://raw.githubusercontent.com/Muhendalf-ru/DiscordFix/main/Pesherkino-Discord.ps1')
```

## Возможности

- Discord Stable, Canary и PTB.
- Поиск Discord в стандартных каталогах и через реестр Windows.
- Автоматическое закрытие запущенного Discord перед установкой и Repair.
- Установка и переустановка Discord Drover.
- Проверка актуального релиза и SHA-256, если digest опубликован GitHub.
- Проверка реального HTTP CONNECT до Discord через proxy.
- Проверка, что посторонние сайты через proxy заблокированы.

## Совместимость

- Не используйте одновременно с Zapret.
- Не используйте одновременно с VPN в TUN-режиме.
- Скрипт не меняет системный proxy Windows.

## Благодарность Discord Drover

Этот проект использует **Discord Drover** для перенаправления сетевых соединений Discord через HTTP proxy.

Большое спасибо автору и участникам проекта **Discord Drover** за разработку и поддержку инструмента.

Оригинальный проект:

**[hdrover/discord-drover](https://github.com/hdrover/discord-drover)**

`DiscordFix` не является заменой Discord Drover. Файлы Discord Drover загружаются из официальных релизов оригинального репозитория.
