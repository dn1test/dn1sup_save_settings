# Changelog (Лог изменений)

Лог изменений **DN1Sup Save Settings** (`dn1sup_save_settings`).
Формат версий соответствует правилам `MAJOR.MINOR.PATCH`.

## [0.13.0] — 2026-10-15

- Удалён функционал dev/prod (второй id `dn1sup_save_settings_dev`): удалены
  `DEV_BUILD`, поле `dev_build` в состоянии диалога и бейдж DEV в шапке.
  Разработка — рабочая копия под тем же id («Обновить из рабочей копии» /
  reload); self-update рабочей копии отключён по пути загрузки
  (`Dn1sup::Updater.dev_source?`); файлы `.sketchup_dev.json` удалены.
- Добавлена кнопка проверки обновлений в шапке диалога: сначала проверяется
  локальная папка, затем GitHub.
- Убраны dev-кнопки обновления из рабочей копии и hot reload (чистка
  диалога, main и UI).
- Единый апдейтер v3 (`shared/dn1sup_updater.rb`), поле `author` в
  `registry.json`; удалён `tools/inspect_rbz.rb`.
- CI: тело релиза собирается из CHANGELOG.md (`tools/release_body.rb`).

## [0.12.3] — 2026-10-10

- feat: dev/prod placement rules — manifest in code folder, updater skips dev installs; v0.12.3
- docs: PUBLISHING.md - GitHub repo requirements for Extension Store; link in README
