# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/win_process.rb — запуск консольных программ БЕЗ окна
# терминала.
#
# SketchUp — GUI-процесс без консоли: любой запущенный из него консольный
# exe (tar.exe, powershell.exe) получает от Windows НОВОЕ видимое консольное
# окно. Open3/Process.spawn на Windows не позволяют задать CREATE_NO_WINDOW,
# поэтому используем WScript.Shell.Run (COM, win32ole из состава Ruby):
# intWindowStyle=0 (SW_HIDE) — консоль ребёнка создаётся скрытой,
# bWaitOnReturn=true возвращает код возврата процесса.
#
# Вывод (stdout/stderr) недоступен — это соответствует практике расширения:
# внутри SketchUp вывод дочерних процессов всё равно пуст, везде опираемся
# на код возврата.
# =============================================================================

module Dn1supSaveSettings
  module WinProcess
    extend self

    SW_HIDE = 0

    begin
      require 'win32ole'
      SUPPORTED = true
    rescue LoadError, StandardError
      SUPPORTED = false
    end

    # Запустить программу и дождаться завершения. Возвращает код возврата.
    def run(*argv)
      argv = argv.flatten
      return open3_exitstatus(*argv) unless SUPPORTED

      shell.Run(build_command_line(argv), SW_HIDE, true)
    rescue StandardError => e
      Log.warn("Не удалось запустить «#{argv.first}»: #{e.class}: #{e.message}")
      -1
    end

    # Запустить программу, не дожидаясь завершения (процесс переживает выход
    # SketchUp — дочерние процессы Windows при смерти родителя не убивает).
    # true — запуск состоялся.
    def run_detached(*argv)
      argv = argv.flatten
      unless SUPPORTED
        pid = Process.spawn(*argv, out: File::NULL, err: File::NULL, new_pgroup: true)
        Process.detach(pid)
        return true
      end

      shell.Run(build_command_line(argv), SW_HIDE, false)
      true
    rescue StandardError => e
      Log.warn("Не удалось запустить «#{argv.first}»: #{e.class}: #{e.message}")
      false
    end

    private

    def shell
      @shell ||= WIN32OLE.new('WScript.Shell')
    end

    # Командная строка для WScript.Shell.Run: создаётся процесс напрямую
    # (без cmd), поэтому каждому аргументу достаточно двойных кавычек.
    def build_command_line(argv)
      argv.map { |arg| %("#{arg}") }.join(' ')
    end

    # Фолбэк (не Windows или нет win32ole): прежнее поведение — окно
    # терминала может мигнуть, но результат тот же.
    def open3_exitstatus(*argv)
      require 'open3'
      _out, _err, status = Open3.capture3(*argv)
      status.exitstatus.to_i
    rescue StandardError => e
      Log.warn("Не удалось запустить «#{argv.first}»: #{e.class}: #{e.message}")
      -1
    end
  end
end
