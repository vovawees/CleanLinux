# Clean Linux — журнал изменений

Формат основан на [Keep a Changelog], версияция — [Calendar Versioning]
(`YYYY.MM[.MICRO]`), как у образа Arch Linux.

## [Unreleased]

### Added

- Скрипт сборки `scripts/build.sh`, Makefile и CI-сборка ISO в GitHub Actions.
- Структура репозитория: профили archiso отделены от инфраструктуры сборки.

### Changed

- Профиль live-ISO перенесён из `iso/` в `profiles/cleanlinux/` и заново
  синхронизирован с эталонным профилем `releng` archiso 89.
- Сборка стала воспроизводимой: `SOURCE_DATE_EPOCH` фиксируется по последнему
  коммиту.

## [0.1.0] - 2026-08-25

### Added

- Первый рабочий профиль live-/install-ISO на базе archiso с брендингом
  Clean Linux: имя, лого ASCII-art, тихая загрузка, поддержка старых GPU AMD.

[Keep a Changelog]: https://keepachangelog.com/ru/1.1.0/
[Calendar Versioning]: https://calver.org/
[Unreleased]: https://github.com/vovawees/Clean-Linux/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/vovawees/Clean-Linux/releases/tag/v0.1.0
