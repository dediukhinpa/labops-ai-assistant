# Перевод роя между харнесами (switch-harness)

Как перевести **весь рой** агентов с Claude Code на Codex CLI или обратно **одной командой**,
сохранив настройки, память и идентичность. Это та «отдельная процедура», на которую ссылается
`harness_set_swarm` (установщик менять харнес существующего роя отказывается — см.
[codex-harness.md](codex-harness.md)).

Харнес один на весь рой и хранится в `~/.claude-lab/shared/swarm.env` (`HARNESS=claude|codex`).

## Команда

```bash
bash orchestration/switch-harness.sh codex           # перевести рой на Codex (ChatGPT)
bash orchestration/switch-harness.sh claude          # перевести рой на Claude Code
bash orchestration/switch-harness.sh codex --dry-run # показать план, ничего не меняя
```

Запускать **от пользователя агентов** (у него лаборатория и `swarm.env`), не от root.

Переменные: `PRIMARY_MODEL=<модель>` (умолчание — дефолт целевого харнеса: `sonnet` для claude,
`gpt-6.2-sol` для codex), `SKIP_LOGIN=1` (подписка уже готова).

## Что делает (всё внутри одной команды, без ручных доп. настроек)

1. **Бэкап** `swarm.env`, общего входа `shared/codex` и воркспейсов всех агентов →
   `shared/backups/harness-switch-<из>-to-<в>-<время>/` (для отката).
2. **Доустановка рантайма** целевого харнеса, если его нет (при codex→claude бинаря Claude Code
   и его окружения может не быть, и наоборот) — переиспользует шаги зависимостей `install.sh`.
3. **Встроенный вход** в целевую подписку (не отдельной командой): codex — `codex login
   --device-auth` в `shared/codex`; claude — интерактивный `/login`. Пропускается, если уже
   залогинено. Код/подтверждение оператор вводит один раз здесь же (headless-токены для
   агентского трафика запрещены правилом репо).
4. Для **codex** — поднять pii-proxy (`pii-setup.sh host`): без него codex-агент стартовать
   откажется; адрес прокси детерминирован (`pii_proxy_port <agent>`).
5. **Пауза роя и остановка** процессов текущим стоппером (codex: `codex_stop_driver` +
   app-server; claude: `tmux kill-session` + добивание bun). Маркеры `agent_stop_mark`, чтобы
   watchdog не перезапускал во время свопа.
6. **Флип** `swarm.env` на целевой харнес (`harness_switch_swarm`).
7. **Конвертация каждого агента** (`lib/harness-convert.sh`) — после флипа рендерит файлы
   целевого харнеса поверх существующего воркспейса штатным `agent-template/install.sh`
   (`harness_render_agent`): `fill_template` — skip-if-exists, поэтому память/канал/`agent.env`/
   bearer и уже посеянную идентичность он сохраняет, создаются только недостающие файлы целевого
   харнеса. Перед этим **пред-посев идентичности** (`harness_preseed_identity`), чтобы «душа»
   сохранилась побайтно (а не перерендерилась из шаблона):
   - claude→codex: `codex_workspace.py identity` из существующего `CLAUDE.md` → `AGENTS.src.md`;
   - codex→claude: `codex_workspace.py identity --reverse --channel-span <N>` из `AGENTS.src.md`
     → `CLAUDE.md` (`N` = число `## `-секций в `templates/codex/channel-section.md`).
   Доки памяти (`core/AGENTS.md`, `USER.md`, `rules.md`, `TOOLS.md`) при переходе на claude
   правятся на месте (`harness_reverse_adapt_core` → `adapt --reverse`); в сторону codex их
   адаптирует сам установщик. Упоминания путей/подагентов, без потери содержимого.
8. **Перезапуск** юнитов и проверка готовности (webhook-порт, auth-state, health). При сбое —
   **автоматический откат** из бэкапа (воркспейсы + `swarm.env`).

## Что сохраняется, что меняется

| Сохраняется как есть (харнес-агностично) | Регенерируется под целевой харнес |
|---|---|
| `core/` (вся память: USER.md, decisions, preferences, episodic, pre-compact, archived) | идентичность: `CLAUDE.md` ⇄ `AGENTS.src.md` (+ собранный `AGENTS.md`) — тело «души» сохраняется, меняется раздел о канале |
| `tools/TOOLS.md`, `agent.env` (bearer, scopes, URL мозга) | модель/MCP: `settings.json`+`.mcp.json` ⇄ `.codex/config.toml` |
| `channel.env` (бот-токен, id операторов, порт) | глобальные правила: `~/.claude/{CLAUDE.md,rules/}` ⇄ `.codex/{AGENTS.md,rules/}` |
| секреты `shared/secrets/` | symlink `.agents/skills` (codex), `.codex/` home (700) + вход `shared/codex` |

## Неустранимые ограничения

- **Непрерывность диалога не переносится.** Треды Codex (`.codex/`) и сессия Claude в tmux —
  харнес-специфичны; после перехода агент стартует свежей сессией. Память в `core/` цела,
  агент «вспомнит» её через recall. Миграции истории диалога нет.
- **Код входа оператор вводит один раз** (внутри команды) — это учётные данные подписки.

## Статус реализации

Строится поэтапно (ветка `feature/switch-harness`):

- [x] `harness_switch_swarm` — флип `swarm.env` в обход guard'а (+юнит-тесты).
- [x] Скелет `switch-harness.sh` — аргументы, резолв ростера, бэкап, `--dry-run`, конвейер с
      «safe-stop» (недостроенная команда делает бэкап и не трогает рой) (+юнит-тесты).
- [x] Обратимость идентичности в `codex_workspace.py` (`identity/adapt --reverse`, span-aware
      подмена раздела канала) — round-trip claude→codex→claude побайтный (+юнит-тесты).
- [x] Конвертация воркспейса (`lib/harness-convert.sh`: пред-посев идентичности из «души» +
      `harness_render_agent` поверх штатного установщика skip-if-exists + обратная адаптация
      памяти на claude) — юнит + сквозной интеграционный тест claude→codex (память и ручные
      правки идентичности сохраняются).
- [ ] Доустановка рантайма целевого харнеса + встроенный вход + pii-proxy.
- [ ] Пауза/стоп/рестарт/откат.
- [ ] Скилл-враппер `switch-harness` и TG-команда `/harness` (отдельным шагом).
