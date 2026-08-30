# WordTrainer

Оффлайн iOS-приложение для запоминания английских слов. Сам создаёшь группы, добавляешь слова, приложение подтягивает все значения из встроенного словаря на английском, ты галочками отмечаешь нужные смыслы и добавляешь свои заметки (перевод, мнемонику — что угодно). Затем гоняешь тесты в трёх режимах и с рандомным сэмплом.

## Что уже работает

- Приложение целиком на английском — чтобы погружаться в язык пока им пользуешься.
- **Группы слов** — создавай и удаляй; каждая группа — отдельная колода.
- **Добавление слова** — вводишь лемму, получаешь все значения из офлайн-словаря, отмечаешь нужные.
- **Умный поиск** — ввёл `came` → предложит `come`; ввёл `up with` → покажет `come up with`, `put up with` и т.д.
- **Фразовые глаголы и идиомы** — в словаре есть большая часть таких лемм целиком (`break a leg`, `come up with`).
- **Значения (senses)** — у каждого слова любое число значений с отдельным чекбоксом «учить это значение» и полем свободной заметки.
- **Своё определение** — можно добавить своё (помечается бейджем CUSTOM) к любому слову, даже если оно есть в словаре.
- **Слово не найдено** — кнопка «Add without looking up»: сразу перейти к ручной форме.
- **Три режима теста:**
  - `EN → translation (самопроверка)` — видишь слово, вспоминаешь смысл, потом жмёшь «знал / ошибся».
  - `Translation → EN` — видишь свой перевод/мнемонику, вводишь английское слово.
  - `Definition → EN` — видишь английское определение, вводишь слово.
- **Рандомный сэмпл** — слайдер «10 из 100» (или сколько нужно) прямо перед тестом.
- **Всё офлайн** — данные в SwiftData, словарь в SQLite, сеть используется только один раз при первом запуске для скачивания полного словаря.

## Что лежит в проекте

- `WordTrainer.xcodeproj` — Xcode-проект (iOS 17+, SwiftUI + SwiftData).
- `WordTrainer/Resources/dictionary.sqlite` — **демо-словарь**: несколько слов + фразовых глаголов + таблица форм (came→come и т.п.) чтобы всё пощупать. Полноценный словарь собирается скриптом ниже.
- `DictBuilder/build_dict.py` — конвертер из Kaikki JSONL в SQLite.

## Как запустить (первый раз)

1. Открой на Mac папку `WordTrainer` в Finder.
2. Двойной клик по `WordTrainer.xcodeproj` — откроется Xcode.
3. Слева вверху выбери устройство: сначала попробуй `iPhone 15` в симуляторе (быстро, ничего подписывать не надо).
4. `Cmd+R` — приложение соберётся и запустится.

Если хочешь сразу на свой iPhone:

