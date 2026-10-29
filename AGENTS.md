# AGENTS.md — DN1Sup Save Settings

> **ОБЯЗАТЕЛЬНО ПРОЧИТАТЬ ПЕРЕД РАБОТОЙ — общие правила разработки:**
> мастер `U:\dn1code\sketchup_ext\AGENTS.md` — единственная полная копия
> (публикация: `U:\dn1code\sketchup_ext\PUBLISHING.md`).

- Расширение: `dn1sup_save_settings` / имя: «DN1Sup Save Settings».
- Критичное: один id без `_dev`-двойников; версию поднимать сразу в двух
  местах (`ext.version` регистратора, `registry.json`); релиз — только при
  зелёных тестах. Локальный чек-лист публикации — в `PUBLISHING.md` этого
  репозитория.

## Локальные правила репозитория

Sketchup API 2023 и выше
Интерфейс HTML VUE 3 + Tailwind

Настройки путей Sketchup для сохранения

C:\Users\User\AppData\Local\SketchUp\SketchUp 202x\SketchUp\PrivatePreferences.json
C:\Users\User\AppData\Roaming\SketchUp\SketchUp 202x\SketchUp\Components
C:\Users\User\AppData\Roaming\SketchUp\SketchUp 202x\SketchUp\Materials
C:\Users\User\AppData\Roaming\SketchUp\SketchUp 202x\SketchUp\Plugins
C:\Users\User\AppData\Roaming\SketchUp\SketchUp 202x\SketchUp\Styles
C:\Users\User\AppData\Roaming\SketchUp\SketchUp 202x\SketchUp\Templates
C:\Users\User\AppData\Roaming\SketchUp\SketchUp 202x\SketchUp\SharedPreferences.json
