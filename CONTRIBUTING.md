# Как участвовать

**CleanLinux** — главный репозиторий проекта: документация, профили железа, bootstrap, образы и тесты. *English [below](#english).*

## С чего начать

- Что входит в базу, а что ставится сверху — [SCOPE.md](https://github.com/vovawees/CleanLinux/blob/main/docs/SCOPE.md); как всё устроено — [ARCHITECTURE.md](https://github.com/vovawees/CleanLinux/blob/main/docs/ARCHITECTURE.md).
- Что дальше — [ROADMAP.md](https://github.com/vovawees/CleanLinux/blob/main/docs/ROADMAP.md), issues с меткой `roadmap` и общая доска [CleanLinux roadmap](https://github.com/users/vovawees/projects/1).
- Крупную правку сначала обсудите в issue, чтобы не делать работу дважды.

## Проверки

Хостингового CI нет: проверки запускаются локально, одной командой (нужен shellcheck 0.11 или новее).

`tools/check.sh` — shellcheck, `tests/rolling.sh` (rolling release+++) и `tests/smoke.sh` (сборка настоящих рецептов); `tools/check.sh --kernel КОД_ЯДРА|linux-X.tar.xz` — ещё и `tests/kernel-config.sh` (каждый параметр фрагментов профилей доходит до `.config`, у узлов device tree плат есть драйверы); `tools/check.sh --full [x86_64|aarch64]` — ещё и весь bootstrap с нуля, затем параметры ядра, `tests/boot.py` и `tests/install.py` в QEMU (часы CPU).

Быстрые проверки можно запускать автоматически перед каждым `git push`:

```sh
git config core.hooksPath tools/hooks   # перед push: tools/check.sh --quick
```

## Правила

- Что относится к базе, а что к сборкам, решает [SCOPE.md](docs/SCOPE.md): база — то, без чего система не загрузится, не обновится или не использует железо.
- Профиль описывает только железо (`profiles/devices/<имя>.profile`): CPU, GPU, ядро, firmware, quirks — никаких программ «на вкус».
- Новый профиль или проверка на устройстве — строка в [HARDWARE.md](docs/HARDWARE.md) и отчёт по форме «Отчёт об устройстве».
- Изменения фрагментов ядра и `x86.config`/`arm64.config` рецепта `linux` проверяются `tools/check.sh --kernel …`.
- Изменения bootstrap проверяются `tools/check.sh --full` хотя бы для одной архитектуры.

## Коммиты и pull request'ы

- Одна логическая правка — один коммит. Сообщение — на английском, в стиле истории: `область: что изменилось`
  (`bootstrap: …`, `docs: …`), подробности — в теле письма.
- Ветка от `main`, pull request в `main`; `Closes #N` (или `Closes vovawees/CleanLinux#N`) закрывает issue при слиянии.
- Документация меняется в том же pull request'е, что и поведение.

## English

This repository is the hub of CleanLinux: docs, hardware profiles, bootstrap, images and tests. There is no hosted CI: run `tools/check.sh` (shellcheck 0.11+)
before every push (`git config core.hooksPath tools/hooks` runs the quick checks automatically). Scope rules are in docs/SCOPE.md; profiles describe hardware only; device reports go through the "Hardware report" form; bootstrap changes need `tools/check.sh --full` for at least one architecture.
Commit messages are in English (`area: what changed`); pull requests target `main`, and `Closes #N` closes the issue.
See the [roadmap](https://github.com/vovawees/CleanLinux/blob/main/docs/ROADMAP.md) and the [project board](https://github.com/users/vovawees/projects/1).
