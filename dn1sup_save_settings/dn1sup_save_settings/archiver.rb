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
# =============================================================================

require 'open3'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'find'

module Dn1supSaveSettings
  module Archiver
    extend self

    MANIFEST_NAME = 'dn1sup_settings_manifest.json'
    LOG_NAME = 'dn1sup_settings_log.txt'

    # Лимит построчного списка файлов в логе на одну запись — страховка от
    # гигантских папок (Plugins); итоговые счётчики при этом остаются точными.
    LOG_LISTING_LIMIT = 10_000

    class Error < StandardError; end

    # Доступен ли движок (проверяется один раз за сессию).
    # ВАЖНО: внутри SketchUp дочерние процессы не пишут в унаследованный
    # stdout (даже «cmd /c echo» возвращает пустую строку), поэтому опираться
    # на вывод нельзя — только на код возврата и отсутствие ENOENT.
    def available?
      return @available unless @available.nil?

      _out, _err, status = Open3.capture3('tar', '--version')
      @available = status.success?
    rescue StandardError => e
      Log.warn("Встроенный zip-движок (tar.exe) недоступен: #{e.class}: #{e.message}")
      @available = false
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

        entries.each do |entry|
          dest = File.join(staging, entry[:scope].to_s, entry[:name].to_s)
          FileUtils.mkdir_p(File.dirname(dest))
          if File.directory?(entry[:src])
            FileUtils.cp_r(File.join(entry[:src], '.'), dest)
          else
            FileUtils.cp(entry[:src], dest)
          end
        end

        File.write(File.join(staging, LOG_NAME),
                   build_log(manifest, entries, staging, dest_zip))

        top = Dir.children(staging).sort
        _out, err, status = Open3.capture3('tar', '-acf', dest_zip, '-C', staging, *top)
        unless status.success?
          raise Error, "tar.exe: код #{status.exitstatus}#{err.strip.empty? ? '' : " — #{err.strip}"}"
        end
      end
      dest_zip
    end

    # Распаковывает архив целиком в dest_dir (создаётся при необходимости).
    def extract(zip_path, dest_dir)
      raise Error, 'Встроенный zip-движок (tar.exe) недоступен' unless available?
      raise Error, "Архив не найден: #{zip_path}" unless File.file?(zip_path)

      FileUtils.mkdir_p(dest_dir)
      _out, err, status = Open3.capture3('tar', '-xf', zip_path, '-C', dest_dir)
      unless status.success?
        raise Error, "tar.exe: код #{status.exitstatus}#{err.strip.empty? ? '' : " — #{err.strip}"}"
      end
      dest_dir
    end

    # Читает манифест из архива, распаковывая только его во временную папку.
    # (tar -xOf с выводом в stdout не годится: внутри SketchUp stdout дочерних
    # процессов пуст.) nil — манифеста нет (чужой архив) или архив повреждён.
    def read_manifest(zip_path)
      return nil unless File.file?(zip_path)
      return nil unless available?

      Dir.mktmpdir('dn1sup_mf_') do |tmp|
        _out, _err, status = Open3.capture3('tar', '-xf', zip_path, '-C', tmp, MANIFEST_NAME)
        return nil unless status.success?

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
        _out, _err, status = Open3.capture3('tar', '-xf', zip_path, '-C', tmp, LOG_NAME)
        return nil unless status.success?

        path = File.join(tmp, LOG_NAME)
        return nil unless File.file?(path)

        File.read(path, encoding: 'UTF-8')
      end
    rescue StandardError => e
      Log.warn("Не удалось прочитать лог архивации (#{File.basename(zip_path.to_s)}): #{e.class}: #{e.message}")
      nil
    end

    # Список записей архива (tar -tf). Диагностика: внутри SketchUp stdout
    # дочерних процессов пуст — метод осмыслен только в обычном Ruby.
    def list(zip_path)
      out, _err, status = Open3.capture3('tar', '-tf', zip_path)
      return [] unless status.success?

      out.lines.map(&:strip).reject(&:empty?)
    rescue StandardError => e
      Log.warn("Не удалось получить список записей архива (#{zip_path}): #{e.class}: #{e.message}")
      []
    end

    private

    # Лог строится обходом staging-папки ПОСЛЕ копирования записей — поэтому
    # он всегда совпадает с фактическим содержимым архива.
    def build_log(manifest, entries, staging, dest_zip)
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
      lines << "Итог: путей #{entries.size} · файлов #{total_files} · #{human_size(total_bytes)} (#{total_bytes} байт)"
      lines << "Архив: #{File.basename(dest_zip)}"
      lines.join("\n") + "\n"
    end

    def log_rel(from, path)
      prefix = File.join(from, '')
      path.start_with?(prefix) ? path[prefix.length..] : path
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
