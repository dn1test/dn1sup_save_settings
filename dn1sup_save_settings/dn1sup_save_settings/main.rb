# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/main.rb — основная логика расширения «DN1Sup Save Settings».
#
# Код рассчитан на горячую перезагрузку (ext_reload MCP-сервера sketchup-dev):
#   • диалоги регистрируются через track_* и снимаются в unload! — старая
#     версия не оставляет следов;
#   • меню и тулбар создаются один раз на сессию SketchUp: UI::Menu в
#     современных версиях не имеет API удаления, поэтому пункты ссылаются
#     на Dn1supSaveSettings.* через константу и после перезагрузки вызывают
#     уже новый код.
# =============================================================================

begin
  require 'sketchup.rb'
rescue LoadError
  # загрузка в обычном Ruby — только для локального запуска тестов
end

# Журнал грузится первым: ошибки загрузки остальных модулей должны в него
# попадать. Ловим Exception (а не StandardError): SyntaxError и прочие
# ScriptError при загрузке файлов мимо rescue StandardError проходят.
# Ошибка логируется и пробрасывается дальше — SketchUp покажет её как обычно.
require File.join(File.dirname(__FILE__), 'log')
begin
  %w[store settings paths win_process archiver history_store backup deferred_apply restorer win_shell dialog].each do |name|
    require File.join(File.dirname(__FILE__), "#{name}.rb")
  end
rescue Exception => e # rubocop:disable Lint/RescueException
  Log.exception(e, 'загрузка модулей')
  raise
end
begin
  dev_file = File.join(File.dirname(__FILE__), 'dev_updater.rb')
  require dev_file if File.file?(dev_file)
rescue StandardError, LoadError => e
  Log.exception(e, 'загрузка dev_updater')
  nil
end

# Общий модуль автообновления dn1sup_updater.rb кладётся в пакет при упаковке
# (tools/pack.rb monorepo dn1sup_extensions); в dev-копии его нет.
# LoadError не наследуется от StandardError — ловим явно (SU2026+ пробрасывает).
if defined?(Sketchup) && Sketchup.respond_to?(:require)
  begin
    Sketchup.require 'dn1sup_save_settings/dn1sup_updater'
  rescue LoadError, StandardError
    nil
  end
end

module Dn1sup
  def self.common_menu
    @common_menu ||= begin
      legacy = (defined?($dn1sup_common_menu) && $dn1sup_common_menu) || (defined?($dn1sup_menu) && $dn1sup_menu)
      legacy || UI.menu('Extensions').add_submenu('DN1Sup')
    end
  end
end

