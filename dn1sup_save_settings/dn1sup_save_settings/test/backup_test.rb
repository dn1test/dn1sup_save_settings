# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/test/backup_test.rb — интеграция: создание резервной
# копии → порча текущих настроек → восстановление (с автобэкапом и без),
# импорт чужого zip отклоняется.
# =============================================================================

require 'fileutils'
require 'tmpdir'

module Dn1supSaveSettings
  module Test
    test 'backup+restore: полный цикл с автобэкапом' do
      skip('tar.exe недоступен') unless Archiver.available?

      Dir.mktmpdir do |root|
        roaming = File.join(root, 'roaming')
        local   = File.join(root, 'local')
        store   = File.join(root, 'store')
        FileUtils.mkdir_p([File.join(roaming, 'Materials'), local, store])
        File.write(File.join(roaming, 'Materials', 'm1.skm'), 'M1')
        File.write(File.join(roaming, 'SharedPreferences.json'), '{"v":1}')
        File.write(File.join(local, 'PrivatePreferences.json'), '{"pref":1}')

        ENV['DN1SUP_SAVE_SETTINGS_ROAMING_ROOT'] = roaming
        ENV['DN1SUP_SAVE_SETTINGS_LOCAL_ROOT'] = local
        ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR'] = store
        Paths.reset_sizes!
        begin
          entry = Backup.create!(comment: 'тест', keys: %w[materials shared_prefs private_prefs], kind: 'manual')
          zip = File.join(store, 'backups', entry['file'])
          assert File.file?(zip), 'архив не создан'
          assert_equal 'manual', entry['kind']
          assert_equal 'тест', entry['comment']

          # Портим и удаляем текущее состояние
          File.delete(File.join(roaming, 'Materials', 'm1.skm'))
          File.write(File.join(local, 'PrivatePreferences.json'), '{"pref":"spoiled"}')

          result = Restorer.restore!(zip, auto_backup: true, spawn: false)
          assert_equal ['Materials'], result.restored,
                       'каталоги применяются сразу'
          assert_equal ['PrivatePreferences.json', 'SharedPreferences.json'].sort,
                       result.deferred.sort, 'файлы настроек уходят в отложенное применение'
          assert result.pending_dir && File.directory?(result.pending_dir), 'pending-папка создана'
          assert result.errors.empty?, "ошибки восстановления: #{result.errors.inspect}"
          assert_equal 'M1', File.read(File.join(roaming, 'Materials', 'm1.skm'))
          assert_equal '{"pref":"spoiled"}', File.read(File.join(local, 'PrivatePreferences.json')),
                       'JSON в запущенном SketchUp не перезаписан — применится после закрытия'
          assert_equal '{"pref":1}',
                       File.read(File.join(result.pending_dir, 'staged', 'local', 'PrivatePreferences.json')),
                       'в staged лежит файл из архива'
          DeferredApply.cancel!

          # Автобэкап записан в историю и указан в результате
          assert result.auto_backup_file, 'в результате нет файла автобэкапа'
          history = HistoryStore.list
          assert history.find { |e| e['kind'] == 'auto' }, 'в истории нет записи автобэкапа'
          assert history.find { |e| e['file'] == entry['file'] && e['kind'] == 'manual' }

          # Частичное восстановление без автобэкапа
          result2 = Restorer.restore!(zip, auto_backup: false, keys: %w[private_prefs], spawn: false)
          assert_equal [], result2.restored
          assert_equal ['PrivatePreferences.json'], result2.deferred
          assert result2.errors.empty?
          DeferredApply.cancel!
        ensure
          ENV.delete('DN1SUP_SAVE_SETTINGS_ROAMING_ROOT')
          ENV.delete('DN1SUP_SAVE_SETTINGS_LOCAL_ROOT')
          ENV.delete('DN1SUP_SAVE_SETTINGS_STORE_DIR')
          Paths.reset_sizes!
        end
      end
    end

    test 'backup: без существующих путей — ошибка' do
      skip('tar.exe недоступен') unless Archiver.available?

      Dir.mktmpdir do |root|
        ENV['DN1SUP_SAVE_SETTINGS_ROAMING_ROOT'] = File.join(root, 'empty_roaming')
        ENV['DN1SUP_SAVE_SETTINGS_LOCAL_ROOT'] = File.join(root, 'empty_local')
        ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR'] = File.join(root, 'store')
        begin
          error = nil
          begin
            Backup.create!
          rescue Dn1supSaveSettings::Error => e
            error = e.message
          end
          assert error && error.include?('ни одного'), "ожидали ошибку выбора путей, получили: #{error.inspect}"
        ensure
          ENV.delete('DN1SUP_SAVE_SETTINGS_ROAMING_ROOT')
          ENV.delete('DN1SUP_SAVE_SETTINGS_LOCAL_ROOT')
          ENV.delete('DN1SUP_SAVE_SETTINGS_STORE_DIR')
        end
      end
    end

    test 'backup: импорт чужого zip отклоняется' do
      Dir.mktmpdir do |root|
        ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR'] = root
        begin
          foreign = File.join(root, 'foreign.zip')
          File.write(foreign, 'это не архив настроек dn1sup')
          error = nil
          begin
            Backup.import!(foreign)
          rescue Dn1supSaveSettings::Error => e
            error = e.message
          end
          assert error && error.include?('манифест'), "ожидали ошибку манифеста, получили: #{error.inspect}"
        ensure
          ENV.delete('DN1SUP_SAVE_SETTINGS_STORE_DIR')
        end
      end
    end
  end
end
