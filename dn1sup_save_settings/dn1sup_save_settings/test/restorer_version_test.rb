# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/test/restorer_version_test.rb — интеграция запрета
# даунгрейда: Restorer.restore! сверяет sketchup_version манифеста с текущей
# (opts[:current_version] в тестах, Paths.su_version в проде).
# =============================================================================

require 'fileutils'
require 'tmpdir'

module Dn1supSaveSettings
  module Test
    def self.make_versioned_zip(store, roaming, local, sketchup_version, sketchup_year)
      targets = Paths::TARGETS.select do |t|
        File.exist?(Paths.resolve(t))
      end
      manifest = {
        'app' => 'dn1sup_save_settings',
        'manifest_version' => 1,
        'created_at' => Time.now.strftime('%Y-%m-%d %H:%M:%S'),
        'sketchup_version' => sketchup_version.to_s,
        'sketchup_year' => sketchup_year.to_s,
        'user' => 'test',
        'comment' => 'version-guard тест',
        'kind' => 'manual',
        'paths' => targets.map { |t| t[:key] },
        'targets' => targets.map do |t|
          { 'key' => t[:key], 'scope' => t[:scope], 'kind' => t[:kind],
            'name' => t[:name], 'label' => t[:label] }
        end
      }
      dest = File.join(store, 'backups', "dn1sup_settings_#{sketchup_version.to_s.gsub(/[^\d]/, '_')}_test.zip")
      entries = targets.map { |t| { scope: t[:scope], name: t[:name], src: Paths.resolve(t) } }
      Archiver.create(manifest, entries, dest)
      dest
    end

    test 'restorer: даунгрейд заблокирован (27 → 26)' do
      skip('tar.exe недоступен') unless Archiver.available?
      skip('тест только для Windows') unless Gem.win_platform?

      Dir.mktmpdir do |root|
        roaming = File.join(root, 'roaming')
        local = File.join(root, 'local')
        store = File.join(root, 'store')
        FileUtils.mkdir_p([File.join(roaming, 'Materials'), local])
        File.write(File.join(roaming, 'Materials', 'm1.skm'), 'M1')
        File.write(File.join(local, 'PrivatePreferences.json'), '{"v":1}')

        ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR'] = store
        ENV['DN1SUP_SAVE_SETTINGS_ROAMING_ROOT'] = roaming
        ENV['DN1SUP_SAVE_SETTINGS_LOCAL_ROOT'] = local
        Paths.reset_sizes!
        begin
          zip = Test.make_versioned_zip(store, roaming, local, '27.0.100', '2027')
          error = nil
          begin
            Restorer.restore!(zip, auto_backup: false, spawn: false, current_version: '26.2.243')
          rescue Dn1supSaveSettings::Error => e
            error = e.message
          end
          assert error && error.include?('запрещено'), "ожидали hard-блок даунгрейда, получили: #{error.inspect}"
        ensure
          %w[DN1SUP_SAVE_SETTINGS_STORE_DIR
             DN1SUP_SAVE_SETTINGS_ROAMING_ROOT
             DN1SUP_SAVE_SETTINGS_LOCAL_ROOT].each { |key| ENV.delete(key) }
          Paths.reset_sizes!
        end
      end
    end

    test 'restorer: апгрейд разрешён (25 → 27)' do
      skip('tar.exe недоступен') unless Archiver.available?
      skip('тест только для Windows') unless Gem.win_platform?

      Dir.mktmpdir do |root|
        roaming = File.join(root, 'roaming')
        local = File.join(root, 'local')
        store = File.join(root, 'store')
        FileUtils.mkdir_p([File.join(roaming, 'Materials'), local])
        File.write(File.join(roaming, 'Materials', 'm1.skm'), 'M1')
        File.write(File.join(local, 'PrivatePreferences.json'), '{"v":1}')

        ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR'] = store
        ENV['DN1SUP_SAVE_SETTINGS_ROAMING_ROOT'] = roaming
        ENV['DN1SUP_SAVE_SETTINGS_LOCAL_ROOT'] = local
        Paths.reset_sizes!
        begin
          zip = Test.make_versioned_zip(store, roaming, local, '25.0.659', '2025')
          result = Restorer.restore!(zip, auto_backup: false, spawn: false, current_version: '27.0.100')
          assert result.errors.empty?, "ошибок нет: #{result.errors.inspect}"
          assert !result.deferred.empty?, 'апгрейд должен применяться'
          DeferredApply.cancel!
        ensure
          %w[DN1SUP_SAVE_SETTINGS_STORE_DIR
             DN1SUP_SAVE_SETTINGS_ROAMING_ROOT
             DN1SUP_SAVE_SETTINGS_LOCAL_ROOT].each { |key| ENV.delete(key) }
          Paths.reset_sizes!
          begin
            DeferredApply.cancel!
          rescue StandardError
            nil
          end
        end
      end
    end

    test 'restorer: неизвестная версия блокируется, imported — разрешён' do
      skip('tar.exe недоступен') unless Archiver.available?
      skip('тест только для Windows') unless Gem.win_platform?

      Dir.mktmpdir do |root|
        roaming = File.join(root, 'roaming')
        local = File.join(root, 'local')
        store = File.join(root, 'store')
        FileUtils.mkdir_p([File.join(roaming, 'Materials'), local])
        File.write(File.join(roaming, 'Materials', 'm1.skm'), 'M1')
        File.write(File.join(local, 'PrivatePreferences.json'), '{"v":1}')

        ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR'] = store
        ENV['DN1SUP_SAVE_SETTINGS_ROAMING_ROOT'] = roaming
        ENV['DN1SUP_SAVE_SETTINGS_LOCAL_ROOT'] = local
        Paths.reset_sizes!
        begin
          zip = Test.make_versioned_zip(store, roaming, local, '', '')
          error = nil
          begin
            Restorer.restore!(zip, auto_backup: false, spawn: false, current_version: '27.0.100')
          rescue Dn1supSaveSettings::Error => e
            error = e.message
          end
          assert error && error.include?('определить нельзя'), "битый архив блокируется: #{error.inspect}"

          result = Restorer.restore!(zip, auto_backup: false, spawn: false,
                                          current_version: '27.0.100', allow_unknown_version: true)
          assert result.errors.empty?, "imported с неизвестной версией разрешён: #{result.errors.inspect}"
          DeferredApply.cancel!
        ensure
          %w[DN1SUP_SAVE_SETTINGS_STORE_DIR
             DN1SUP_SAVE_SETTINGS_ROAMING_ROOT
             DN1SUP_SAVE_SETTINGS_LOCAL_ROOT].each { |key| ENV.delete(key) }
          Paths.reset_sizes!
          begin
            DeferredApply.cancel!
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
