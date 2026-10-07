# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/log.rb — журнал работы и ошибок расширения.
#
# Файл журнала: <хранилище>/dn1sup_save_settings.log (Store.dir — %APPDATA%/
# SketchUp/«SketchUp <год>»/dn1sup_save_settings). Каталог — сосед
# бэкапируемых папок SketchUp, в Plugins не входит: журнал переживает полное
# удаление расширения (обновление, установка .rbz поверх, сброс плагинов).
#
# Модуль нарочито без зависимостей и никогда не поднимает исключений:
# регистратор грузит его ПЕРВЫМ (до store.rb — корень хранилища на этот
# случай считается локально), при невозможности записи журнал молча
# переходит на puts в консоль Ruby. Пишет только UTF-8 (сообщения системы
# и WinAPI перекодируются, битые байты заменяются).
#
# Ротация: при превышении MAX_BYTES журнал сдвигается в .1/.2.
# Папка журнала переопределяется переменной DN1SUP_SAVE_SETTINGS_LOG_DIR
# (тесты; по умолчанию — хранилище расширения).
# =============================================================================

require 'fileutils'

module Dn1supSaveSettings
  module Log
    extend self

    FILE_NAME = 'dn1sup_save_settings.log'
    MAX_BYTES = 2 * 1024 * 1024 # ротация основного файла при превышении
    KEEP      = 2               # сколько сдвинутых копий хранить (.1, .2)

    @mutex = Mutex.new

    # -- API --------------------------------------------------------------------

    def info(msg)
      write('INFO', msg)
    end

    def warn(msg)
      write('WARN', msg)
    end

    def error(msg)
      write('ERROR', msg)
    end

    # Исключение: класс, сообщение (с контекстом) и до 10 строк backtrace.
    def exception(err, context = nil)
      head = context ? "[#{context}] #{err.class}: #{err.message}" : "#{err.class}: #{err.message}"
      write('ERROR', head, Array(err.backtrace).first(10))
    end

    # Полный путь файла журнала.
    def path
      File.join(dir, FILE_NAME)
    end

    # Папка журнала: env (тесты) → Store.dir (если загружен) → локальный
    # расчёт (регистратор грузит log.rb раньше store.rb).
    def dir
      custom = ENV['DN1SUP_SAVE_SETTINGS_LOG_DIR']
      return custom.tr('\\', '/').sub(%r{/+\z}, '') if custom && !custom.empty?
      return Store.dir if defined?(Dn1supSaveSettings::Store)

      fallback_store_dir
    end

    # Баннер начала сессии SketchUp — один раз на сессию (глобальная
    # переменная переживает remove_const при горячей перезагрузке).
    # Вне SketchUp (тесты) пишется каждый раз.
    def session_start
      if defined?(Sketchup)
        return if $dn1sup_ss_log_session

        $dn1sup_ss_log_session = true
      end
      append(session_banner)
      nil
    end

    private

    def write(level, msg, backtrace = nil)
      rows = ["#{Time.now.strftime('%Y-%m-%d %H:%M:%S.%3N')} [#{level}] #{clean(msg)}"]
      Array(backtrace).each { |line| rows << "    #{clean(line)}" }
      append(rows.join("\n"))
      nil
    end

    # Единственная точка записи на диск. Любое исключение глушится:
    # журнал не должен ронять расширение, при недоступности файла — puts.
    def append(text)
      @mutex.synchronize do
        file = path
        rotate_if_needed(file)
        target_dir = File.dirname(file)
        FileUtils.mkdir_p(target_dir) unless File.directory?(target_dir)
        File.open(file, 'a:UTF-8') { |f| f.puts text }
      end
      nil
    rescue StandardError => e
      begin
        puts "[SaveSettings] журнал недоступен (#{e.class}: #{e.message}): #{text.lines.first.to_s.strip}"
      rescue StandardError
        nil
      end
      nil
    end

    def rotate_if_needed(file)
      return unless File.exist?(file) && File.size(file) > MAX_BYTES

      FileUtils.rm_f("#{file}.#{KEEP}")
      KEEP.downto(2) { |i| FileUtils.mv("#{file}.#{i - 1}", "#{file}.#{i}") if File.exist?("#{file}.#{i - 1}") }
      FileUtils.mv(file, "#{file}.1")
    end

    # Сообщение одной строкой в UTF-8: не-UTF-8 (UTF-16 от WinAPI, системные
    # сообщения) перекодируется, битые байты заменяются символом «�».
    def clean(text)
      s = text.to_s
      s = s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace) if s.encoding != Encoding::UTF_8 || !s.valid_encoding?
      s
    rescue StandardError
      ''
    end

    def session_banner
      lines = ['=' * 72]
      lines << "Сессия SketchUp — #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
      lines << "SketchUp:      #{defined?(Sketchup) && Sketchup.respond_to?(:version) ? Sketchup.version : 'n/a (вне SketchUp)'}"
      lines << "Ruby:          #{RUBY_VERSION} (#{RUBY_PLATFORM})"
      lines << "Плагин:        v#{defined?(Dn1supSaveSettings::VERSION) ? Dn1supSaveSettings::VERSION : '?'}"
      lines << "Хранилище:     #{defined?(Dn1supSaveSettings::Store) ? Store.dir : fallback_store_dir}"
      lines << "Журнал:        #{path}"
      overrides = ENV.keys.grep(/\ADN1SUP_SAVE_SETTINGS_/).sort
      lines << "Env-оверрайды: #{overrides.join(', ')}" unless overrides.empty?
      lines << '=' * 72
      lines.join("\n")
    end

    # Дублирует Store.dir (store.rb) для случая «log.rb загружен, а store.rb
    # ещё нет» — из регистратора при ошибке регистрации.
    def fallback_store_dir
      appdata = ENV['APPDATA'] || Dir.home
      major = defined?(Sketchup) && Sketchup.respond_to?(:version) ? Sketchup.version.to_i : 26
      year = major >= 1000 ? major : 2000 + major
      File.join(appdata, 'SketchUp', "SketchUp #{year}", 'dn1sup_save_settings')
    end
  end
end
