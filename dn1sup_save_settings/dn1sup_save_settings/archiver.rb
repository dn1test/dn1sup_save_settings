# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/archiver.rb — zip через встроенный в Windows tar.exe
# (bsdtar, System32; Windows 10 1803+ / Windows 11).
#
# Windows-сборка bsdtar НЕ поддерживает -s (переименование записей), поэтому
# архив собирается из staging-папки с целевой структурой:
#   dn1sup_settings_manifest.json   ← манифест (метаданные)
#   dn1sup_settings_log.txt         ← лог архивации (что и откуда скопировано)
#   roaming/…                       ← содержимое Roaming-целей
#   local/…                         ← содержимое Local-целей
#
# Гемы в Ruby SketchUp не устанавливать — внешний системный инструмент.
# tar запускается через WinProcess (скрыто, без окна терминала), опираемся
# только на код возврата: внутри SketchUp вывод дочерних процессов пуст.
# =============================================================================

require 'open3' # только для list() — диагностика вне SketchUp
require 'fileutils'
require 'json'
require 'tmpdir'
require 'find'

module Dn1supSaveSettings
  module Archiver
    extend self

    # Полный путь к встроенному bsdtar: пин на System32 вместо поиска по PATH —
    # детерминированно и позволяет проверять доступность без запуска процесса.
    TAR_PATH = File.join(ENV['SystemRoot'] || ENV['WINDIR'] || 'C:\\Windows',
                         'System32', 'tar.exe').tr('/', '\\').freeze

    MANIFEST_NAME = 'dn1sup_settings_manifest.json'
    LOG_NAME = 'dn1sup_settings_log.txt'

    # Лимит построчного списка файлов в логе на одну запись — страховка от
    # гигантских папок (Plugins); итоговые счётчики при этом остаются точными.
    LOG_LISTING_LIMIT = 10_000

    class Error < StandardError; end

    # Доступен ли движок (проверяется один раз за сессию). Достаточно наличия
    # файла: запуском процесса ничего дополнительно не проверяем — экономно и
    # без малейшего шанса на окно терминала.
    def available?
      return @available unless @available.nil?

      @available = File.file?(TAR_PATH)
    end

    # Собирает zip из манифеста и записей.
    #   manifest — Hash метаданных (записывается в корень архива);
    #   entries  — массив { scope: 'roaming'|'local', name: 'Materials',
    #                       src: 'полный исходный путь' }.
    # В корень архива вместе с манифестом пишется лог архивации
    # (LOG_NAME): что, откуда и с какими размерами попало в архив.
    # Возвращает путь к созданному zip.
    def create(manifest, entries, dest_zip)
      raise Error, 'Встроенный zip-движок (tar.exe) недоступен' unless available?

      FileUtils.mkdir_p(File.dirname(dest_zip))
      Dir.mktmpdir('dn1sup_ss_') do |staging|
        File.write(File.join(staging, MANIFEST_NAME), JSON.pretty_generate(manifest))

        skipped_links = []
        entries.each do |entry|
          dest = File.join(staging, entry[:scope].to_s, entry[:name].to_s)
          copy_tree(entry[:src], dest, {}, skipped_links)
        end

        File.write(File.join(staging, LOG_NAME),
                   build_log(manifest, entries, staging, dest_zip, skipped_links))

        top = Dir.children(staging).sort
        code = WinProcess.run(TAR_PATH, '-acf', dest_zip, '-C', staging, *top)
        raise Error, "tar.exe: код #{code}" unless code.zero?
      end
      dest_zip
    end

    # Рекурсивно копирует src в dest, разыменовывая симлинки/джанкшны
    # СОДЕРЖИМЫМ (в архив/на диск попадает содержимое цели, а не ссылка).
    #
    # Зачем: FileUtils.cp_r переносит симлинки как симлинки через
    # File.symlink, а на Windows это требует привилегии
    # SeCreateSymbolicLinkPrivilege (режим разработчика/админ) и падает с
    # Errno::EACCES (@ rb_file_s_symlink) — например, на ссылке вида
    # Plugins/asm_faceup. Поэтому ссылки здесь не пересоздаются.
    #
    # Битые ссылки (цели нет) и циклы (ссылка на уже посещённый каталог)
    # пропускаются с предупреждением в журнал; пути пропущенных
    # накапливаются в skipped (тот же массив, что передан caller'ом).
    # Возвращает массив skipped.
    #
    # Повторы при EACCES/EPERM: живые файлы во временных каталогах иногда
    # заняты антивирусом на доли секунды (свежераспакованный .rbe в staging
    # перед восстановлением) — до 3 попыток с паузой вместо мгновенного
    # падения всего бэкапа/восстановления.
    def copy_tree(src, dest, seen = nil, skipped = nil)
      tries = 0
      begin
        # Свежие seen/skipped на каждую попытку: частично заполненные
        # за упавшую попытку иначе давали бы ложные «циклы» и дубли.
        # Успешный результат синхронизируется обратно в переданные массивы
        # (вызывающие — Archiver.create/Backup::Job — читают skipped для лога).
        s = (seen || {}).dup
        k = (skipped || []).dup
        result = copy_tree_impl(src, dest, s, k)
        seen.clear.merge!(s) if seen
        skipped.clear.concat(k) if skipped
        result
      rescue Errno::EACCES, Errno::EPERM => e
        tries += 1
        if tries < 3
          Log.warn("Повтор копирования (#{src}): #{e.class} — попытка #{tries + 1}/3")
          sleep(0.2 * tries)
          retry
        end
        raise
      end
    end

    # Собственно обход дерева (см. copy_tree: контракт и повторы).
    # Рекурсия идёт напрямую через copy_tree_impl — единый конверт повторов
    # сверху, без умножения попыток на каждом уровне.
    def copy_tree_impl(src, dest, seen = nil, skipped = nil)
      seen ||= {}
      skipped ||= []
      if File.symlink?(src)
        begin
          real = File.realpath(src)
        rescue StandardError
          real = nil
        end
        if real.nil? || !File.exist?(real)
          skipped << src
          Log.warn("Пропущен битый симлинк (нет цели): #{src}")
          return skipped
        end
        if File.directory?(real)
          key = cycle_key(real)
          if seen[key]
            skipped << src
            Log.warn("Пропущен симлинк (цикл): #{src} -> #{real}")
            return skipped
          end
          seen[key] = true
          FileUtils.mkdir_p(dest)
          Dir.children(real).each do |child|
            copy_tree_impl(File.join(real, child), File.join(dest, child), seen, skipped)
          end
        else
          FileUtils.mkdir_p(File.dirname(dest))
          FileUtils.cp(real, dest)
        end
      elsif File.directory?(src)
        begin
          real = File.realpath(src)
        rescue StandardError
          real = src
        end
        key = cycle_key(real)
        if seen[key]
          skipped << src
          Log.warn("Пропущен каталог (цикл): #{src}")
          return skipped
        end
        seen[key] = true
        FileUtils.mkdir_p(dest)
        Dir.children(src).each do |child|
          copy_tree_impl(File.join(src, child), File.join(dest, child), seen, skipped)
        end
      else
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(src, dest)
      end
      skipped
    end

    # Распаковывает архив целиком в dest_dir (создаётся при необходимости).
    def extract(zip_path, dest_dir)
      raise Error, 'Встроенный zip-движок (tar.exe) недоступен' unless available?
      raise Error, "Архив не найден: #{zip_path}" unless File.file?(zip_path)

      FileUtils.mkdir_p(dest_dir)
      code = WinProcess.run(TAR_PATH, '-xf', zip_path, '-C', dest_dir)
      raise Error, "tar.exe: код #{code}" unless code.zero?
      dest_dir
    end

    # Читает манифест из архива, распаковывая только его во временную папку.
    # (tar -xOf с выводом в stdout не годится: внутри SketchUp stdout дочерних
    # процессов пуст.) nil — манифеста нет (чужой архив) или архив повреждён.
    def read_manifest(zip_path)
      return nil unless File.file?(zip_path)
      return nil unless available?

      Dir.mktmpdir('dn1sup_mf_') do |tmp|
        code = WinProcess.run(TAR_PATH, '-xf', zip_path, '-C', tmp, MANIFEST_NAME)
        return nil unless code.zero?

        path = File.join(tmp, MANIFEST_NAME)
        return nil unless File.file?(path)

        JSON.parse(File.read(path, encoding: 'UTF-8'))
      end
    rescue StandardError => e
      Log.warn("Не удалось прочитать манифест (#{File.basename(zip_path.to_s)}): #{e.class}: #{e.message}")
      nil
    end

    # Читает лог архивации из архива, распаковывая только его во временную
    # папку (тот же приём, что у read_manifest). nil — лога нет (архив старой
    # версии расширения или чужой) либо архив отсутствует/повреждён.
    def read_log(zip_path)
      return nil unless File.file?(zip_path)
      return nil unless available?

      Dir.mktmpdir('dn1sup_lg_') do |tmp|
        code = WinProcess.run(TAR_PATH, '-xf', zip_path, '-C', tmp, LOG_NAME)
        return nil unless code.zero?

        path = File.join(tmp, LOG_NAME)
        return nil unless File.file?(path)

        File.read(path, encoding: 'UTF-8')
      end
    rescue StandardError => e
      Log.warn("Не удалось прочитать лог архивации (#{File.basename(zip_path.to_s)}): #{e.class}: #{e.message}")
      nil
    end

    # Список записей архива (tar -tf). Диагностика: вывод здесь нужен, а внутри
    # SketchUp stdout дочерних процессов пуст — метод осмыслен только в
    # обычном Ruby, поэтому оставлен на Open3 (вне SketchUp окна не проблема).
    def list(zip_path)
      out, _err, status = Open3.capture3(TAR_PATH, '-tf', zip_path)
      return [] unless status.success?

      out.lines.map(&:strip).reject(&:empty?)
    rescue StandardError => e
      Log.warn("Не удалось получить список записей архива (#{zip_path}): #{e.class}: #{e.message}")
      []
    end

    # Расширения нативных бинарников: собраны под конкретные Ruby/SketchUp
    # и чаще всего НЕ работают после переноса в другую версию.
    # .rbe сюда не входит: подписанный шифрованный Ruby грузится везде.
    NATIVE_EXTS = %w[.so .dll .bundle .dylib].freeze

    # Нативные бинарники из лога архивации (для предупреждения о переносе
    # между версиями SketchUp). Состав берётся из лога, а не из распаковки
    # списка: внутри SketchUp stdout дочерних процессов пуст (см. list).
    # [] — нативных нет; nil — лога нет (старый формат) или архив не читается.
    def scan_native(zip_path)
      log = read_log(zip_path)
      return nil if log.nil?

      found = []
      section = ''
      log.each_line do |line|
        # Заголовок секции записи: «[roaming] Plugins — папка». Файлы ниже
        # него перечислены относительно неё — запоминаем префикс.
        if (m = line.strip.match(/\A\[(?<scope>[^\]]+)\]\s+(?<name>.+?)\s+—\s+(?:папка|файл)\s*\z/))
          section = "#{m[:name]}/"
          next
        end
        rel = line.strip.sub(/\s+—\s+\d+\z/, '')
        next if rel == line.strip

        found << "#{section}#{rel}" if NATIVE_EXTS.include?(File.extname(rel).downcase)
      end
      found.uniq.sort
    rescue StandardError => e
      Log.warn("Не удалось проверить нативные бинарники (#{File.basename(zip_path.to_s)}): #{e.class}: #{e.message}")
      nil
    end

    private

    # Лог строится обходом staging-папки ПОСЛЕ копирования записей — поэтому
    # он всегда совпадает с фактическим содержимым архива.
    def build_log(manifest, entries, staging, dest_zip, skipped = [])
      entries = Array(entries)
      lines = []
      lines << 'dn1sup_save_settings — лог архивации'
      lines << '=' * 44
      lines << "Создан:       #{manifest['created_at']}"
      lines << "SketchUp:     #{manifest['sketchup_version']} (#{manifest['sketchup_year']})"
      lines << "Пользователь: #{manifest['user']}"
      lines << "Тип:          #{manifest['kind']}"
      comment = manifest['comment'].to_s
      lines << "Комментарий:  #{comment.empty? ? '—' : comment}"
      lines << "Пути:         #{Array(manifest['paths']).join(', ')}"
      lines << ''

      total_files = 0
      total_bytes = 0
      entries.each do |entry|
        dest = File.join(staging, entry[:scope].to_s, entry[:name].to_s)
        dir = File.directory?(dest)
        lines << "[#{entry[:scope]}] #{entry[:name]} — #{dir ? 'папка' : 'файл'}"
        lines << "  Источник: #{entry[:src]}"

        if dir
          files = []
          Find.find(dest) { |path| files << path if File.file?(path) }
          files.sort!
          size = files.sum { |p| File.size(p) }
          total_files += files.size
          total_bytes += size
          lines << "  Файлов: #{files.size} · Размер: #{human_size(size)}"
          files.take(LOG_LISTING_LIMIT).each { |p| lines << "    #{log_rel(dest, p)} — #{File.size(p)}" }
          lines << "    … и ещё #{files.size - LOG_LISTING_LIMIT} файлов (список усечён)" if files.size > LOG_LISTING_LIMIT
        else
          size = File.size(dest)
          total_files += 1
          total_bytes += size
          lines << "  Размер: #{size} байт"
        end
        lines << ''
      end

      lines << '---'
      Array(skipped).each do |path|
        lines << "Пропущен симлинк (битый или цикл, в архив не вошёл): #{path}"
      end
      lines << "Итог: путей #{entries.size} · файлов #{total_files} · #{human_size(total_bytes)} (#{total_bytes} байт)"
      lines << "Архив: #{File.basename(dest_zip)}"
      lines.join("\n") + "\n"
    end

    def log_rel(from, path)
      prefix = File.join(from, '')
      path.start_with?(prefix) ? path[prefix.length..] : path
    end

    # Ключ посещённого каталога для отсечения циклов: на Windows файловая
    # система регистронезависима, поэтому сравниваем в нижнем регистре —
    # иначе одно и то же место, записанное в разном регистре, даст ложный
    # проход и бесконечную рекурсию.
    def cycle_key(real)
      (RUBY_PLATFORM =~ /mswin|mingw|cygwin/ ? real.downcase : real)
    end

    def human_size(bytes)
      units = %w[Б КБ МБ ГБ ТБ]
      v = bytes.to_f
      i = 0
      while v >= 1024 && i < units.size - 1
        v /= 1024
        i += 1
      end
      text = v >= 100 || i.zero? ? v.round.to_s : format('%.1f', v)
      "#{text} #{units[i]}"
    end
  end
end
