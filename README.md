# Clean Linux

Собственный дистрибутив на базе [Arch Linux]: минималистичный, чистый и предсказуемый.

**Статус:** ранняя разработка. Сейчас собирается live-/install-ISO на базе профиля
archiso; собственные пакеты и установщик — следующие этапы.

## Архитектура репозитория

| Каталог | Назначение |
|---|---|
| `profiles/cleanlinux/` | Профиль [archiso]: состав пакетов, оверлей `airootfs`, конфигурация загрузчиков (systemd-boot / GRUB / syslinux) |
| `scripts/` | Скрипты сборки (`build.sh`) |
| `packages/` | Собственные пакеты (PKGBUILD) — зарезервировано |
| `config/` | Системные конфиги устанавливаемой системы — зарезервировано |
| `.github/workflows/` | CI: автоматическая сборка ISO |

Профиль отделён от инфраструктуры сборки: в `profiles/` можно держать несколько
вариантов образа (full / minimal / rescue), каждый собирается одной командой.

## Требования к сборке

- Arch Linux или контейнер `archlinux:base-devel`
- Пакеты: `archiso`, `git` (в CI ставятся автоматически)

## Сборка ISO

```bash
make build            # профиль по умолчанию: profiles/cleanlinux
make build PROFILE=profiles/minimal   # другой профиль
# результат: out/cleanlinux-<дата>-x86_64.iso
make clean            # удалить work/ и out/
```

`scripts/build.sh` экспортирует `SOURCE_DATE_EPOCH` из последнего коммита —
сборка воспроизводима для одинакового дерева.

## Быстрый тест в QEMU (UEFI)

```bash
qemu-system-x86_64 -m 2G -enable-kvm \
  -bios /usr/share/ovmf/x64/OVMF_CODE.fd \
  -cdrom out/cleanlinux-*-x86_64.iso
```

## CI

При изменениях в `profiles/**` или `scripts/**` GitHub Actions собирает ISO и
публикует его артефактом (хранение 7 дней). На тегах `v*` файл дополнительно
прикладывается к GitHub Release.

## Параметры ядра live-среды

Поверх стандартных параметров archiso добавлены:

- `quiet loglevel=3 logo.nologo` — тихая загрузка без логотипа ядра;
- `amdgpu.cik_support=0 radeon.cik_support=1` — старые GPU AMD GCN
  (Sea Islands) обслуживаются драйвером `radeon`.

## Дорожная карта

- [x] Базовый профиль archiso с брендингом Clean Linux
- [x] Скрипты сборки и CI
- [ ] Собственный репозиторий пакетов (`packages/`)
- [ ] Текстовый установщик
- [ ] Конфигурации по умолчанию (`config/`)

[Arch Linux]: https://archlinux.org
[archiso]: https://gitlab.archlinux.org/archlinux/archiso
