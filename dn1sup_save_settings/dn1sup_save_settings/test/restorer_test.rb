# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/test/restorer_test.rb — восстановление из архива:
# каталоги применяются сразу, файлы настроек (JSON) уходят в отложенное
# применение (DeferredApply), defer_files: false возвращает старое поведение
# (копировать сразу).
# =============================================================================

require 'fileutils'
require 'tmpdir'
require 'json'

module Dn1supSaveSettings
  module Test
    test 'restorer: папки сразу, JSON — отложенно (spawn: false)' do
      skip('tar.exe недоступен') unless Archiver.available?
      skip('тест только для Windows') unless Gem.win_platform?

      Dir.mktmpdir do |root|
        roaming = File.join(root, 'roaming')
        local   = File.join(root, 'local')
        store   = File.join(root, 'store')
        FileUtils.mkdir_p([File.join(roaming, 'Materials'), local, store])
        File.write(File.join(roaming, 'Materials', 'm1.skm'), 'OLD')
        File.write(File.join(local, 'PrivatePreferences.json'), '{"old":1}')
        File.write(File.join(roaming, 'SharedPreferences.json'), '{"old":2}')

        ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR'] = store
        ENV['DN1SUP_SAVE_SETTINGS_ROAMING_ROOT'] = roaming
        ENV['DN1SUP_SAVE_SETTINGS_LOCAL_ROOT'] = local
        Paths.reset_sizes!
        begin
          entry = Backup.create!(comment: 'тест', kind: 'manual')
          zip = File.join(Store.backups_dir, entry['file'])

          # Меняем текущее состояние — восстановление должно его перезаписать.
          File.write(File.join(roaming, 'Materials', 'm1.skm'), 'CHANGED')
          File.write(File.join(local, 'PrivatePreferences.json'), '{"changed":1}')

          result = Restorer.restore!(zip, auto_backup: false, spawn: false)

          assert_equal ['Materials'], result.restored, 'каталог применён сразу'
          assert_equal ['PrivatePreferences.json', 'SharedPreferences.json'].sort,
                       result.deferred.sort, 'JSON-файлы отложены'
          assert result.pending_dir && File.directory?(result.pending_dir), 'pending-папка создана'
          assert_equal '{"old":1}',
                       File.read(File.join(result.pending_dir, 'staged', 'local', 'PrivatePreferences.json')),
                       'в staged — файл из архива'
          assert_equal '{"changed":1}', File.read(File.join(local, 'PrivatePreferences.json')).strip,
                       'JSON в запущенном SketchUp НЕ перезаписан — применится после закрытия'
          assert_equal 'OLD', File.read(File.join(roaming, 'Materials', 'm1.skm')),
                       'каталог перезаписан содержимым архива'
          cfg = JSON.parse(File.read(File.join(result.pending_dir, 'pending.json')))
          assert_equal roaming, cfg['roots']['roaming']
          assert_equal true, cfg['relaunch'], 'relaunch по умолчанию включён'

          assert DeferredApply.cancel!, 'pending-папка убрана'
        ensure
          %w[DN1SUP_SAVE_SETTINGS_STORE_DIR
             DN1SUP_SAVE_SETTINGS_ROAMING_ROOT
             DN1SUP_SAVE_SETTINGS_LOCAL_ROOT].each { |key| ENV.delete(key) }
          Paths.reset_sizes!
        end
      end
    end

    test 'restorer: defer_files: false — старое поведение (копировать JSON сразу)' do
      skip('tar.exe недоступен') unless Archiver.available?
      skip('тест только для Windows') unless Gem.win_platform?

      Dir.mktmpdir do |root|
        roaming = File.join(root, 'roaming')
        local   = File.join(root, 'local')
        store   = File.join(root, 'store')
        FileUtils.mkdir_p([roaming, local, store])
        File.write(File.join(local, 'PrivatePreferences.json'), '{"old":1}')

        ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR'] = store
        ENV['DN1SUP_SAVE_SETTINGS_ROAMING_ROOT'] = roaming
        ENV['DN1SUP_SAVE_SETTINGS_LOCAL_ROOT'] = local
        Paths.reset_sizes!
        begin
          entry = Backup.create!(comment: 'тест', kind: 'manual')
          zip = File.join(Store.backups_dir, entry['file'])

          File.write(File.join(local, 'PrivatePreferences.json'), '{"changed":1}')
          result = Restorer.restore!(zip, auto_backup: false, defer_files: false)

          assert result.deferred.empty?, 'ничего не отложено'
          assert_nil result.pending_dir
          assert result.restored.include?('PrivatePreferences.json'), 'JSON применён сразу'
          assert_equal '{"old":1}', File.read(File.join(local, 'PrivatePreferences.json')).strip
        ensure
          %w[DN1SUP_SAVE_SETTINGS_STORE_DIR
             DN1SUP_SAVE_SETTINGS_ROAMING_ROOT
             DN1SUP_SAVE_SETTINGS_LOCAL_ROOT].each { |key| ENV.delete(key) }
          Paths.reset_sizes!
        end
      end
    end
  end
end
