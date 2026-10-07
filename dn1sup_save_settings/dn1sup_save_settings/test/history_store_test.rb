# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/test/history_store_test.rb — история сохранений:
# append/list (новые первыми)/remove, устойчивость к повреждённому файлу.
# =============================================================================

require 'fileutils'
require 'tmpdir'

module Dn1supSaveSettings
  module Test
    test 'history: append/list/remove' do
      Dir.mktmpdir do |store|
        ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR'] = store
        begin
          assert_equal [], HistoryStore.list, 'пустая история на старте'

          HistoryStore.append('file' => 'a.zip', 'created_at' => '2026-10-06 10:00:00', 'kind' => 'manual')
          HistoryStore.append('file' => 'b.zip', 'created_at' => '2026-10-06 11:00:00', 'kind' => 'auto')
          assert_equal %w[b.zip a.zip], HistoryStore.list.map { |e| e['file'] }, 'новые записи первыми'

          found = HistoryStore.find('a.zip')
          assert found && found['kind'] == 'manual'

          assert HistoryStore.remove('a.zip')
          assert_equal %w[b.zip], HistoryStore.list.map { |e| e['file'] }
          assert !HistoryStore.remove('a.zip'), 'повторное удаление — false'
        ensure
          ENV.delete('DN1SUP_SAVE_SETTINGS_STORE_DIR')
        end
      end
    end

    test 'history: повреждённый файл не ломает чтение' do
      Dir.mktmpdir do |store|
        ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR'] = store
        begin
          FileUtils.mkdir_p(store)
          File.write(File.join(store, 'history.json'), '{не-json')
          assert_equal [], HistoryStore.list
        ensure
          ENV.delete('DN1SUP_SAVE_SETTINGS_STORE_DIR')
        end
      end
    end
  end
end
