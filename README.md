# WordTrainer

Оффлайн iOS-приложение для запоминания английских слов. Сам создаёшь группы, добавляешь слова, приложение подтягивает все значения из встроенного словаря на английском, ты галочками отмечаешь нужные смыслы и добавляешь свои заметки (перевод, мнемонику — что угодно). Затем гоняешь тесты в трёх режимах и с рандомным сэмплом.

## Что уже работает

- Приложение целиком на английском — чтобы погружаться в язык пока им пользуешься.
- **Три вкладки**: My Groups (свои колоды), Ready Groups (19 тем × уровни A1–A2/B1–B2/C1–C2 — 45 листов, 2 250+ слов, каждое привязано к одному конкретному значению), Dict (просто словарь с поиском).
- **Двухэтапный поиск** — печатаешь по мере ввода (debounce ~250 мс, запросы вне main-потока), выбираешь слово из кандидатов (`came` → `come`; `up with` → `come up with`, `put up with`), потом видишь значения по частям речи и фразы, содержащие слово.
- **Ready Groups** — тематический лист конвертируется в свою группу через фильтр «сними то, что знаешь»; тематичные значения включаются автоматически (hint-ключи в `ready_groups.json`), нетематичные импортируются выключенными.
- **Значения (senses)** — у каждого слова любое число значений с отдельным чекбоксом «учить это значение» и полем свободной заметки.
- **Своё определение** — база кастомных определений живёт параллельно словарю (переживает его обновления): добавляй своё, правь словарное карандашом — оно станет custom-копией.
- **Три режима теста:**
  - `EN → translation (самопроверка)` — видишь слово, вспоминаешь смысл, потом жмёшь «знал / ошибся».
  - `Translation → EN` — видишь свой перевод/мнемонику, вводишь английское слово.
  - `Definition → EN` — видишь английское определение, вводишь слово.
- **Рандомный сэмпл** — слайдер «10 из 100» (или сколько нужно) прямо перед тестом.
- **Статистика по значениям** — после квиза выбираешь, сохранять ли прогон; счётчики живут на уровне значения (sense), история — снапшотами в `QuizSession`/`QuizResult` (UI ещё не сделан).
- **Всё офлайн** — данные в SwiftData, словарь в SQLite, сеть используется только один раз при первом запуске для скачивания полного словаря.

## Что лежит в проекте

- `WordTrainer.xcodeproj` — Xcode-проект (iOS 17+, SwiftUI + SwiftData).
- `WordTrainer/Resources/dictionary.sqlite` — **демо-словарь**: несколько слов + фразовых глаголов + таблица форм (came→come и т.п.) чтобы всё пощупать. Полноценный словарь собирается скриптом ниже.
- `WordTrainer/Resources/ready_groups.json` — 20 готовых тематических листов (леммы + pos-фильтры + hint-ключи тематичности).
- `DictBuilder/build_dict.py` — конвертер из Kaikki JSONL в SQLite (частотный фильтр + эвристики качества, флаги для LLM-ревью).
- `DictBuilder/dictfilters.py` — общие эвристики/помощники пайплайна.
- `DictBuilder/review_tools.py` — split/validate/apply для LLM-ревью определений.
- `DictBuilder/analyze_dict.py` — анализ собранного словаря (репорты по флагам).
- `DictBuilder/build_demo_dict.py` — генератор демо-словаря: `python3 build_demo_dict.py ../WordTrainer/Resources/dictionary.sqlite`.

## Как запустить (первый раз)

1. Открой на Mac папку `WordTrainer` в Finder.
2. Двойной клик по `WordTrainer.xcodeproj` — откроется Xcode.
3. Слева вверху выбери устройство: сначала попробуй `iPhone 15` в симуляторе (быстро, ничего подписывать не надо).
4. `Cmd+R` — приложение соберётся и запустится.

Если хочешь сразу на свой iPhone:

