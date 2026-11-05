# Потоки персональных данных (152-ФЗ)

Инженерный документ, не юридическое заключение. Юридические пункты помечены «юрист».
Short English summary at the end.

## 1. Важное ограничение: локализация

Хост вне РФ **не выполняет** требование локализации (ст. 18 ч. 5 152-ФЗ): данные граждан РФ
записываются и хранятся за рубежом уже на входе в хост. Тестовый стенд (Fornex, Нидерланды) —
именно такой. Псевдонимизация перед отправкой в модель этого не меняет. Рой с реальными ПДн
граждан РФ ставится только на РФ-хост; на зарубежном хосте допустимы лишь тестовые данные.

## 2. Реестр каналов

Срок указан для настроек по умолчанию; «—» означает, что срок не задан.

| Канал | Что уходит и куда | Маскируется | Где хранится | Срок жизни |
|---|---|---|---|---|
| Текст чата Telegram | Серверы Telegram (зарубежный транспорт), плагин, сессия агента | Транспорт Telegram — нет (юрист) | Транскрипты CLI, `chats/`, `state/multichat` | CLI: `cleanupPeriodDays`; очереди чатов 30 дн. |
| Голосовые | Расшифровка в сервисе voice-transcriber, затем как текст | После расшифровки — да (как текст) | Файл во вложениях `inbox/`, текст в транскрипте | inbox 30 дн. |
| Фото, сканы, PDF | В модель через прокси | Зависит от режима прокси (политика `passthrough` = нет; маска — этап S2) | `inbox/`, транскрипт | inbox 30 дн. |
| Файлы через Read | В модель как блок `tool_result` | Текст — да; картинки/PDF — как фото | транскрипт | как у транскрипта |
| WebFetch | Запрос и ответ в модель | Да (`tool_result`) | транскрипт | как у транскрипта |
| Серверный поиск/fetch провайдера | Запрос маскируется; результат рождается у провайдера | Запрос — да | транскрипт | как у транскрипта |
| Межагентные задачи `claude -p` | listener запускает `claude -p` | Только если передан `ANTHROPIC_BASE_URL` прокси (иначе обход) | `/var/log/labops-plugin-webhook/<agent>/*.log` — полный вывод агента | 30 дн. (`retention-sweep.sh`) |
| Чаты multichat/per_person | Отдельная сессия на собеседника | Только если у сессии задан прокси | `chats/<id>`, `state/multichat`, транскрипты | очереди 30 дн.; сессии — по запросу субъекта |
| Телеметрия и отчёты об ошибках CLI | Мимо `ANTHROPIC_BASE_URL` | Отчёты об ошибках отключены `DISABLE_ERROR_REPORTING`; телеметрия остаётся: `DISABLE_TELEMETRY` и `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` ломают каналы CLI | — | — |
| second-brain | Заметки и вектора, общий recall между собеседниками | Нет | vault + Postgres | — (удаляет оператор) |
| Журналы плагина | `logs/*.log`, `permissions.jsonl`, `ask-user-question.jsonl` | Секреты — да, ПДн — нет | `<state>/logs` | 30 дн. (ротация) |
| Журналы агента | `<ws>/logs/verbose-*.jsonl`, hooks, task-poller | Нет | `<ws>/logs` | 30 дн. |
| `outbox/`, `tmp/` агента | Файлы к отправке и временные | Нет | `<ws>/outbox`, `<ws>/tmp` | 30 / 7 дн. |
| Таблицы замен псевдонимизатора | токен -> исходное значение | — (это ключ) | БД сервиса, по треду (сессии) | до конца сессии; удаление `DELETE /threads/{id}` |
| `raw/`, `core/hot` | Слои памяти агента | Нет | `<ws>` | не ограничен (`RETENTION_RAW_DAYS=0` — решает владелец) |

## 3. Сроки хранения и чистка

- Журналы, outbox, tmp, вложения, журналы listener: `agent-architecture/scripts/retention-sweep.sh`.
  Сроки (дни): `RETENTION_LOG_DAYS=30`, `RETENTION_OUTBOX_DAYS=30`, `RETENTION_TMP_DAYS=7`,
  `RETENTION_INBOX_DAYS=30`, `RETENTION_LISTENER_DAYS=30`, `RETENTION_RAW_DAYS=0` (выкл.).
  Проверка без изменений: `--dry-run`.
