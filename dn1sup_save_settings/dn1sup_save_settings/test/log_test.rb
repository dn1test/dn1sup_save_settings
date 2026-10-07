# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/test/log_test.rb — журнал работы и ошибок (Log):
# формат записи, уровни, backtrace, кодировка, ротация и «никогда не падает».
# =============================================================================

require 'fileutils'
require 'tmpdir'

module Dn1supSaveSettings
  module Test
    # Локальная папка журнала на время блока (ENV читается Log при каждой записи).
    def self.with_log_dir
      Dir.mktmpdir('dn1sup_log_test_') do |dir|
        old = ENV['DN1SUP_SAVE_SETTINGS_LOG_DIR']
        ENV['DN1SUP_SAVE_SETTINGS_LOG_DIR'] = dir
        begin
          yield dir
        ensure
          old ? ENV['DN1SUP_SAVE_SETTINGS_LOG_DIR'] = old : ENV.delete('DN1SUP_SAVE_SETTINGS_LOG_DIR')
        end
      end
    end

    test 'log: info/warn/error пишутся с меткой времени и уровнем' do
      with_log_dir do
        Log.info('информационное сообщение')
        Log.warn('предупреждение')
        Log.error('ошибка')
        lines = File.readlines(Log.path, encoding: 'UTF-8').map(&:strip)
        assert_equal 3, lines.size
        assert_match(/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \[INFO\] информационное сообщение\z/, lines[0])
        assert_match(/\[WARN\] предупреждение\z/, lines[1])
        assert_match(/\[ERROR\] ошибка\z/, lines[2])
      end
    end

    test 'log: exception пишет контекст, класс, сообщение и backtrace' do
      with_log_dir do
        begin
          raise RuntimeError, 'бум'
        rescue StandardError => e
          Log.exception(e, 'контекст')
        end
        text = File.read(Log.path, encoding: 'UTF-8')
        assert_match(/\[ERROR\] \[контекст\] RuntimeError: бум/, text)
        assert_match(/^    \S+.*log_test/, text, 'строка backtrace с отступом ожидается в журнале')
      end
    end

    test 'log: кириллица и битые байты не ломают запись' do
      with_log_dir do
        bad = +"кириллица ✓ | " << "\xFF\xFE".dup.force_encoding('UTF-8')
        Log.info(bad)
        text = File.read(Log.path, encoding: 'UTF-8')
        assert_match(/кириллица/, text)
        assert text.valid_encoding?, 'запись в журнале должна быть корректным UTF-8'
        assert text.include?("\uFFFD"), 'битые байты должны быть заменены символом «�»'
      end
    end

    test 'log: ротация при превышении лимита' do
      with_log_dir do
        Log.info('X' * (Log::MAX_BYTES + 1024))
        assert File.size(Log.path) > Log::MAX_BYTES, 'порог ротации должен быть превышен'

        Log.info('после ротации')
        assert File.exist?("#{Log.path}.1"), 'прежний журнал должен переехать в .1'
        assert File.size("#{Log.path}.1") > Log::MAX_BYTES
        assert File.size(Log.path) < Log::MAX_BYTES
        lines = File.readlines(Log.path, encoding: 'UTF-8').map(&:strip)
        assert_equal 1, lines.size
        assert_match(/после ротации\z/, lines[0])
      end
    end

    test 'log: запись никогда не поднимает исключений (папка недоступна)' do
      Dir.mktmpdir do |tmp|
        blocker = File.join(tmp, 'not_a_dir')
        File.write(blocker, 'x')
        old = ENV['DN1SUP_SAVE_SETTINGS_LOG_DIR']
        ENV['DN1SUP_SAVE_SETTINGS_LOG_DIR'] = blocker
        begin
          assert_nil Log.info('не должно упасть')
          assert_nil Log.exception(StandardError.new('тоже не должно'))
          assert !File.exist?(File.join(blocker, Log::FILE_NAME)), 'файл журнала не должен появиться'
        ensure
          old ? ENV['DN1SUP_SAVE_SETTINGS_LOG_DIR'] = old : ENV.delete('DN1SUP_SAVE_SETTINGS_LOG_DIR')
        end
      end
    end

    test 'log: session_start пишет баннер с версиями' do
      with_log_dir do
        # В SketchUp баннер за сессию пишется один раз ($dn1sup_ss_log_session):
        # тест снимает guard, как это делает горячая перезагрузка, и восстанавливает.
        prev = $dn1sup_ss_log_session
        $dn1sup_ss_log_session = nil
        begin
          Log.session_start
        ensure
          $dn1sup_ss_log_session = prev
        end
        text = File.read(Log.path, encoding: 'UTF-8')
        assert_match(/Сессия SketchUp — \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/, text)
        assert_match(/Ruby:\s+\d+\.\d+/, text)
        assert_match(/Плагин:\s+v#{Regexp.escape(Dn1supSaveSettings::VERSION)}/, text)
      end
    end
  end
end
