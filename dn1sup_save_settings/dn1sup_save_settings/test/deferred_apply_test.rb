# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/test/deferred_apply_test.rb — отложенное применение
# файлов настроек: подготовка pending-папки (staged, pending.json, скрипт),
# отмена, повторная подготовка, чтение result.txt (включая BOM от
# PowerShell). Скрипт запускается с spawn_process: false — реальное
# применение проверяется вручную в живом SketchUp.
# =============================================================================

require 'fileutils'
require 'tmpdir'

module Dn1supSaveSettings
  module Test
    ENV_KEYS = %w[DN1SUP_SAVE_SETTINGS_STORE_DIR
                  DN1SUP_SAVE_SETTINGS_ROAMING_ROOT
                  DN1SUP_SAVE_SETTINGS_LOCAL_ROOT].freeze

    # Переопределяет корни Local/Roaming и хранилище на временные папки.
    def self.with_env(root)
      roaming = File.join(root, 'roaming')
      local   = File.join(root, 'local')
      store   = File.join(root, 'store')
      FileUtils.mkdir_p([roaming, local, store])
      ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR'] = store
      ENV['DN1SUP_SAVE_SETTINGS_ROAMING_ROOT'] = roaming
      ENV['DN1SUP_SAVE_SETTINGS_LOCAL_ROOT'] = local
      Paths.reset_sizes!
      [roaming, local, store]
    end

    def self.clear_env!
      ENV_KEYS.each { |key| ENV.delete(key) }
      Paths.reset_sizes!
    end

    test 'deferred: arm! готовит pending-папку, cancel! удаляет' do
      skip('тест только для Windows') unless Gem.win_platform?

      Dir.mktmpdir do |root|
        roaming, local, _store = with_env(root)
        begin
          src = File.join(root, 'src')
          FileUtils.mkdir_p(src)
          priv = File.join(src, 'PrivatePreferences.json')
          shared = File.join(src, 'SharedPreferences.json')
          File.write(priv, '{"a":1}')
          File.write(shared, '{"b":2}')

          entries = [
            { target: Paths::TARGETS.find { |t| t[:key] == 'private_prefs' }, src: priv },
            { target: Paths::TARGETS.find { |t| t[:key] == 'shared_prefs' }, src: shared }
          ]
          dir = DeferredApply.arm!(entries, archive: 'test.zip', relaunch: false,
                                   auto_backup: true, spawn_process: false)

          assert_equal DeferredApply.pending_dir, dir
          assert DeferredApply.pending?
          assert File.file?(File.join(dir, 'staged', 'local', 'PrivatePreferences.json')),
                 'файл Local попал в staged'
          assert File.file?(File.join(dir, 'staged', 'roaming', 'SharedPreferences.json')),
                 'файл Roaming попал в staged'

          cfg = JSON.parse(File.read(File.join(dir, DeferredApply::PENDING_FILE)))
          assert_equal 2, cfg['targets'].size, 'в pending.json обе цели'
          assert_equal local, cfg['roots']['local'], 'корень Local из окружения'
          assert_equal roaming, cfg['roots']['roaming'], 'корень Roaming из окружения'
          assert_equal false, cfg['relaunch'], 'relaunch=false записан'
          assert_equal true, cfg['auto_backup']
          assert_equal Process.pid, cfg['su_pid']

          script = File.read(File.join(dir, DeferredApply::SCRIPT_NAME))
          assert_match(/Get-Process/, script, 'скрипт опросом ждёт закрытия SketchUp')
          assert_match(/86400/, script, 'скрипт ждёт не дольше суток')
          assert_match(/pre_restore_/, script, 'скрипт делает страховочную копию')
          assert_match(/result\.txt/, script, 'скрипт пишет результат')

          assert_nil DeferredApply.last_result, 'результата ещё нет'
          state = DeferredApply.state
          assert state, 'состояние отложенной задачи доступно'
          assert state['from_current_session'], 'задача из текущей сессии'

          assert DeferredApply.cancel!
          assert !File.directory?(dir), 'pending-папка удалена'
          assert !DeferredApply.pending?
        ensure
          clear_env!
        end
      end
    end

    test 'deferred: повторный arm! заменяет подготовленное восстановление' do
      skip('тест только для Windows') unless Gem.win_platform?

      Dir.mktmpdir do |root|
        _roaming, _local, _store = with_env(root)
        begin
          src = File.join(root, 'src')
          FileUtils.mkdir_p(src)
          priv = File.join(src, 'PrivatePreferences.json')
          File.write(priv, '{"v":1}')
          entry = { target: Paths::TARGETS.find { |t| t[:key] == 'private_prefs' }, src: priv }

          first = DeferredApply.arm!([entry], spawn_process: false)
          File.write(priv, '{"v":2}')
          second = DeferredApply.arm!([entry], spawn_process: false)

          assert_equal first, second, 'pending-папка одна'
          staged = File.join(second, 'staged', 'local', 'PrivatePreferences.json')
          assert_equal '{"v":2}', File.read(staged), 'взят последний вариант'
          assert DeferredApply.pending?
          DeferredApply.cancel!
        ensure
          clear_env!
        end
      end
    end

    test 'deferred: чтение result.txt (с BOM) и clear_result!' do
      skip('тест только для Windows') unless Gem.win_platform?

      Dir.mktmpdir do |root|
        _roaming, _local, _store = with_env(root)
        begin
          src = File.join(root, 'src')
          FileUtils.mkdir_p(src)
          priv = File.join(src, 'PrivatePreferences.json')
          File.write(priv, '{}')
          entry = { target: Paths::TARGETS.find { |t| t[:key] == 'private_prefs' }, src: priv }
          dir = DeferredApply.arm!([entry], spawn_process: false)

          assert_nil DeferredApply.last_result

          # PowerShell Set-Content -Encoding UTF8 пишет BOM
          File.write(File.join(dir, DeferredApply::RESULT_FILE),
                     "\uFEFFok\nfinished 2026-10-06 21:00:00\nok PrivatePreferences.json\n")
          result = DeferredApply.last_result
          assert_equal 'ok', result['status'], 'статус без BOM'
          assert_equal '2026-10-06 21:00:00', result['finished']
          assert_equal ['ok PrivatePreferences.json'], result['lines']

          DeferredApply.clear_result!
          assert_nil DeferredApply.last_result
          assert DeferredApply.pending?, 'pending.json не тронут'
          DeferredApply.cancel!
        ensure
          clear_env!
        end
      end
    end

    test 'deferred: arm_reset! готовит сброс файла настроек (delete_file)' do
      skip('тест только для Windows') unless Gem.win_platform?

      Dir.mktmpdir do |root|
        _roaming, _local, _store = with_env(root)
        begin
          target = Paths::TARGETS.find { |t| t[:key] == 'private_prefs' }
          dir = DeferredApply.arm_reset!(target, relaunch: true, spawn_process: false)

          assert DeferredApply.pending?
          assert !File.directory?(File.join(dir, 'staged', 'local')),
                 'для сброса staged не заполняется'

          cfg = JSON.parse(File.read(File.join(dir, DeferredApply::PENDING_FILE)))
          assert_equal 'reset', cfg['kind'], 'kind=reset в pending.json'
          assert_equal true, cfg['relaunch']
          assert_equal false, cfg['auto_backup'], 'страховка — принудительный zip-бэкап вызывающего'
          assert_equal 'delete_file', cfg['targets'].first['action'], 'файл настроек удаляется целиком'
          assert_equal 'local', cfg['targets'].first['scope']

          state = DeferredApply.state
          assert_equal 'reset', state['kind'], 'kind пробрасывается в состояние'

          script = File.read(File.join(dir, DeferredApply::SCRIPT_NAME))
          assert_match(/delete_file/, script, 'скрипт обрабатывает удаление файла')
          assert_match(/clear_dir/, script, 'скрипт обрабатывает очистку каталога')

          assert DeferredApply.cancel!
        ensure
          clear_env!
        end
      end
    end

    test 'deferred: arm_reset! каталога (clear_dir); arm! заменяет сброс' do
      skip('тест только для Windows') unless Gem.win_platform?

      Dir.mktmpdir do |root|
        _roaming, _local, _store = with_env(root)
        begin
          plugins = Paths::TARGETS.find { |t| t[:key] == 'plugins' }
          dir = DeferredApply.arm_reset!(plugins, relaunch: false, spawn_process: false)

          cfg = JSON.parse(File.read(File.join(dir, DeferredApply::PENDING_FILE)))
          assert_equal 'reset', cfg['kind']
          assert_equal 'clear_dir', cfg['targets'].first['action'], 'содержимое каталога очищается'
          assert_equal false, cfg['relaunch']
          assert_equal ['dn1sup_save_settings', 'dn1sup_save_settings.rb'],
                       cfg['targets'].first['keep'], 'собственные файлы расширения исключены из очистки'

          error = nil
          begin
            DeferredApply.arm_reset!(Paths::TARGETS.find { |t| t[:key] == 'materials' }.merge(kind: 'bad'),
                                     spawn_process: false)
          rescue Dn1supSaveSettings::Error => e
            error = e.message
          end
          assert error, 'неизвестный вид цели — ошибка'

          src = File.join(root, 'src')
          FileUtils.mkdir_p(src)
          priv = File.join(src, 'PrivatePreferences.json')
          File.write(priv, '{"v":1}')
          dir2 = DeferredApply.arm!([{ target: Paths::TARGETS.find { |t| t[:key] == 'private_prefs' }, src: priv }],
                                    spawn_process: false)
          assert_equal dir, dir2, 'pending-папка одна'

          cfg2 = JSON.parse(File.read(File.join(dir2, DeferredApply::PENDING_FILE)))
          assert_equal 'restore', cfg2['kind'], 'arm! пишет kind=restore'
          assert_equal 'copy', cfg2['targets'].first['action'], 'восстановление — copy'
          assert File.file?(File.join(dir2, 'staged', 'local', 'PrivatePreferences.json')),
                 'staged заполнен для copy'
          assert_equal 'restore', DeferredApply.state['kind']

          DeferredApply.cancel!
        ensure
          clear_env!
        end
      end
    end

    test 'deferred: сброс плагинов сохраняет файлы самого расширения (PS-скрипт)' do
      skip('тест только для Windows') unless Gem.win_platform?

      Dir.mktmpdir do |root|
        roaming, _local, _store = with_env(root)
        begin
          plugins_dir = File.join(roaming, 'Plugins')
          FileUtils.mkdir_p(File.join(plugins_dir, 'other_plugin'))
          File.write(File.join(plugins_dir, 'other.rb'), '# other')
          File.write(File.join(plugins_dir, 'dn1sup_save_settings.rb'), '# registrar')
          FileUtils.mkdir_p(File.join(plugins_dir, 'dn1sup_save_settings'))
          File.write(File.join(plugins_dir, 'dn1sup_save_settings', 'main.rb'), '# package')

          target = Paths::TARGETS.find { |t| t[:key] == 'plugins' }
          dir = DeferredApply.arm_reset!(target, relaunch: false, spawn_process: false)

          # PID уже завершившегося процесса: скрипт не ждёт SketchUp и сразу
          # применяет задачу — так же, как после реального закрытия.
          child = Process.spawn('cmd.exe', '/c', 'exit')
          Process.waitpid(child)

          ps = File.join(ENV['SystemRoot'] || ENV['WINDIR'] || 'C:\\Windows',
                         'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
          ran = system(ps, '-NoProfile', '-ExecutionPolicy', 'Bypass',
                       '-File', File.join(dir, DeferredApply::SCRIPT_NAME),
                       '-SuPid', child.to_s, '-PendingDir', dir,
                       out: File::NULL, err: File::NULL)
          assert ran, 'PS-скрипт запустился и отработал'

          result = DeferredApply.last_result
          assert result, 'результат написан в result.txt'
          assert_equal 'ok', result['status'], "статус ok: #{result['lines'].join('; ')}"
          assert result['lines'].include?('ok Plugins cleared, kept 2 items'),
                 "сохранённые файлы отмечены в результате: #{result['lines'].join('; ')}"

          assert !File.exist?(File.join(plugins_dir, 'other.rb')), 'чужой файл удалён'
          assert !File.directory?(File.join(plugins_dir, 'other_plugin')), 'чужая папка удалена'
          assert File.file?(File.join(plugins_dir, 'dn1sup_save_settings.rb')), 'регистратор сохранён'
          assert File.file?(File.join(plugins_dir, 'dn1sup_save_settings', 'main.rb')),
                 'папка пакета сохранена'

          DeferredApply.cancel!
        ensure
          clear_env!
        end
      end
    end

    test 'deferred: arm! без подходящих файлов падает' do
      skip('тест только для Windows') unless Gem.win_platform?

      Dir.mktmpdir do |root|
        _roaming, _local, _store = with_env(root)
        begin
          [
            [],
            [{ target: Paths::TARGETS.find { |t| t[:key] == 'private_prefs' }, src: 'C:/нет/такого.json' }],
            [{ target: Paths::TARGETS.find { |t| t[:key] == 'materials' }, src: __FILE__ }]
          ].each do |entries|
            error = nil
            begin
              DeferredApply.arm!(entries, spawn_process: false)
            rescue Dn1supSaveSettings::Error => e
              error = e.message
            end
            assert error, "ожидали ошибку для #{entries.size} записей"
          end
          assert !DeferredApply.pending?
        ensure
          clear_env!
        end
      end
    end
  end
end
