# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/dialog.rb — окно «Сохранение настроек» (UI::HtmlDialog).
# Стиль GUI — Vue 3 + Tailwind CSS (Vite singlefile bundle), тёмная/светлая
# тема. Разметка и логика: ui/index.html (собран из frontend/).
#
# Обмен Ruby ↔ JS: один экшен-колбэк 'call_ruby' (name + JSON-параметр) и
# пуш-функции window.pushState / window.pushResult.
# =============================================================================

require 'json'
require 'fileutils'

module Dn1supSaveSettings
  # Цели, для которых доступен сброс к заводскому состоянию (кнопки внизу
  # диалога): настройки интерфейса и расширения.
  RESETTABLE_KEYS = %w[private_prefs plugins].freeze

  # Перехват ошибок интерфейса (window error / unhandledrejection) → Ruby
  # (log_js_error). Инжектится со стороны Ruby при 'ready' — без пересборки
  # фронтенда; повторная инжекция безопасна (флаг в window).
  JS_ERROR_HOOK = <<~'JS'.freeze
    (function () {
      if (window.__dn1supErrorHook) { return; }
      window.__dn1supErrorHook = true;
      function report(payload) {
        try {
          var bridge = (typeof sketchup !== 'undefined' && sketchup) || window.sketchup;
          if (bridge && typeof bridge.call_ruby === 'function') {
            bridge.call_ruby('log_js_error', JSON.stringify(payload));
          }
        } catch (e) { /* журнал не должен ломать интерфейс */ }
      }
      window.addEventListener('error', function (event) {
        var err = event && event.error;
        report({
          message: err && err.message ? String(err.message) : String((event && event.message) || 'JS error'),
          source: String((event && event.filename) || ''),
          lineno: (event && event.lineno) || 0,
          stack: err && err.stack ? String(err.stack) : ''
        });
      });
      window.addEventListener('unhandledrejection', function (event) {
        var reason = event && event.reason;
        report({
          message: 'Unhandled rejection: ' + (reason && reason.message ? String(reason.message) : String(reason)),
          source: '',
          lineno: 0,
          stack: reason && reason.stack ? String(reason.stack) : ''
        });
      });
    })();
  JS

  module DialogWindow
    extend self

    begin
      require 'fiddle/import'

      module WinAPI
        extend Fiddle::Importer
        dlload 'user32.dll'
        extern 'void* FindWindowW(const void*, const void*)'
        extern 'int IsIconic(void*)'
        extern 'int ShowWindow(void*, int)'
        extern 'int SetForegroundWindow(void*)'
      end

      SUPPORTED = true
    rescue LoadError, StandardError
      SUPPORTED = false
    end

    SW_RESTORE = 9

    def raise_from_taskbar
      return unless SUPPORTED

      title = (Dn1supSaveSettings.window_title + "\0").encode('UTF-16LE')
      hwnd = WinAPI.FindWindowW(nil, title)
      return if hwnd.nil? || (hwnd.respond_to?(:null?) && hwnd.null?)
      return if WinAPI.IsIconic(hwnd).zero?

      WinAPI.ShowWindow(hwnd, SW_RESTORE)
      WinAPI.SetForegroundWindow(hwnd)
    rescue StandardError
      nil
    end
  end

  class << self
    def window_title
      "Save Settings v#{VERSION} — настройки SketchUp"
    end

    # help: true — окно откроется с показанной справкой (пункт меню «Справка»);
    # флаг одноразовый, передаётся в UI с первым push_state.
    def show_dialog(help = false)
      @pending_help = true if help
      dlg = @dialog
      if dlg && dlg.visible?
        dlg.bring_to_front
        DialogWindow.raise_from_taskbar
        return dlg
      end
      # Закрытый HtmlDialog повторным show не поднимается — пересоздаём.
      dialogs.delete(dlg) if dlg
      dlg = track_dialog(UI::HtmlDialog.new(
                           dialog_title: window_title,
                           preferences_key: 'dn1sup_save_settings_dialog',
                           width: 920, height: 660,
                           min_width: 720, min_height: 520,
                           resizable: true,
                           style: UI::HtmlDialog::STYLE_DIALOG
                         ))
      dlg.set_file(File.join(PLUG_ROOT, 'ui', 'index.html'))
      register_callbacks(dlg)
      dlg.show
      Log.info('Диалог открыт')
      @dialog = dlg
    end

    # -- колбэки -----------------------------------------------------------------

    def register_callbacks(dlg)
      dlg.add_action_callback('call_ruby') do |_ctx, name, param|
        dispatch(dlg, name.to_s, param.to_s)
      end
    end

    def dispatch(dlg, name, param)
      Log.info("Команда диалога: #{name}") unless %w[ready get_state].include?(name)
      case name
      when 'ready', 'get_state'
        # Хук ошибок JS инжектится на каждый запрос состояния: идемпотентен
        # (флаг в window), а первый get_state приходит сразу после загрузки
        # страницы — раньше безопасного момента нет.
        inject_error_hook(dlg)
        push_state(dlg)
      when 'log_js_error'
        log_js_error(param)
      when 'create_backup'
        create_backup(dlg, param)
      when 'restore_backup'
        restore_backup(dlg, param)
      when 'cancel_pending_restore'
        safe { DeferredApply.cancel! }
        push_state(dlg)
      when 'dismiss_restore_result'
        safe { DeferredApply.clear_result! }
        push_state(dlg)
      when 'delete_backup'
        delete_backup(dlg, param)
      when 'import_zip'
        import_zip(dlg)
      when 'read_archive_info'
        read_archive_info(dlg, param)
      when 'read_archive_log'
        read_archive_log(dlg, param)
      when 'open_backups_folder'
        safe { WinShell.open_folder(Store.backups_dir) }
      when 'reveal_backup'
        safe { WinShell.reveal(Store.resolve_archive(param.to_s)) }
      when 'open_store_file'
        safe { WinShell.reveal(HistoryStore.path) }
      when 'choose_archive_dir'
        choose_archive_dir(dlg)
      when 'reset_archive_dir'
        safe { Settings.reset_archive_dir! }
        push_state(dlg)
      when 'reset_target'
        reset_target(dlg, param)
      when 'update_from_dev'
        safe do
          if defined?(UI) && UI.respond_to?(:start_timer)
            UI.start_timer(0.05, false) do
              res = DevUpdater.update_and_reload!(reopen_dialog: true, notify: false)
              if !res['success'] && defined?(UI)
                UI.messagebox("Ошибка обновления из dev-папки:\n#{res['error']}")
              end
            end
          else
            DevUpdater.update_and_reload!(reopen_dialog: true, notify: false)
          end
        end
      end
    rescue StandardError => e
      Log.exception(e, "dialog:#{name}")
      push_result(dlg, 'error', 'message' => "#{e.class}: #{e.message}")
    end

    # -- действия ---------------------------------------------------------------

    # param: {comment: '…', keys: ['materials', …]} — keys пустой = все существующие.
    def create_backup(dlg, param)
      payload = parse_json(param)
      entry = safe { Backup.create!(comment: payload['comment'].to_s, keys: payload['keys'], kind: 'manual') }
      return unless entry

      push_result(dlg, 'backup_created', 'entry' => entry, 'backups_path' => Store.backups_dir)
      push_state(dlg)
    end

    # param: {file: 'dn1sup_settings_….zip', auto_backup: true,
    #         keys: [...]|null, relaunch: true|false} — подтверждение происходит
    # в интерфейсе. Файлы настроек (JSON) применяются отложенно — после
    # закрытия SketchUp (см. DeferredApply).
    def restore_backup(dlg, param)
      payload = parse_json(param)
      zip_path = Store.resolve_archive(payload['file'].to_s)
      relaunch = payload.key?('relaunch') ? payload['relaunch'] != false : Settings.restore_relaunch
      result = safe do
        Restorer.restore!(zip_path,
                          auto_backup: payload['auto_backup'] != false,
                          keys: payload['keys'],
                          relaunch: relaunch)
      end
      return unless result

      Settings.set_restore_relaunch!(relaunch) unless payload['relaunch'].nil?
      push_result(dlg, 'restore_done',
                  'restored' => result.restored,
                  'skipped' => result.skipped,
                  'errors' => result.errors,
                  'deferred' => result.deferred,
                  'pending_dir' => result.pending_dir,
                  'auto_backup_file' => result.auto_backup_file)
      push_state(dlg)
    end

    # param: {key: 'private_prefs'|'plugins', relaunch: true|false} — сброс
    # цели к заводскому состоянию (подтверждение — в интерфейсе). Перед сбросом
    # ПРИНУДИТЕЛЬНО создаётся резервная копия: без неё сброс не выполняется.
    # Применение отложенное — сразу после закрытия SketchUp
    # (см. DeferredApply.arm_reset!).
    def reset_target(dlg, param)
      payload = parse_json(param)
      key = payload['key'].to_s
      target = Paths::TARGETS.find { |t| t[:key] == key }
      unless target && RESETTABLE_KEYS.include?(key)
        push_result(dlg, 'error', 'message' => "Сброс «#{key}» не поддерживается")
        return
      end

      path = Paths.resolve(target)
      exists = target[:kind] == 'file' ? File.file?(path) : File.directory?(path)
      unless exists
        push_result(dlg, 'error', 'message' => "#{target[:label]}: нечего сбрасывать — путь не найден")
        return
      end

      begin
        entry = Backup.create!(comment: "Автоматически перед сбросом: #{target[:label]}",
                               keys: [key], kind: 'auto')
        DeferredApply.arm_reset!(target, relaunch: payload['relaunch'] != false)
      rescue Error => e
        Log.exception(e, "сброс цели:#{key}")
        push_result(dlg, 'error', 'message' => e.message)
        return
      end

      push_result(dlg, 'reset_armed', 'label' => target[:label], 'backup_file' => entry['file'])
      push_state(dlg)
    end

    def delete_backup(dlg, param)
      file = param.to_s
      zip_path = Store.resolve_archive(file)
      safe do
        # Разрешено удалять только файлы в папках архивов (без обхода путей).
        safe_file = File.expand_path(zip_path)
        allowed = Store.archive_search_dirs.map { |d| File.expand_path(d) }
        File.delete(safe_file) if allowed.include?(File.dirname(safe_file)) && File.file?(safe_file)
        HistoryStore.remove(file)
      end
      push_state(dlg)
    end

    # Выбор и импорт внешнего zip-архива настроек с диска.
    def import_zip(dlg)
      path = UI.openpanel('Выберите zip-архив настроек', Store.backups_dir, 'ZIP-архивы|*.zip|Все файлы|*.*||')
      return if path.nil? || path.to_s.empty?

      entry = safe { Backup.import!(path.to_s) }
      return unless entry

      push_result(dlg, 'imported', 'entry' => entry)
      push_state(dlg)
    end

    # Выбор папки архивов: куда сохранять новые копии и где прежде всего
    # искать существующие. Выбор и ошибки валидации — на стороне Ruby.
    def choose_archive_dir(dlg)
      dir = UI.select_directory(
        title: 'Папка для резервных копий настроек',
        directory: Store.backups_dir
      )
      return if dir.nil? || dir.to_s.empty?

      Settings.set_archive_dir!(dir.to_s)
      push_result(dlg, 'archive_dir_set', 'archive_dir' => Settings.archive_dir)
      push_state(dlg)
    end

    # param: file — состав архива для окна подтверждения восстановления.
    def read_archive_info(dlg, param)
      zip_path = Store.resolve_archive(param.to_s)
      manifest = safe { Archiver.read_manifest(zip_path) }
      if manifest
        push_result(dlg, 'archive_info',
                    'file' => param.to_s,
                    'manifest' => manifest,
                    'exists' => File.file?(zip_path))
      else
        push_result(dlg, 'error', 'message' => 'Не удалось прочитать манифест архива')
      end
    end

    # param: file — лог архивации из архива (читается по кнопке «Лог»).
    # log: nil — в архиве нет лога (архив старой версии расширения или чужой);
    # это не ошибка — окно открывается с пояснением.
    def read_archive_log(dlg, param)
      file = param.to_s
      zip_path = Store.resolve_archive(file)
      unless File.file?(zip_path)
        push_result(dlg, 'error', 'message' => "Архив не найден на диске: #{file}")
        return
      end

      push_result(dlg, 'archive_log',
                  'file' => file,
                  'exists' => true,
                  'log' => safe { Archiver.read_log(zip_path) })
    end

    # -- пуш в диалог ------------------------------------------------------------

    def push_state(dlg)
      payload = safe do
        h = {
          'version' => VERSION,
          'su_version' => Paths.su_version,
          'su_year' => Paths.su_year,
          'tar_ok' => Archiver.available?,
          'store_path' => Store.dir,
          'backups_path' => Store.backups_dir,
          'default_backups_path' => Store.default_backups_dir,
          'archive_dir' => Settings.archive_dir,
          'archive_dir_custom' => Settings.custom?,
          'history_path' => HistoryStore.path,
          'user' => Paths.username,
          'targets' => Paths.states,
          'history' => HistoryStore.list,
          'pending_restore' => DeferredApply.state,
          'restore_relaunch' => Settings.restore_relaunch
        }
        # Одноразовый флаг справки (пункт меню «Справка»): UI откроет окно
        # справки при получении состояния и сбросит флаг у себя.
        h['show_help'] = true if @pending_help
        h
      end
      @pending_help = nil
      dlg.execute_script("window.pushState(#{JSON.generate(payload)});")
    rescue StandardError => e
      Log.exception(e, 'push_state')
      puts "[SaveSettings] Не удалось передать состояние в диалог: #{e.message}"
    end

    def push_result(dlg, kind, payload)
      dlg.execute_script("window.pushResult('#{kind}', #{JSON.generate(payload || {})});")
    rescue StandardError => e
      Log.exception(e, "push_result:#{kind}")
      puts "[SaveSettings] Не удалось передать результат в диалог: #{e.message}"
    end

    # -- вспомогательное ----------------------------------------------------------

    # Ошибки интерфейса (Vue/JS) → журнал. param — JSON {message, source,
    # lineno, stack} от JS_ERROR_HOOK.
    def log_js_error(param)
      data = parse_json(param)
      message = "JS: #{data['message']}"
      source = [data['source'].to_s, data['lineno'].to_s].reject(&:empty?).join(':')
      message += " (#{source})" unless source.empty?
      stack = data['stack'].to_s
      message += "\n#{stack.lines.first(5).map(&:strip).join("\n")}" unless stack.empty?
      Log.error(message)
    end

    def inject_error_hook(dlg)
      dlg.execute_script(JS_ERROR_HOOK)
    rescue StandardError => e
      Log.warn("Не удалось установить перехватчик ошибок интерфейса: #{e.message}")
    end

    def parse_json(text)
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      {}
    end
  end
end
