# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/test/win_process_test.rb — скрытый запуск процессов
# (WScript.Shell.Run без окна терминала): код возврата, отсоединённый запуск.
# =============================================================================

require 'tmpdir'

module Dn1supSaveSettings
  module Test
    test 'win_process: run возвращает код возврата процесса' do
      skip('только Windows') unless Gem.win_platform?

      assert_equal 0, WinProcess.run('cmd', '/c', 'exit', '0')
      assert_equal 5, WinProcess.run('cmd', '/c', 'exit', '5')
      # Реальный ребёнок расширения: встроенный bsdtar.
      skip('tar.exe недоступен') unless File.file?(Archiver::TAR_PATH)
      assert_equal 0, WinProcess.run(Archiver::TAR_PATH, '--version')
    end

    test 'win_process: run_detached — запуск без ожидания завершения' do
      skip('tar.exe недоступен') unless File.file?(Archiver::TAR_PATH)

      Dir.mktmpdir do |tmp|
        File.write(File.join(tmp, 'a.txt'), 'x')
        zip = File.join(tmp, 'detached.zip')

        t0 = Time.now
        assert WinProcess.run_detached(Archiver::TAR_PATH, '-acf', zip, '-C', tmp, 'a.txt'),
               'run_detached вернул false — запуск не состоялся'
        assert Time.now - t0 < 2, 'run_detached не должен ждать завершения процесса'

        deadline = Time.now + 10
        sleep(0.05) while !File.file?(zip) && Time.now < deadline
        assert File.file?(zip), 'отсоединённый процесс не создал архив'
      end
    end
  end
end