- Запуск раз в сутки: шаблоны `agent-architecture/systemd/pii-retention.{service,timer}.template`.
  Таймер сам не включается: подставить `__SCRIPTS__`, `__SWEEP_ARGS__` и включить вручную.
- Транскрипты CLI (`~/.claude/projects`): срок задаёт `cleanupPeriodDays` в `settings.json` агента.
- Бэкапы удаления содержат ПДн и живут 7 дней (`--backup-ttl-days`); чистит sweep.

## 4. Удаление по требованию субъекта (ст. 21)

Скрипт: `agent-architecture/scripts/pii-forget.sh` (обёртка над `pii_forget.py`).

```
# 1. Отчёт (dry-run по умолчанию, ничего не меняет, ПДн в вывод не попадают)
bash pii-forget.sh --user-id <tg_id> --workspace ~/.claude-lab/<agent>/.claude \
  --state-dir <TELEGRAM_STATE_DIR> --listener-log-dir /var/log/labops-plugin-webhook/<agent> \
  --pseudonymizer-url http://127.0.0.1:<порт> --pseudonymizer-token-file <файл>
# 2. Удаление с бэкапом (каталог 700, срок 7 дней)
bash pii-forget.sh <те же параметры> --apply --report forget-report.json
```

Что чистится: транскрипты (сессии целиком, если все теги `<channel>` принадлежат субъекту;
в смешанных сессиях вырезаются строки субъекта, `--drop-mixed` удаляет сессию целиком), каталоги
чатов и записи `sessions.json`, строки журналов, файлы запусков listener, таблицы замен
псевдонимизатора. Ограничения: ответы агента без id в смешанных сессиях остаются; second-brain
скрипт **не чистит** — только напоминает: оператор находит заметки по id через MCP recall и
удаляет их штатными средствами second-brain; `chats/policy.yaml` правится вручную. Отчёт
(`subject_ref` — хеш id, только счётчики) можно отдать субъекту. Срок ответа субъекту — по закону
(юрист).

## 5. Модель угроз (кратко)

- Утечка к провайдеру модели: ПДн в открытом виде в запросе. Меры: pii-proxy; пробелы — картинки,
  `claude -p` без прокси, multichat без прокси, ФИО, пропущенные NER, адреса.
- Утечка с хоста: один Unix-пользователь на все агенты, транскрипты и журналы с открытыми ПДн.
  Меры: права 600/700, сроки хранения, шифрование диска (хостинг).
- Раскрытие третьим лицам: общий recall second-brain между собеседниками.
- Зарубежный транспорт (Telegram) и зарубежный хост: не закрывается кодом.
- Телеметрия CLI: выключается переменными окружения.
- Бэкапы удаления сами становятся хранилищем ПДн: короткий срок, 700.

## 6. Регламент инцидента: ПДн ушли в модель открытыми

1. Зафиксировать: время, агент, сессия, тип данных, число субъектов. Журнал инцидента — без
   самих ПДн.
2. Остановить утечку: проверить, что трафик агента идёт через pii-proxy (`ANTHROPIC_BASE_URL`);
   при обходе — остановить агента (владелец решает, это красная зона).
3. Оценить масштаб: `pii-forget.sh --dry-run` по затронутым субъектам; session id затронутых
   запросов — из журнала прокси.
4. Локальная чистка: `pii-forget.sh --apply` для затронутых транскриптов; удалить треды замен.
5. Провайдер модели: запрос на удаление/неиспользование данных по его процедуре (юрист).
6. Уведомления: Роскомнадзор — 24 ч с момента выявления, итог расследования — 72 ч (ст. 21 ч. 3.1);
   субъекты — по решению юриста.
7. Корректирующая мера: добавить случай в корпус тестов прокси, исправить детектор или
   конфигурацию, зафиксировать в журнале.

## English summary

Hosts outside the Russian Federation do not satisfy the data-localisation requirement (Art. 18
part 5 of 152-FZ); only test data belongs on them. Section 2 lists every data channel, whether it
is masked, where it is stored and how long it lives. Retention: `scripts/retention-sweep.sh`
(default 30 days for logs, 30 for outbox/inbox/listener logs, 7 for tmp; timer templates in
`agent-architecture/systemd`, not enabled automatically). Erasure on request (Art. 21):
`scripts/pii-forget.sh`, dry-run by default, `--apply` makes a 700-mode backup that expires after
7 days; second-brain is reported only. Incident procedure: section 6.
