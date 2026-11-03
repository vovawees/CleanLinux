# Roadmap

Проект в стадии pre-alpha. Порядок примерный — rolling, как и сам дистрибутив.

## Сделано

- [x] `burn`: рецепты, features, профили, сборка в кеш, установка в любой корень, база пакетов, конфликты, `backup`
- [x] rolling release+++: `plan`, сборка до установки, хуки (btrfs-снимок), preserved libs, ABI-пересборка, `hold`, `rollback`, `history`, `doctor`
- [x] профили: `native`, `generic-x86_64`, `generic-aarch64`, Steam Deck, ROG Ally, Mangmi Air X, Raspberry Pi 5, RK3566, ASUS X540YA
- [x] рецепты базовой системы: GCC 16, glibc 2.44, binutils 2.47, Linux 7.3, bash, coreutils, util-linux, dinit, …
- [x] cross-first bootstrap для x86_64 и aarch64: тулчейн → 21 пакет `base` → архив rootfs (проверено: x86_64 в chroot, aarch64 под qemu-user)
- [x] тесты: smoke на настоящих рецептах, полный цикл rolling+++

## Дальше: загрузка

- [ ] ядро: проверенные конфиги для каждого профиля, initramfs (или без него, где можно), загрузчик (systemd-boot/UEFI на x86_64, U-Boot/ABL на arm64)
- [ ] образ диска: GPT + btrfs (подтома `@`, `@home`, `@snapshots`, сжатие zstd), установщик
- [ ] вход в систему: shadow, PAM, agetty, сервисы dinit по умолчанию
- [ ] устройства: eudev или mdev (без systemd), firmware для профилей
- [ ] сеть: iwd + dhcpcd

## Дальше: десктоп и игры

- [ ] LLVM/Clang, Mesa (radeonsi/RADV, freedreno/turnip, panfrost/panvk, v3d) по `VIDEO_CARDS`
- [ ] Wayland-композитор для консолей (gamescope) и для ПК (labwc/sway), seatd
- [ ] PipeWire + WirePlumber
- [ ] Steam: multilib (32-bit glibc/mesa для x86_64), Proton; на arm64 — FEX-Emu/Box64
- [ ] контроллеры, датчики, управление питанием для handheld-профилей

## Дальше: burn

- [ ] split-пакеты (например, `gcc-libs` отдельно от компилятора)
- [ ] сборка от непривилегированного пользователя, изоляция сборки (namespaces, без сети)
- [ ] каналы `edge` и `security`, подписи коммитов репозитория рецептов
- [ ] бинарный кеш *своих* сборок между своими устройствами (не публичный репозиторий бинарников)
- [ ] mold/lld, PGO для тяжёлых пакетов, опциональный Clang-тулчейн
- [ ] рецепт самого burn в CleanLinux-Recipes