1. Подключи iPhone кабелем, разблокируй, разреши «Доверять этому компьютеру».
2. В Xcode: выбор target `WordTrainer` → таб **Signing & Capabilities** → поставь свой Apple ID в **Team** (если ID ещё нет — «Add an Account…» с обычным Apple ID, платить не надо).
3. Bundle Identifier уже задан: `com.deniskremko.wordtrainer`. Для своего форка смени на свой.
4. Выбери сверху свой iPhone как target, `Cmd+R`.
5. На iPhone: `Настройки → Основные → VPN и управление устройством` → доверься своему разработчику один раз.
6. С бесплатным Apple ID сборка живёт **7 дней** — потом пересобрать. С [Apple Developer Program](https://developer.apple.com/programs/) (99 USD/год) — год без пересборок, плюс возможность выложить в App Store.

## Полный словарь через GitHub Release

Приложение при первом запуске показывает splash с прогресс-баром и качает `dictionary.sqlite` из GitHub Release. Bundled демо-БД остаётся как fallback, чтобы Xcode всегда собирался и превьюшки работали.

URL и контрольная сумма зашиты в `WordTrainer/Info.plist` (ключи `DictionaryDownloadURL` и `DictionarySHA256`). Именно файл, а не build setting: механизм `INFOPLIST_KEY_*` работает только для известных системных ключей — кастомные Xcode молча выбрасывает. Сейчас там:

```
https://github.com/denis-kremko/wordtrainer/releases/download/dict-v3/dictionary-v3.sqlite.gz
```

### Как выложить релиз (один раз)

1. Собери полный словарь у себя:
   ```bash
   curl -LO https://kaikki.org/dictionary/English/kaikki.org-dictionary-English.jsonl.gz
   gunzip kaikki.org-dictionary-English.jsonl.gz
   curl -LO https://norvig.com/ngrams/count_1w.txt
   curl -LO https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_full.txt
   cd DictBuilder
   python3 build_dict.py ../kaikki.org-dictionary-English.jsonl /tmp/dictionary.sqlite \
     --norvig ../count_1w.txt --subs ../en_full.txt --review-queue /tmp/review_queue.jsonl
   gzip -9 /tmp/dictionary.sqlite   # приложение ждёт .gz — разжимает при первом запуске
   ```
   Фильтры: частотник (Norvig top-100k ∪ OpenSubtitles top-250k по каждому content-слову леммы), 3 смысла на (word, POS), 8–200 символов на определение, без obsolete/archaic/dated/rare (vulgar/derogatory-лексика включена намеренно — сериальный английский; offensive/slur исключены), без инфлекционных кросс-рефов и словообразовательных заглушек. Подозрительные определения (самоссылки, циркулярные, сложные) не выбрасываются, а пишутся в `review_queue.jsonl` — их прогоняет LLM-ревью (`review_tools.py split/validate/apply`). dict-v3: 280.5k senses, 181k лемм, ~27 МБ в gzip; ~85k определений переписаны LLM на простой язык, значения ранжированы по употребимости (колонка rank, near-дубли удалены), 99.9% значений с примером употребления.

2. Залей файл релизом. Через `gh`:
   ```bash
   gh release create dict-v3 /tmp/dictionary-v3.sqlite.gz \
     --repo denis-kremko/wordtrainer \
     --title "Dictionary v2" \
     --notes "Curated English dictionary (~26 MB gzipped)."
   ```

3. Проверь URL:
   ```bash
   curl -IL https://github.com/denis-kremko/wordtrainer/releases/download/dict-v3/dictionary-v3.sqlite.gz
   # HTTP/2 200
   ```

4. Обнови контрольную сумму в `WordTrainer/Info.plist` (ключ `DictionarySHA256`) — считается по **распакованному** файлу:
   ```bash
   shasum -a 256 /tmp/dictionary.sqlite
   ```
   При несовпадении приложение отклонит скачанный файл (защита от кривых прокси/DNS).

### Как обновить словарь

1. Пересобери `dictionary.sqlite`.
2. `gh release create dict-v3 ...` (новый тег).
3. Обнови `DictionaryDownloadURL` и `DictionarySHA256` в `WordTrainer/Info.plist`.
4. Первое приложение при следующем запуске увидит, что локальный файл уже есть, и **не** перекачает. Для форс-обновления сейчас нужно снести приложение или добавить кнопку «Redownload dictionary» в настройки (по запросу сделаю).

### Где лежит скачанный файл

`Application Support/dictionary.sqlite` внутри песочницы приложения, помечен `isExcludedFromBackup=true` (не гоняем в iCloud без нужды). `DictionaryService` сначала ищет там, потом падает на bundled демо.

## Архитектура коротко

- `Models/Models.swift` — SwiftData-модели: `WordGroup` → `Word` → `WordSense`, `CustomSense` (переиспользуемые свои определения по леммам), `QuizSession`/`QuizResult` (история квизов снапшотами), `PartOfSpeech` (отображение POS-тегов).
- `Dictionary/DictionaryService.swift` — read-only доступ к `dictionary.sqlite` через SQLite3 (serial queue, async-обёртки).
- `Dictionary/DictionaryDownloader.swift` — скачивание gzip-словаря с GitHub Release, gunzip + SHA256 вне main-потока.
- `Quiz/QuizEngine.swift` — сборка вопросов из группы: фильтрация по включённым значениям, шаффл, сэмплирование, проверка ответа.
- `Views/*` — SwiftUI-экраны:
  - `GroupsListView` — вкладки My Groups | Ready Groups | Dict
  - `GroupDetailView` — слова в группе + «Start quiz»
  - `WordLookupView` — один компонент на три режима: добавление в группу / просмотр слова / вкладка Dict
  - `ReadyGroupsView` — каталог готовых листов + конверсия в группу
  - `WordDetailView` — редактирование значений и заметок
  - `QuizConfigSheet`, `QuizRunnerView` — настройка, прохождение, сохранение статистики по выбору
  - `SharedViews` — общие компоненты (BottomCTA, TagBadge, DisclosureRow)

## Возможные апгрейды (легко доделать по запросу)

- Интервальные повторения (SM-2 / Anki-подобный график).
- Импорт/экспорт групп в CSV или JSON.
- Виджет на домашний экран «слово дня».
- iCloud-синк между устройствами (SwiftData умеет из коробки).
- Второй словарь EN→RU для автоматических переводов.
- Озвучка через `AVSpeechSynthesizer` (тоже офлайн).
