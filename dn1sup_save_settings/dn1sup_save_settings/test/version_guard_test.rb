# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/test/version_guard_test.rb — запрет восстановления
# «сверху вниз»: сравнение полных версий, hard-блок даунгрейда, битые
# (неизвестная версия) блокируются, кроме kind 'imported'.
# =============================================================================

module Dn1supSaveSettings
  module Test
    test 'version_guard: compare полных версий' do
      assert_equal 0, VersionGuard.compare('27.0.100', '27.0.100')
      assert_equal 0, VersionGuard.compare('27', '27.0.0')
      assert_equal(-1, VersionGuard.compare('26.2.243', '27.0.100'))
      assert_equal(1, VersionGuard.compare('27.0.100', '26.9.999'))
      # Внутри одного года минор тоже считается: 26.2 новее 26.1.
      assert_equal 1, VersionGuard.compare('26.2.243', '26.1.340')
      assert_equal(-1, VersionGuard.compare('26.1.340', '26.2.243'))
      assert_nil VersionGuard.compare('', '27.0.100')
      assert_nil VersionGuard.compare('—', '27.0.100')
    end

    test 'version_guard: апгрейд и та же версия разрешены, даунгрейд заблокирован' do
      ok = VersionGuard.check_info({ 'sketchup_version' => '25.0.659' }, '27.0.100')
      assert !ok[:blocked], "апгрейд должен быть разрешён: #{ok.inspect}"
      same = VersionGuard.check_info({ 'sketchup_version' => '27.0.100' }, '27.0.100')
      assert !same[:blocked], "та же версия: #{same.inspect}"
      down = VersionGuard.check_info({ 'sketchup_version' => '27.0.100' }, '26.2.243')
      assert down[:blocked], 'даунгрейд должен быть заблокирован'
      assert down[:downgrade]
      assert_match(/только на ту же или более новую/, down[:reason].to_s)
      minor = VersionGuard.check_info({ 'sketchup_version' => '26.2.243' }, '26.1.340')
      assert minor[:blocked], 'даунгрейд внутри года тоже блокируется'
    end

    test 'version_guard: check! бросает на даунгрейде' do
      error = nil
      begin
        VersionGuard.check!({ 'sketchup_version' => '27.0.100' }, '26.0.0')
      rescue Dn1supSaveSettings::Error => e
        error = e.message
      end
      assert error && error.include?('запрещено'), "ожидали hard-блок, получили: #{error.inspect}"
    end

    test 'version_guard: неизвестная версия блокируется, imported — с предупреждением' do
      blocked = VersionGuard.check_info({ 'sketchup_version' => '' }, '27.0.100')
      assert blocked[:blocked], 'битый архив должен блокироваться'
      assert blocked[:unknown]
      allowed = VersionGuard.check_info({ 'sketchup_version' => '' }, '27.0.100', allow_unknown: true)
      assert !allowed[:blocked], 'imported с неизвестной версией — разрешить'
      assert allowed[:unknown]
    end

    test 'version_guard: неизвестная текущая версия не блокирует (тесты/dev)' do
      info = VersionGuard.check_info({ 'sketchup_version' => '27.0.100' }, '—')
      assert !info[:blocked], "вне SketchUp enforcement невозможен: #{info.inspect}"
    end
  end
end
