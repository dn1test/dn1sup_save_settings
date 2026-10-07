# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/test/settings_test.rb — настройки расширения:
# нормализация папки архивов, валидация (относительный путь, папка внутри
# архивируемых каталогов), set/reset и запись архивов в пользовательскую
# папку с сохранением доступа к старым архивам.
# =============================================================================

require 'fileutils'
require 'tmpdir'

module Dn1supSaveSettings
  module Test
    test 'settings: пусто → стандартная папка; set/reset' do
      Dir.mktmpdir do |store|
        ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR'] = store
        begin
          assert_equal '', Settings.archive_dir, 'на старте папка не задана'
          assert !Settings.custom?

          dir = File.join(store, 'my_archives')
          result = Settings.set_archive_dir!(dir)
          expected = File.expand_path(dir).tr('\\', '/').sub(%r{/+\z}, '')
          assert_equal expected, result, 'путь нормализован (прямые слэши)'
          assert_equal expected, Settings.archive_dir
          assert Settings.custom?
          assert File.directory?(dir), 'папка создана'
          assert File.file?(Settings.path), 'settings.json записан'

          # Активная папка архивов переключилась
          assert_equal expected, Store.backups_dir

          assert_equal '', Settings.reset_archive_dir!
          assert_equal '', Settings.archive_dir
          assert_equal File.join(Store.dir, 'backups'), Store.backups_dir
        ensure
          ENV.delete('DN1SUP_SAVE_SETTINGS_STORE_DIR')
        end
      end
    end

    test 'settings: валидация — относительный путь и диск без каталога' do
      Dir.mktmpdir do |store|
        ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR'] = store
        begin
          ['', '   ', 'relative/path', 'C:'].each do |bad|
            error = nil
            begin
              Settings.set_archive_dir!(bad)
            rescue Dn1supSaveSettings::Error => e
              error = e.message
            end
            assert error, "ожидали ошибку для #{bad.inspect}"
            assert_equal '', Settings.archive_dir, "настройка не изменилась для #{bad.inspect}"
          end
        ensure
          ENV.delete('DN1SUP_SAVE_SETTINGS_STORE_DIR')
        end
      end
    end

    test 'settings: папка внутри архивируемого каталога отклоняется' do
      Dir.mktmpdir do |root|
        roaming = File.join(root, 'roaming')
        FileUtils.mkdir_p(File.join(roaming, 'Materials'))
        ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR'] = File.join(root, 'store')
        ENV['DN1SUP_SAVE_SETTINGS_ROAMING_ROOT'] = roaming
        begin
          error = nil
          begin
            Settings.set_archive_dir!(File.join(roaming, 'Materials', 'zips'))
          rescue Dn1supSaveSettings::Error => e
            error = e.message
          end
          assert error && error.include?('внутри'),
                 "ожидали отказ «внутри архивируемых», получили: #{error.inspect}"

          # Папка РЯДОМ с архивируемым каталогом (как стандартное хранилище) — допустима.
          ok = Settings.set_archive_dir!(File.join(root, 'roaming_archives'))
          assert_equal File.expand_path(ok).tr('\\', '/'), Settings.archive_dir
        ensure
          ENV.delete('DN1SUP_SAVE_SETTINGS_STORE_DIR')
          ENV.delete('DN1SUP_SAVE_SETTINGS_ROAMING_ROOT')
        end
      end
    end

    test 'settings: restore_relaunch — галочка автозапуска сохраняется' do
      Dir.mktmpdir do |store|
        ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR'] = store
        begin
          assert Settings.restore_relaunch, 'по умолчанию включено'
          assert_equal false, Settings.set_restore_relaunch!(false)
          assert_equal false, Settings.restore_relaunch
          assert_equal true, Settings.set_restore_relaunch!(true)
          assert_equal true, Settings.restore_relaunch
        ensure
          ENV.delete('DN1SUP_SAVE_SETTINGS_STORE_DIR')
        end
      end
    end

    test 'settings: повреждённый settings.json → стандартные значения' do
      Dir.mktmpdir do |store|
        ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR'] = store
        begin
          FileUtils.mkdir_p(store)
          File.write(File.join(store, 'settings.json'), '{не-json')
          assert_equal '', Settings.archive_dir
          assert_equal File.join(Store.dir, 'backups'), Store.backups_dir
        ensure
          ENV.delete('DN1SUP_SAVE_SETTINGS_STORE_DIR')
        end
      end
    end

    test 'settings: архив пишется в пользовательскую папку, старые доступны' do
      skip('tar.exe недоступен') unless Archiver.available?

      Dir.mktmpdir do |root|
        roaming = File.join(root, 'roaming')
        local   = File.join(root, 'local')
        store   = File.join(root, 'store')
        custom  = File.join(root, 'custom_archives')
        FileUtils.mkdir_p([File.join(roaming, 'Materials'), local, store])
        File.write(File.join(roaming, 'Materials', 'm1.skm'), 'M1')
        File.write(File.join(local, 'PrivatePreferences.json'), '{"pref":1}')

        ENV['DN1SUP_SAVE_SETTINGS_ROAMING_ROOT'] = roaming
        ENV['DN1SUP_SAVE_SETTINGS_LOCAL_ROOT'] = local
        ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR'] = store
        Paths.reset_sizes!
        begin
          Settings.set_archive_dir!(custom)
          entry = Backup.create!(comment: 'в свою папку', keys: %w[materials private_prefs], kind: 'manual')

          custom_zip = File.join(custom, entry['file'])
          assert File.file?(custom_zip), 'архив не попал в пользовательскую папку'
          assert_equal File.join(Store.backups_dir, entry['file']), Store.resolve_archive(entry['file'])

          # Архив, созданный до смены папки, находится в стандартной
          old = File.join(Store.default_backups_dir, 'dn1sup_settings_2020-01-01_000000.zip')
          FileUtils.mkdir_p(Store.default_backups_dir)
          File.write(old, 'old')
          assert_equal old, Store.resolve_archive(File.basename(old))

          # После сброса активная папка — снова стандартная
          Settings.reset_archive_dir!
          assert_equal File.join(Store.default_backups_dir, entry['file']),
                       Store.resolve_archive(entry['file'])
        ensure
          ENV.delete('DN1SUP_SAVE_SETTINGS_ROAMING_ROOT')
          ENV.delete('DN1SUP_SAVE_SETTINGS_LOCAL_ROOT')
          ENV.delete('DN1SUP_SAVE_SETTINGS_STORE_DIR')
          Paths.reset_sizes!
        end
      end
    end
  end
end
