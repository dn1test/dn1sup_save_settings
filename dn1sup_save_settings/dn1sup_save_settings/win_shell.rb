# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/win_shell.rb — открытие файлов и папок средствами
# Windows. UI.openURL не открывает file:// URL (возвращает false), поэтому
# Проводник запускаем через ShellExecuteW (не Windows — no-op).
# =============================================================================

module Dn1supSaveSettings
  module WinShell
    extend self

    begin
      require 'fiddle/import'

      module API
        extend Fiddle::Importer
        dlload 'shell32.dll'
        extern 'void* ShellExecuteW(void*, const void*, const void*, const void*, const void*, int)'
      end

      SUPPORTED = true
    rescue LoadError, StandardError
      SUPPORTED = false
    end

    SW_SHOWNORMAL = 1

    # Открыть папку в Проводнике (файл выделен, если передан файл).
    # true — окно запрошено.
    def reveal(path)
      return false unless SUPPORTED
      return false if path.nil? || path.to_s.empty?

      ret = API.ShellExecuteW(nil, nil,
                              wide('explorer.exe'),
                              wide(%(/select,"#{path.tr('/', '\\')}")),
                              nil, SW_SHOWNORMAL)
      ret.to_i > 32
    rescue StandardError => e
      Log.warn("Не удалось показать в Проводнике «#{path}»: #{e.class}: #{e.message}")
      false
    end

    # Открыть файл приложением по умолчанию.
    def open_file(path)
      return false unless SUPPORTED
      return false unless File.file?(path.to_s)

      ret = API.ShellExecuteW(nil, wide('open'),
                              wide(path.to_s.tr('/', '\\')),
                              nil, nil, SW_SHOWNORMAL)
      ret.to_i > 32
    rescue StandardError => e
      Log.warn("Не удалось открыть файл «#{path}»: #{e.class}: #{e.message}")
      false
    end

    # Открыть папку (для файла — его папку).
    def open_folder(path)
      target = path.to_s
      target = File.dirname(target) if File.file?(target)
      return false unless File.directory?(target)
      return false unless SUPPORTED

      ret = API.ShellExecuteW(nil, wide('open'),
                              wide(target.tr('/', '\\')),
                              nil, nil, SW_SHOWNORMAL)
      ret.to_i > 32
    rescue StandardError => e
      Log.warn("Не удалось открыть папку «#{target}»: #{e.class}: #{e.message}")
      false
    end

    private

    # LPCWSTR: UTF-16LE с нулевым терминатором
    def wide(str)
      (str + "\0").encode('UTF-16LE')
    end
  end
end
