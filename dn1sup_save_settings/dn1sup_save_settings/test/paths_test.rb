# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/test/paths_test.rb — разрешение путей настроек
# через ENV-оверрайды (вне SketchUp).
# =============================================================================

require 'fileutils'
require 'tmpdir'

module Dn1supSaveSettings
  module Test
    test 'paths: корни Local/Roaming разрешаются по ENV-оверрайдам' do
      Dir.mktmpdir do |root|
        roaming = File.join(root, 'roaming')  # …\SketchUp
        local   = File.join(root, 'local')    # …\SketchUp
        FileUtils.mkdir_p([File.join(roaming, 'Materials'), local])
        File.write(File.join(roaming, 'Materials', 'a.skm'), 'x' * 100)
        File.write(File.join(local, 'PrivatePreferences.json'), '{}')

        ENV['DN1SUP_SAVE_SETTINGS_ROAMING_ROOT'] = roaming
        ENV['DN1SUP_SAVE_SETTINGS_LOCAL_ROOT'] = local
        Paths.reset_sizes!
        begin
          materials = Paths::TARGETS.find { |t| t[:key] == 'materials' }
          assert_equal File.join(roaming, 'Materials'), Paths.resolve(materials)
          assert_equal 100, Paths.size_of(materials)

          private_prefs = Paths::TARGETS.find { |t| t[:key] == 'private_prefs' }
          assert_equal File.join(local, 'PrivatePreferences.json'), Paths.resolve(private_prefs)
          assert File.exist?(Paths.resolve(private_prefs))

          plugins = Paths::TARGETS.find { |t| t[:key] == 'plugins' }
          assert !File.exist?(Paths.resolve(plugins)), 'Plugins не должен существовать в фикстуре'
        ensure
          ENV.delete('DN1SUP_SAVE_SETTINGS_ROAMING_ROOT')
          ENV.delete('DN1SUP_SAVE_SETTINGS_LOCAL_ROOT')
          Paths.reset_sizes!
        end
      end
    end

    test 'paths: states возвращает все 7 целей с существованием и размерами' do
      Dir.mktmpdir do |root|
        roaming = File.join(root, 'roaming')
        local   = File.join(root, 'local')
        FileUtils.mkdir_p([File.join(roaming, 'Styles'), local])
        File.write(File.join(roaming, 'Styles', 's.style'), 'y' * 10)
        File.write(File.join(local, 'PrivatePreferences.json'), '{}')

        ENV['DN1SUP_SAVE_SETTINGS_ROAMING_ROOT'] = roaming
        ENV['DN1SUP_SAVE_SETTINGS_LOCAL_ROOT'] = local
        Paths.reset_sizes!
        begin
          states = Paths.states
          assert_equal 7, states.size
          by_key = states.group_by { |s| s['key'] }
          assert by_key.key?('materials') && by_key.key?('styles') && by_key.key?('private_prefs')

          styles = states.find { |s| s['key'] == 'styles' }
          assert_equal true, styles['exists']
          assert_equal 10, styles['size']
          assert_equal 'dir', styles['kind']

          prefs = states.find { |s| s['key'] == 'private_prefs' }
          assert_equal 'file', prefs['kind']
          assert_equal true, prefs['exists']

          templates = states.find { |s| s['key'] == 'templates' }
          assert_equal false, templates['exists']
          assert_equal 0, templates['size']
        ensure
          ENV.delete('DN1SUP_SAVE_SETTINGS_ROAMING_ROOT')
          ENV.delete('DN1SUP_SAVE_SETTINGS_LOCAL_ROOT')
          Paths.reset_sizes!
        end
      end
    end
  end
end
