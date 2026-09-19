# docs/BUILD.md — Windows-first pipeline → unsigned IPA

## Цель
Downloadable unsigned `.ipa` для physical iPad **без платного Apple Developer
аккаунта**: Windows → git push → GitHub Actions (macOS runner) → xcodegen →
xcodebuild `CODE_SIGNING_ALLOWED=NO` → artifact `btr-remote-unsigned-ipa` →
sideload/re-sign на устройстве (SideStore/Sideloadly + free Apple ID).

## Почему НЕ существующий CI «как есть» (проверено чтением файлов)
`​.github/workflows/build.yml` (upstream, оставлен без изменений):
- триггеры только `push: tags: [v*.*.*]` / `workflow_dispatch` → push в `main`
  ничего не собирает;
- сборка = `fastlane ios/mac release` + `match` + `Apple Distribution` +
  `export_method: app-store` → подпись **чужим платным Apple-аккаунтом** автора
  upstream; требует секреты `MATCH_PASSWORD`/`MATCH_GIT_URL`, которых у нас нет.

## Добавленный workflow (additive, zero-diff к файлам upstream)
`​.github/workflows/unsigned.yml` (новый файл):
- triggers: `push: branches: [main]` + `workflow_dispatch`;
- `runs-on: macos-latest`; bootstrap: `sudo xcode-select -s
  /Applications/Xcode_26.3.app` + `ci_scripts/ci_post_clone.sh` (сам ставит
  xcodegen через brew; скачивает отсутствующие `company_ids.json`/
  `service_uuids.json` с Nordic; `xcodegen generate`). env
  `CI_PRIMARY_REPOSITORY_PATH: ${{ github.workspace }}` — обязателен, т.к.
  ci_post_clone.sh делает `cd "$CI_PRIMARY_REPOSITORY_PATH"`;
- build: команды **из `build.sh`** (xcodebuild `-sdk iphoneos
  generic/platform=iOS` + `CODE_SIGNING_ALLOWED=NO`), без nix-only гейтов
  `swiftformat --lint`/`swiftlint --strict` (swiftlint на раннере отсутствует)
  и без fastlane/signing; `set -o pipefail` — падение xcodebuild не маскируется
  `xcbeautify`;
- package: cp Release-iphoneos/BTRemote.app → Payload/ → zip → `build/BTRemote.ipa`;
- upload: `actions/upload-artifact@v4`, name `btr-remote-unsigned-ipa`,
  `if-no-files-found: error`.
- `build/`, `.build/`, `*.ipa` уже в `.gitignore` (проверено) — в git ничего
  generated не попадёт.

## Путь до физической проверки (по шагам, для пользователя)
1. Создать **публичный** GitHub-репозиторий (macOS GitHub-hosted runners
   бесплатны только для public repos) + настроить push с этой Windows-машины
   (see Blockers).
2. `git push origin main` → на вкладке Actions прогонится «Build unsigned IPA».
3. Скачать artifact `btr-remote-unsigned-ipa` из прогона (retention ~90 дней).
4. Установить `.ipa` на physical iPad через SideStore/Sideloadly (free Apple
   ID — re-sign locally).
5. Пройти physical tests: `docs/PHYSICAL_TEST.md`.

## НЕ проверено (не заявлять как проверенное)
- «build passes» / «IPA created» — требует фактического CI-прогона; на Windows
  нет Xcode/swift, GitHub-репо ещё не создано, credentials не настроены.
- Локально проверено только: структура repo, `.gitignore`, синтаксис
  конфигурации по чтению (xcodegen/xcodebuild команды взяты из рабочего
  `build.sh` автора).

## Red flags / заметки
- Xcode pin `Xcode_26.3.app` — есть на текущем образе `macos-latest`
  (macOS 26 arm64, Xcode 26.0.1–26.6); если GitHub уберёт старые версии —
  убрать `xcode-select` строку (дефолтный 26.6 собирает Swift 6.0-код;
  `project.yml` swift_version 6.0 + strict concurrency: complete).
- `/usr/bin/zip` — стандартный в macOS.
- swiftlint/swiftformat в CI намеренно не запускаются (версии не верифицируемы
  без Mac; «real build errors исправляются» = сначала довести до сборки).
- Существующие `build.sh`/`build.yml`/`fastlane/` НЕ изменены.
