# Рецепты

Рецепты живут в отдельном публичном репозитории [CleanLinux-Recipes](https://github.com/vovawees/CleanLinux-Recipes) — там же полная таблица переменных формата. Здесь — как burn их исполняет и как писать рецепты, которые хорошо ведут себя в rolling release+++.

## Где burn ищет рецепты

1. каталоги из `-R DIR` (можно несколько) и `RECIPE_PATHS` — локальные оверлеи, ищутся первыми;
2. git-клоны `RECIPE_REPOS` в `/var/lib/burn/repos/` (`burn sync`).

Свой пакет или изменённый рецепт кладётся в оверлей и перекрывает официальный без форка репозитория.

## Жизненный цикл рецепта в burn

| Фаза | По умолчанию | Переопределить |
|---|---|---|
| fetch | скачать `source=()`, сверить `sha256=()` | — |
| unpack | распаковать, применить `patches=()` с `-p${patch_strip:-1}` | — |
| prepare | ничего | `do_prepare` |
| configure | `bt_configure` типа сборки + `*_args` + `*_extra` | `do_configure` |
| build | `bt_build` | `do_build` |
| check | только с `--check`/`CHECK=1` | `do_check` |
| install | `bt_install` в `$DESTDIR` | `do_install` (+ `post_install`) |
| package | чистка, strip, soname-учёт, `.tar.zst` | `options=(…)` |

Функции выполняются в каталоге исходников (`$SRC`); внеисходниковая сборка — в `$BUILD`. Локальные файлы рецепта доступны через `$FILES`.

## Правила хорошего рецепта

- **Только upstream.** `https://` или зеркала `gnu://…`, `kernel://…`; никаких бинарных blob'ов и вендоренных архивов в репозитории.
- **sha256 обязателен.** `burn -R packages checksum --write <pkg>` впишет настоящие хеши из скачанных файлов.
- **Явные features.** Каждая опциональная зависимость — feature (`features=(+zlib)`, `depends=(zlib-ng:zlib)`, `meson_feature zlib`). Никакого автодетекта.
- **Не трогать флаги.** `-march`, `-O`, LTO и hardening приходят из профиля. Если пакет не переносит LTO или hardening — `options=(!lto)` / `options=(!hardening)` с комментарием почему.
- **Кросс-компиляция.** Рецепт должен собираться при `CHOST != CBUILD`: используйте `$CROSS`, `$CHOST`, `$KARCH`, задавайте cache-переменные autoconf для проверок, которые нельзя выполнить (`bash_cv_…`, `gl_cv_…`), а инструменты сборки берите с хоста.
- **Минимум на диске.** Документация, лишние локали, `.la` и статические библиотеки удаляются автоматически; `options=(staticlibs)` — только если статика действительно нужна.
- **Конфиги.** Файлы из `/etc`, которые пользователь правит, перечисляются в `backup=()` — обновление их не перезапишет.
- **`release`** увеличивается при любом изменении рецепта без смены версии — так `burn plan` покажет пересборку.

## Пример: cmake с выбором во время конфигурации

```bash
name=zlib-ng
version=2.3.3
release=1
summary="zlib replacement with SIMD optimisations (zlib-compatible API and ABI)"
homepage=https://github.com/zlib-ng/zlib-ng
license=(Zlib)
category=core
depends=(glibc)
build_type=cmake
source=(zlib-ng-$version.tar.gz::https://github.com/zlib-ng/zlib-ng/archive/refs/tags/$version.tar.gz)
sha256=(f9c65aa9c852eb8255b636fd9f07ce1c406f061ec19a2e7d508b318ca0c907d1)
cmake_args=(-DZLIB_COMPAT=ON -DWITH_GTEST=OFF -DINSTALL_UTILS=OFF -DWITH_RUNTIME_CPU_DETECTION=ON)
cmake_extra() { if ((CHECK)); then echo -DBUILD_TESTING=ON; else echo -DBUILD_TESTING=OFF; fi; }
```

## Проверка перед PR

```sh
printf 'ASSUME_INSTALLED=(glibc)\n' >/tmp/test.conf          # glibc берётся с хоста
b() { burn -R packages -r /tmp/root -c /tmp/test.conf --host-deps -y "$@"; }

b lint <pkg>              # формат и обязательные поля
b install <pkg>           # сборка и установка в тестовый корень
b files <pkg>             # что попало в пакет
tools/lint.sh --fetch <pkg>   # то же, что проверяет CI: ссылки и sha256
```

Так же работает `tests/smoke.sh` в основном репозитории.