1. Подключи iPhone кабелем, разблокируй, разреши «Доверять этому компьютеру».
2. В Xcode: выбор target `WordTrainer` → таб **Signing & Capabilities** → поставь свой Apple ID в **Team** (если ID ещё нет — «Add an Account…» с обычным Apple ID, платить не надо).
3. Смени **Bundle Identifier** с `com.example.WordTrainer` на что-то уникальное, например `com.denis.WordTrainer` — иначе получишь конфликт, если такой id уже занят.
4. Выбери сверху свой iPhone как target, `Cmd+R`.
5. На iPhone: `Настройки → Основные → VPN и управление устройством` → доверься своему разработчику один раз.
6. С бесплатным Apple ID сборка живёт **7 дней** — потом пересобрать. С [Apple Developer Program](https://developer.apple.com/programs/) (99 USD/год) — год без пересборок, плюс возможность выложить в App Store.

## Полный словарь через GitHub Release

Приложение при первом запуске показывает splash с прогресс-баром и качает `dictionary.sqlite` из GitHub Release. Bundled демо-БД остаётся как fallback, чтобы Xcode всегда собирался и превьюшки работали.

URL зашит в `Info.plist` через build setting `INFOPLIST_KEY_DictionaryDownloadURL` (см. `WordTrainer.xcodeproj/project.pbxproj`). Сейчас там:

```
https://github.com/denis-kremko/wordtrainer/releases/download/dict-v1/dictionary.sqlite.gz
```

### Как выложить релиз (один раз)

1. Собери полный словарь у себя:
   ```bash
   curl -LO https://kaikki.org/dictionary/English/kaikki.org-dictionary-English.jsonl
   cd DictBuilder
   python3 build_dict.py ../kaikki.org-dictionary-English.jsonl /tmp/dictionary.sqlite
   gzip -9 /tmp/dictionary.sqlite   # приложение ждёт .gz — разжимает при первом запуске
   ```
   С текущими фильтрами (3 смысла на (word, POS), 8–200 символов на определение, без obsolete/archaic/dated/rare/dialectal): ~124 МБ сырого, ~54 МБ в gzip, 815k senses, 653k лемм, 584k форм.

2. Залей файл релизом. Через `gh`:
   ```bash
   gh release create dict-v1 /tmp/dictionary.sqlite.gz \
     --repo denis-kremko/wordtrainer \
     --title "Dictionary v1" \
     --notes "Full English dictionary (~54 MB gzipped)."
   ```

3. Проверь URL:
   ```bash
   curl -IL https://github.com/denis-kremko/wordtrainer/releases/download/dict-v1/dictionary.sqlite.gz
   # HTTP/2 200
   ```

5. (Опционально) Дополни `Info.plist` контрольной суммой:
   ```bash
   shasum -a 256 /tmp/dictionary.sqlite
   ```
   В `project.pbxproj` добавь `INFOPLIST_KEY_DictionarySHA256 = "<hex>"` рядом с `INFOPLIST_KEY_DictionaryDownloadURL`. При несовпадении приложение отклонит скачанный файл (защита от кривых прокси/DNS).

### Как обновить словарь

1. Пересобери `dictionary.sqlite`.
2. `gh release create v2 ...` (новый тег).
3. Обнови URL в `INFOPLIST_KEY_DictionaryDownloadURL` на `.../v2/dictionary.sqlite`.
4. Первое приложение при следующем запуске увидит, что локальный файл уже есть, и **не** перекачает. Для форс-обновления сейчас нужно снести приложение или добавить кнопку «Redownload dictionary» в настройки (по запросу сделаю).

### Где лежит скачанный файл

`Application Support/dictionary.sqlite` внутри песочницы приложения, помечен `isExcludedFromBackup=true` (не гоняем в iCloud без нужды). `DictionaryService` сначала ищет там, потом падает на bundled демо.

## Архитектура коротко

- `Models/Models.swift` — SwiftData-модели `WordGroup`, `Word`, `WordSense`. Данные пользователя хранятся в SwiftData (SQLite под капотом, в песочнице приложения).
- `Dictionary/DictionaryService.swift` — read-only доступ к bundled `dictionary.sqlite` через SQLite3 напрямую.
- `Quiz/QuizEngine.swift` — сборка вопросов из группы: фильтрация по включённым значениям, шаффл, сэмплирование, проверка ответа.
- `Views/*` — SwiftUI-экраны:
  - `GroupsListView` — список групп
  - `GroupDetailView` — слова в группе + меню «Начать тест»
  - `AddWordSheet` — добавление слова с lookup'ом
  - `WordDetailView` — редактирование значений и заметок
  - `QuizConfigSheet` — выбор режима и размера сэмпла
  - `QuizRunnerView` — прохождение и итоги

## Возможные апгрейды (легко доделать по запросу)

- Интервальные повторения (SM-2 / Anki-подобный график).
- Импорт/экспорт групп в CSV или JSON.
- Виджет на домашний экран «слово дня».
- iCloud-синк между устройствами (SwiftData умеет из коробки).
- Второй словарь EN→RU для автоматических переводов.
- Озвучка через `AVSpeechSynthesizer` (тоже офлайн).
