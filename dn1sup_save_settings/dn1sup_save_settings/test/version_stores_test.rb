# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/test/version_stores_test.rb — блоки истории по версиям
# SketchUp: группировка, поиск архива в чужом хранилище, удаление чужой записи.
# =============================================================================

require 'fileutils'
require 'tmpdir'
require 'json'

module Dn1supSaveSettings
  module Test
    test 'version_stores: блоки по годам из history.json (динамические годы)' do
      Dir.mktmpdir do |appdata|
        Dir.mktmpdir do |localappdata|
          ENV['DN1SUP_SAVE_SETTINGS_APPDATA_ROOT'] = appdata
          ENV['DN1SUP_SAVE_SETTINGS_LOCALAPPDATA_ROOT'] = localappdata
          begin
            %w[2023 2024 2025 2026].each do |year|
              dir = File.join(appdata, 'SketchUp', "SketchUp #{year}", 'dn1sup_save_settings', 'backups')
              FileUtils.mkdir_p(dir)
            end
            h2023 = File.join(appdata, 'SketchUp', 'SketchUp 2023', 'dn1sup_save_settings', 'history.json')
            File.write(h2023, JSON.pretty_generate([
              { 'file' => 'dn1sup_settings_2023-01-01_100000.zip', 'created_at' => '2023-01-01 10:00:00',
                'kind' => 'manual', 'size' => 10, 'su_version' => '23.0.419', 'paths' => ['materials'], 'labels' => [] }
            ]))
            h2024 = File.join(appdata, 'SketchUp', 'SketchUp 2024', 'dn1sup_save_settings', 'history.json')
            File.write(h2024, JSON.pretty_generate([
              { 'file' => 'dn1sup_settings_2024-01-01_100000.zip', 'created_at' => '2024-01-01 10:00:00',
                'kind' => 'manual', 'size' => 10, 'su_version' => '24.0.484', 'paths' => ['materials'], 'labels' => [] }
            ]))
            h2026 = File.join(appdata, 'SketchUp', 'SketchUp 2026', 'dn1sup_save_settings', 'history.json')
            File.write(h2026, JSON.pretty_generate([
              { 'file' => 'b.zip', 'created_at' => '2026-10-06 11:00:00', 'kind' => 'manual' },
              { 'file' => 'a.zip', 'created_at' => '2026-10-06 10:00:00', 'kind' => 'auto' }
            ]))

            groups = VersionStores.list
            # 2027 не создавали — в динамическом списке его нет (раньше был хардкод).
            assert_equal %w[2023 2024 2025 2026], groups.map { |g| g['year'] }, 'только найденные годы'
            g23 = groups.find { |g| g['year'] == '2023' }
            assert_equal 1, g23['count']
            assert_equal '2023', g23['history'].first['store_year']
            assert_equal '23.0.419', g23['history'].first['su_version']
            g25 = groups.find { |g| g['year'] == '2025' }
            assert_equal 0, g25['count'], 'пустой год с хранилищем — пустой блок'
            assert g25['store_exists'], 'папка 2025 существует'
            g26 = groups.find { |g| g['year'] == '2026' }
            assert g26['current'], 'текущий год вне SketchUp — 2026'
            assert_equal %w[b.zip a.zip], g26['history'].map { |e| e['file'] }, 'новые первыми'
            assert g26['history'].all? { |e| e['store_year'] == '2026' }
          ensure
            ENV.delete('DN1SUP_SAVE_SETTINGS_APPDATA_ROOT')
            ENV.delete('DN1SUP_SAVE_SETTINGS_LOCALAPPDATA_ROOT')
          end
        end
      end
    end

    test 'version_stores: 2023 определяется из версии 23.x и пустые профили скрыты' do
      Dir.mktmpdir do |appdata|
        Dir.mktmpdir do |localappdata|
          ENV['DN1SUP_SAVE_SETTINGS_APPDATA_ROOT'] = appdata
          ENV['DN1SUP_SAVE_SETTINGS_LOCALAPPDATA_ROOT'] = localappdata
          begin
            assert_equal '2023', VersionStores.entry_year({ 'su_version' => '23.0.419', 'su_year' => '', 'created_at' => '', 'store_year' => '' })
            assert_equal '2023', VersionStores.entry_year({ 'su_version' => '', 'su_year' => '2023', 'created_at' => '', 'store_year' => '' })
            # Профиль 2023 с целью на месте виден и помечен has_targets.
            roaming = File.join(appdata, 'SketchUp', 'SketchUp 2023', 'SketchUp')
            FileUtils.mkdir_p(File.join(roaming, 'Materials'))
            groups = VersionStores.list
            g23 = groups.find { |g| g['year'] == '2023' }
            assert g23, '2023 в списке после появления папки профиля'
            assert g23['has_targets'], 'цель на месте'
            assert !g23['empty'], 'не пустой'
            # Год без папки, истории и целей — не появляется.
            assert_nil groups.find { |g| g['year'] == '2022' }, 'пустой 2022 скрыт'
          ensure
            ENV.delete('DN1SUP_SAVE_SETTINGS_APPDATA_ROOT')
            ENV.delete('DN1SUP_SAVE_SETTINGS_LOCALAPPDATA_ROOT')
          end
        end
      end
    end

    test 'version_stores: resolve_archive находит чужую копию' do
      Dir.mktmpdir do |appdata|
        Dir.mktmpdir do |localappdata|
          ENV['DN1SUP_SAVE_SETTINGS_APPDATA_ROOT'] = appdata
          ENV['DN1SUP_SAVE_SETTINGS_LOCALAPPDATA_ROOT'] = localappdata
          begin
            foreign = File.join(appdata, 'SketchUp', 'SketchUp 2023', 'dn1sup_save_settings', 'backups')
            FileUtils.mkdir_p(foreign)
            File.write(File.join(foreign, 'dn1sup_settings_2023_x.zip'), 'zip')
            found = VersionStores.resolve_archive('dn1sup_settings_2023_x.zip', '2023')
            assert_equal File.join(foreign, 'dn1sup_settings_2023_x.zip'), found
            found_any = VersionStores.resolve_archive('dn1sup_settings_2023_x.zip', nil)
            assert_equal File.join(foreign, 'dn1sup_settings_2023_x.zip'), found_any
          ensure
            ENV.delete('DN1SUP_SAVE_SETTINGS_APPDATA_ROOT')
            ENV.delete('DN1SUP_SAVE_SETTINGS_LOCALAPPDATA_ROOT')
          end
        end
      end
    end

    test 'version_stores: orphan-zip без history.json попадает в блок' do
      Dir.mktmpdir do |appdata|
        Dir.mktmpdir do |localappdata|
          ENV['DN1SUP_SAVE_SETTINGS_APPDATA_ROOT'] = appdata
          ENV['DN1SUP_SAVE_SETTINGS_LOCALAPPDATA_ROOT'] = localappdata
          begin
            dir = File.join(appdata, 'SketchUp', 'SketchUp 2025', 'dn1sup_save_settings', 'backups')
            FileUtils.mkdir_p(dir)
            File.write(File.join(dir, 'dn1sup_settings_2025-05-05_050505.zip'), 'not-a-zip')
            groups = VersionStores.list
            g25 = groups.find { |g| g['year'] == '2025' }
            assert_equal 1, g25['count']
            assert_equal '2025', g25['history'].first['store_year']
          ensure
            ENV.delete('DN1SUP_SAVE_SETTINGS_APPDATA_ROOT')
            ENV.delete('DN1SUP_SAVE_SETTINGS_LOCALAPPDATA_ROOT')
          end
        end
      end
    end

    test 'version_stores: targets_for_year — пути чужой версии' do
      Dir.mktmpdir do |appdata|
        Dir.mktmpdir do |localappdata|
          ENV['DN1SUP_SAVE_SETTINGS_APPDATA_ROOT'] = appdata
          ENV['DN1SUP_SAVE_SETTINGS_LOCALAPPDATA_ROOT'] = localappdata
          begin
            roaming = File.join(appdata, 'SketchUp', 'SketchUp 2024', 'SketchUp')
            local = File.join(localappdata, 'SketchUp', 'SketchUp 2024', 'SketchUp')
            FileUtils.mkdir_p(File.join(roaming, 'Materials'))
            File.write(File.join(roaming, 'Materials', 'm.skm'), '12345')
            File.write(File.join(roaming, 'SharedPreferences.json'), '{}')

            targets = VersionStores.targets_for_year('2024')
            assert_equal 7, targets.size, 'все 7 целей'
            by_key = targets.each_with_object({}) { |t, h| h[t['key']] = t }
            assert by_key['materials']['exists']
            assert_equal 5, by_key['materials']['size']
            assert by_key['materials']['path'].include?('SketchUp 2024'), 'путь чужой версии'
            assert by_key['shared_prefs']['exists']
            assert !by_key['plugins']['exists'], 'чего нет — exists=false'
            assert_equal 0, by_key['plugins']['size']
            assert_nil by_key['plugins']['modified']
          ensure
            ENV.delete('DN1SUP_SAVE_SETTINGS_APPDATA_ROOT')
            ENV.delete('DN1SUP_SAVE_SETTINGS_LOCALAPPDATA_ROOT')
          end
        end
      end
    end

    test 'version_stores: remove удаляет запись чужого года' do
      Dir.mktmpdir do |appdata|
        Dir.mktmpdir do |localappdata|
          ENV['DN1SUP_SAVE_SETTINGS_APPDATA_ROOT'] = appdata
          ENV['DN1SUP_SAVE_SETTINGS_LOCALAPPDATA_ROOT'] = localappdata
          begin
            store2024 = File.join(appdata, 'SketchUp', 'SketchUp 2024', 'dn1sup_save_settings')
            FileUtils.mkdir_p(store2024)
            File.write(File.join(store2024, 'history.json'), JSON.pretty_generate([
              { 'file' => 'x.zip', 'created_at' => '2024-03-03 03:03:03', 'kind' => 'manual' }
            ]))
            assert VersionStores.remove('x.zip', '2024')
            assert_equal [], VersionStores.list.find { |g| g['year'] == '2024' }['history']
            assert !VersionStores.remove('x.zip', '2024'), 'повторное удаление — false'
          ensure
            ENV.delete('DN1SUP_SAVE_SETTINGS_APPDATA_ROOT')
            ENV.delete('DN1SUP_SAVE_SETTINGS_LOCALAPPDATA_ROOT')
          end
        end
      end
    end
  end
end
