# DiscordFix

Простой PowerShell-установщик для запуска Discord через отдельный Pesherkino proxy.

Скрипт автоматически находит установленный Discord, закрывает его перед изменением файлов, скачивает актуальный релиз Discord Drover, устанавливает нужные файлы и создаёт `drover.ini` с настройкой Pesherkino proxy.

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
- Проверка реального HTTP CONNECT до Discord через Pesherkino proxy.
- Проверка, что посторонние сайты через proxy заблокированы.
- Удаление установленной конфигурации Pesherkino Discord.

## Совместимость

- Не используйте одновременно с Zapret.
- Не используйте одновременно с VPN в TUN-режиме.
- Скрипт не меняет системный proxy Windows.

## Pesherkino VPN

- Бот: [@pesherkino_bot](https://t.me/pesherkino_bot)
- Новости: [t.me/pesherkinonews](https://t.me/pesherkinonews)
- Поддержка: [@pesherkino_support](https://t.me/pesherkino_support)
- Сайт: [cabinet.netherus.com](https://cabinet.netherus.com)

## Благодарность Discord Drover

Этот проект использует **Discord Drover** для перенаправления сетевых соединений Discord через HTTP proxy.

Большое спасибо автору и участникам проекта **Discord Drover** за разработку и поддержку инструмента.

Оригинальный проект:

**[hdrover/discord-drover](https://github.com/hdrover/discord-drover)**

`DiscordFix` не является заменой Discord Drover: PowerShell-скрипт автоматизирует его загрузку, установку, переустановку и настройку для инфраструктуры Pesherkino. Файлы Discord Drover загружаются из официальных релизов оригинального репозитория.
