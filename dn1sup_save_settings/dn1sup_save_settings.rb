# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings.rb — регистратор расширения «DN1Sup Save Settings»
# (единственный файл в корне Plugins). SketchUp автозагружает top-level .rb
# при старте; весь код лежит рядом в подпапке dn1sup_save_settings/.
#
# Регистратор идемпотентен: повторный load (горячая перезагрузка через
# ext_reload) не дублирует запись в Extension Manager — main.rb при этом
# загружается отдельным load (см. ext_reload MCP-сервера sketchup-dev).
#
# Author: DN1Sup <dn1codegen@gmail.com>
# License: MIT
# =============================================================================

require 'sketchup.rb'
require 'extensions.rb'

# Журнал грузится первым: ошибка регистрации должна попасть в лог, даже
# если остальной пакет не загрузится. Вне SketchUp (тесты) молча пропускаем.
begin
  require 'dn1sup_save_settings/log'
rescue StandardError, LoadError
  nil
end

# ExtensionManager не включает Enumerable — только each/[]/size.
_registered = false
Sketchup.extensions.each { |e| _registered = true if e.name == "DN1Sup Save Settings" }

unless _registered
  begin
    ext = SketchupExtension.new("DN1Sup Save Settings", File.join('dn1sup_save_settings', 'main'))
    ext.description = "Сохранение параметров SketchUp в zip-архив и восстановление из архива; сброс интерфейса и плагинов к заводским настройкам; история сохранений с датами"
    ext.version     = '0.7.0'
    ext.creator     = "DN1Sup"
    ext.copyright   = '2026 DN1Sup <dn1codegen@gmail.com> (MIT)'
    Sketchup.register_extension(ext, true) # true = загружать при старте SketchUp
  rescue Exception => e # rubocop:disable Lint/RescueException
    if defined?(Dn1supSaveSettings::Log)
      Dn1supSaveSettings::Log.exception(e, 'регистрация расширения')
    else
      puts "[SaveSettings] Ошибка регистрации: #{e.class}: #{e.message}"
    end
    raise
  end
end