module Dn1supSaveSettings
  VERSION   = '0.9.0'.freeze
  PLUG_ROOT = File.dirname(__FILE__).freeze

  COMMON_MENU = 'DN1Sup'.freeze          # общее меню всех расширений DN1Sup
  MENU_NAME   = 'Save Settings'.freeze   # подменю расширения внутри COMMON_MENU

  TOOLBAR_NAME = 'DN1Sup Save Settings'.freeze
  CMD_TOOLTIP  = 'DN1Sup Save Settings — резервные копии настроек SketchUp'.freeze

  REPO     = 'dn1test/sketchup-dn1sup-extensions'.freeze
  ID       = 'dn1sup_save_settings'.freeze
  ASSET    = "#{ID}.rbz".freeze
  PAGE_URL = "https://github.com/#{REPO}/releases".freeze
  MANIFEST = { id: ID, repo: REPO, version: VERSION, asset: ASSET }.freeze

  class Error < StandardError; end

  class << self
    # -- отслеживаемые ресурсы (снимаются в unload!) ---------------------------

    def dialogs; @dialogs ||= []; end # [UI::HtmlDialog, ...]

    def track_dialog(dialog)
      dialogs << dialog
      dialog
    end

    # -- выгрузка: вызвать ПЕРЕД remove_const (это делает ext_reload) ----------
    # Меню здесь не трогаем: UI::Menu не имеет API удаления, пункты живут
    # всю сессию и продолжают работать, ссылаясь на константу модуля.

    def unload!
      Log.info('unload! — выгрузка расширения')
      if (id = $dn1sup_ss_update_timer_id)
        UI.stop_timer(id) if defined?(UI) && UI.respond_to?(:stop_timer)
        $dn1sup_ss_update_timer_id = nil
      end
      dialogs.each do |dialog|
        begin
          dialog.close
        rescue StandardError
          nil
        end
      end
      true
    end

    # -- построение интерфейса --------------------------------------------------

    def setup!
      return if @setup_done
      return unless defined?(UI) && UI.respond_to?(:menu)

      @setup_done = true
      Log.session_start
      Log.info("Расширение загружено: v#{VERSION}")
      setup_ui
    end

    # Меню и панель инструментов создаются один раз на сессию SketchUp.
    # Своё подменю внутри общего меню DN1Sup.
    def setup_ui
      return if @menu_created || (defined?(Dn1sup) && Dn1sup.instance_variable_get(:@ss_menu))

      common = Dn1sup.common_menu
      menu = common.add_submenu(MENU_NAME)
      @menu_created = true
      Dn1sup.instance_variable_set(:@ss_menu, menu) if defined?(Dn1sup)

      cmd_open = UI::Command.new('Сохранение настроек...') do
        Dn1supSaveSettings.safe { Dn1supSaveSettings.show_dialog }
      end
      cmd_open.menu_text = 'Сохранение настроек...'
      cmd_open.tooltip = CMD_TOOLTIP
      cmd_open.status_bar_text = 'Резервные копии параметров SketchUp: сохранение в zip и восстановление'
      menu.add_item(cmd_open)

      menu.add_item('Создать резервную копию настроек') { Dn1supSaveSettings.safe { Dn1supSaveSettings.quick_backup } }
      menu.add_item('Открыть папку резервных копий') { Dn1supSaveSettings.safe { WinShell.open_folder(Store.backups_dir) } }
      menu.add_item('Открыть папку логов') { Dn1supSaveSettings.safe { Dn1supSaveSettings.open_log_folder } }
      menu.add_separator
      menu.add_item('Проверить обновления сейчас') do
        Dn1supSaveSettings.safe do
          if defined?(Dn1sup::Updater)
            Dn1sup::Updater.check!(Dn1supSaveSettings::MANIFEST.merge(force: true, async: true))
          else
            UI.openURL(Dn1supSaveSettings::PAGE_URL)
          end
        end
      end
      menu.add_item('Страница релизов на GitHub') { UI.openURL(Dn1supSaveSettings::PAGE_URL) }
      menu.add_separator
      menu.add_item('🔄 Обновить из dev-папки') { Dn1supSaveSettings.safe { Dn1supSaveSettings.update_from_dev } }
      menu.add_item('⚡ Перезагрузить (Hot Reload)') { Dn1supSaveSettings.safe { Dn1supSaveSettings.hot_reload } }
      menu.add_separator
      menu.add_item('Справка') { Dn1supSaveSettings.safe { Dn1supSaveSettings.show_dialog(true) } }
      menu.add_item('О расширении') { Dn1supSaveSettings.about }

      schedule_update_check
      setup_toolbar
    end

    # Фоновая проверка обновлений один раз за сессию (не раньше 15 секунд,
    # чтобы не мешать загрузке SketchUp). Таймер снимается в unload!.
    def schedule_update_check
      return if $dn1sup_ss_update_check_scheduled
      return unless defined?(Dn1sup::Updater) && defined?(UI) && UI.respond_to?(:start_timer)

      $dn1sup_ss_update_check_scheduled = true
      $dn1sup_ss_update_timer_id = UI.start_timer(15, false) do
        $dn1sup_ss_update_timer_id = nil
        begin
          Dn1sup::Updater.check!(Dn1supSaveSettings::MANIFEST.merge(async: true))
        rescue StandardError => e
          Log.exception(e, 'фоновая проверка обновлений')
          nil
        end
      end
    end

    # Панель инструментов с кнопкой запуска диалога. Тулбар нельзя удалить
    # через API, поэтому кнопка создаётся один раз: после горячей перезагрузки
    # UI::Toolbar.new возвращает существующую панель, а блок старой кнопки
    # ссылается на константу модуля — уже новый код.
    def setup_toolbar
      toolbar = UI::Toolbar.new(TOOLBAR_NAME)
      return if toolbar.any? { |c| c.tooltip == CMD_TOOLTIP }

      cmd = UI::Command.new('Сохранение настроек') do
        Dn1supSaveSettings.show_dialog if defined?(Dn1supSaveSettings)
      end
      cmd.menu_text = 'Сохранение настроек...'
      cmd.tooltip = CMD_TOOLTIP
      cmd.status_bar_text = 'Резервные копии параметров SketchUp: сохранение в zip и восстановление'
      svg = File.join(PLUG_ROOT, 'icons', 'ss.svg')
      if File.exist?(svg) && defined?(Sketchup) && Sketchup.respond_to?(:version) && Sketchup.version.to_i >= 16
        cmd.small_icon = svg
        cmd.large_icon = svg
      else
        cmd.small_icon = File.join(PLUG_ROOT, 'icons', 'ss_16.png')
        cmd.large_icon = File.join(PLUG_ROOT, 'icons', 'ss_24.png')
      end
      toolbar.add_item(cmd)
      toolbar.restore
    rescue StandardError => e
      Log.exception(e, 'панель инструментов')
      puts "[SaveSettings] Не удалось создать панель инструментов: #{e.message}"
    end

    # -- действия ---------------------------------------------------------------

    def update_from_dev(dev_dir = nil)
      return unless defined?(DevUpdater)
      was_open = @dialog && @dialog.visible?
      DevUpdater.update_and_reload!(dev_dir: dev_dir, reopen_dialog: was_open, notify: true)
    end

    def hot_reload
      return unless defined?(DevUpdater)
      DevUpdater.reload!
      UI.messagebox("⚡ Save Settings v#{VERSION} перезагружен!") if defined?(UI)
    end

    def about
      UI.messagebox(
        "Save Settings v#{VERSION}\n\n" \
        "Сохранение параметров SketchUp в zip-архив и восстановление из архива.\n" \
        "PrivatePreferences.json, SharedPreferences.json, Components, Materials,\n" \
        "Plugins, Styles, Templates.\n\n" \
        "Справка: кнопка «?» в окне или пункт меню «Справка».\n\n" \
        "Хранилище: #{Store.dir}\n" \
        "Журнал работы: #{Log.path}"
      )
    end

    # Журнал работы и ошибок: <хранилище>/dn1sup_save_settings.log (переживает
    # удаление расширения). open_folder принимает файл — откроет его папку.
    def open_log_folder
      return if WinShell.open_folder(Log.path)

      UI.messagebox("Журнал работы:\n#{Log.path}")
    end

    # Быстрое сохранение без открытия диалога: все существующие пути,
    # без комментария.
    def quick_backup
      entry = Backup.create!(comment: '', kind: 'quick')
      UI.messagebox("✅ Резервная копия создана:\n#{entry['file']}\n\nПапка: #{Store.backups_dir}")
    rescue Error => e
      Log.exception(e, 'быстрая резервная копия')
      UI.messagebox("Save Settings: #{e.message}")
    end

    # Ошибки команд не должны ронять SketchUp — логируем и показываем пользователю.
    def safe
      yield
    rescue StandardError => e
      Dn1supSaveSettings::Log.exception(e) if defined?(Dn1supSaveSettings::Log)
      UI.messagebox("Save Settings: #{e.class}: #{e.message}")
      puts "[SaveSettings] #{e.class}: #{e.message}"
      puts e.backtrace.first(5) if e.backtrace
    end
  end
end

Dn1supSaveSettings.setup!
