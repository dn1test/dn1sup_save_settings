# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/version_stores.rb — сохранения других версий SketchUp.
#
# Хранилище расширения привязано к году (%APPDATA%/SketchUp/SketchUp <год>/
# dn1sup_save_settings), поэтому запущенный SketchUp 2026 не видит копии,
# созданные в 2024/2025. Модуль собирает историю по всем поддерживаемым
# годам (SUPPORTED_YEARS) в блоки для интерфейса и ищет архивы для
# восстановления/удаления вне текущего хранилища.
#
# Источники записей года:
#   1) history.json чужого хранилища (отсортирован — новые первыми);
#   2) orphan-zip: архивы dn1sup_settings_*.zip в папке backups, которых нет
#      в истории (битая/потерянная history.json) — подхватываются по манифесту
#      (если tar.exe доступен) либо по дате изменения файла.
# Кастомная папка архивов (Settings.archive_dir) общая для версий: её zip
# распределяются по блокам по manifest.sketchup_year, дубли по имени файла
# не задваиваются.
#
# Для тестов корень %APPDATA% переопределяется переменной окружения
# DN1SUP_SAVE_SETTINGS_APPDATA_ROOT, корень %LOCALAPPDATA% —
# DN1SUP_SAVE_SETTINGS_LOCALAPPDATA_ROOT.
# =============================================================================

require 'json'
require 'fileutils'

module Dn1supSaveSettings
  module VersionStores
    extend self

    SUPPORTED_YEARS = %w[2024 2025 2026 2027].freeze
    ARCHIVE_PREFIX = 'dn1sup_settings_'

    # -- пути ------------------------------------------------------------------

    def appdata_base
      custom = ENV['DN1SUP_SAVE_SETTINGS_APPDATA_ROOT']
      return custom.tr('\\', '/').sub(%r{/+\z}, '') if custom && !custom.empty?

      (ENV['APPDATA'] || Dir.home).to_s.tr('\\', '/')
    end

    def local_base
      custom = ENV['DN1SUP_SAVE_SETTINGS_LOCALAPPDATA_ROOT']
      return custom.tr('\\', '/').sub(%r{/+\z}, '') if custom && !custom.empty?

      (ENV['LOCALAPPDATA'] || Dir.home).to_s.tr('\\', '/')
    end

    def dir_for_year(year)
      File.join(appdata_base, 'SketchUp', "SketchUp #{year}", Store::DIR_NAME)
    end

    def backups_dir_for_year(year)
      File.join(dir_for_year(year.to_s), 'backups')
    end

    def history_path_for_year(year)
      File.join(dir_for_year(year.to_s), HistoryStore::FILE_NAME)
    end

    # Корни «…/SketchUp 2026/SketchUp» чужой версии (для её блока настроек):
    # roaming — рядом с хранилищем, local — в %LOCALAPPDATA%.
    def roots_for_year(year)
      base = File.join(appdata_base, 'SketchUp', "SketchUp #{year}", 'SketchUp')
      local = File.join(local_base, 'SketchUp', "SketchUp #{year}", 'SketchUp')
      { 'roaming' => base, 'local' => local }
    end

    # Состояние 7 целей чужой версии (тот же формат, что Paths.states):
    # существование, размер, время изменения файлов настроек.
    def targets_for_year(year)
      roots = roots_for_year(year.to_s)
      Paths::TARGETS.map do |t|
        path = File.join(roots[t[:scope].to_s], t[:name])
        exists = File.exist?(path)
        {
          'key' => t[:key], 'label' => t[:label], 'scope' => t[:scope],
          'kind' => t[:kind], 'name' => t[:name], 'path' => path,
          'exists' => exists, 'size' => exists ? target_size(path) : 0,
          'modified' => exists && t[:kind] == 'file' ? target_mtime(path) : nil
        }
      end
    end

    # -- блоки для интерфейса ----------------------------------------------------

    # Возвращает массив блоков:
    #   [{ 'year'=>..., 'current'=>bool, 'store_exists'=>bool,
    #      'backups_path'=>..., 'count'=>N, 'history'=>[...], 'targets'=>[...] }]
    # Каждая запись истории дополнена 'store_year' и 'available'
    # (zip физически на месте). Сортировка внутри блока — новые первыми.
    # targets — состояние 7 путей этой версии (для вкладки: свои настройки
    # у каждой версии; у текущей совпадают с Paths.states).
    def list
      current_year = Paths.su_year.to_s
      custom_dir = Settings.archive_dir
      custom_entries = custom_dir.empty? ? [] : scan_custom_dir(custom_dir)
      custom_by_file = {}
      custom_entries.each { |e| custom_by_file[e['file']] = e }

      SUPPORTED_YEARS.map do |year|
        entries = read_history_for_year(year)
        by_file = {}
        entries.each { |e| by_file[e['file']] = e }

        # Orphan-zip из backups года.
        scan_backups_dir(backups_dir_for_year(year), year).each do |orphan|
          next if by_file.key?(orphan['file']) || custom_by_file.key?(orphan['file'])

          entries << orphan
          by_file[orphan['file']] = orphan
        end

        # Zip из общей кастомной папки, относящиеся к этому году.
        custom_entries.each do |entry|
          next if by_file.key?(entry['file'])
          next unless entry_year(entry) == year

          entries << entry
        end

        entries = entries.sort_by { |e| e['created_at'].to_s }.reverse
        {
          'year' => year,
          'current' => year == current_year,
          'store_exists' => File.directory?(dir_for_year(year)),
          'backups_path' => backups_dir_for_year(year),
          'count' => entries.size,
          'history' => entries,
          'targets' => targets_for_year(year)
        }
      end
    end

    # -- поиск архива ------------------------------------------------------------

    # Полный путь архива по имени. store_year сужает поиск до одного года
    # (+ кастомная папка); без него ищутся все годы. Если файла нет нигде —
    # путь в активной папке (для сообщений об ошибке).
    def resolve_archive(file_name, store_year = nil)
      name = File.basename(file_name.to_s)
      return '' if name.empty?

      dirs = search_dirs(store_year)
      found = dirs.map { |d| File.join(d, name) }.find { |p| File.file?(p) }
      found || File.join(Store.backups_dir, name)
    end

    # Папки, в которых разрешено удалять архивы (все годы + кастомная).
    def allowed_dirs
      search_dirs(nil).map { |d| File.expand_path(d) }.uniq
    end

    # Удаляет запись истории года (для кнопки «Удалить» чужую копию).
    # true — запись была.
    def remove(file_name, store_year = nil)
      year = store_year.to_s.empty? ? Paths.su_year.to_s : store_year.to_s
      path = history_path_for_year(year)
      return HistoryStore.remove(file_name) if year == Paths.su_year.to_s && !File.file?(path)

      return false unless File.file?(path)

      begin
        data = JSON.parse(File.read(path, encoding: 'UTF-8'))
        entries = data.is_a?(Array) ? data : []
      rescue StandardError
        return false
      end
      remaining = entries.reject { |e| e['file'] == file_name }
      return false if remaining.size == entries.size

      File.write(path, JSON.pretty_generate(remaining))
      true
    rescue StandardError => e
      Log.warn("Не удалось удалить запись истории #{year} (#{path}): #{e.class}: #{e.message}")
      false
    end

    # -- внутреннее ---------------------------------------------------------------

    def search_dirs(store_year)
      dirs = []
      if store_year && !store_year.to_s.empty?
        # Явный блок версии: чужое хранилище — первое, иначе одноимённый
        # файл текущей версии затенял бы запрошенный.
        dirs << backups_dir_for_year(store_year.to_s)
        dirs |= Store.archive_search_dirs
      else
        # Активная папка — первая: переопределение STORE_DIR в тестах и
        # пользовательская папка архивов всегда побеждают чужие хранилища.
        dirs |= Store.archive_search_dirs
        SUPPORTED_YEARS.each { |y| dirs << backups_dir_for_year(y) }
      end
      custom = Settings.archive_dir
      dirs << custom unless custom.empty?
      dirs.uniq
    end

    def read_history_for_year(year)
      path = history_path_for_year(year)
      return [] unless File.file?(path)

      data = JSON.parse(File.read(path, encoding: 'UTF-8'))
      entries = data.is_a?(Array) ? data : []
      entries.map do |e|
        entry = e.is_a?(Hash) ? e.dup : {}
        entry['store_year'] = year.to_s
        entry['available'] = archive_available?(entry['file'], year)
        entry
      end
    rescue StandardError
      []
    end

    def archive_available?(file_name, year)
      return false if file_name.to_s.empty?

      [File.join(backups_dir_for_year(year), File.basename(file_name.to_s)),
       File.join(Store.backups_dir, File.basename(file_name.to_s)),
       File.join(Store.default_backups_dir, File.basename(file_name.to_s))].any? { |p| File.file?(p) } ||
        (!Settings.archive_dir.empty? && File.file?(File.join(Settings.archive_dir, File.basename(file_name.to_s))))
    end

    # Размер цели чужой версии (файл — напрямую, каталог — рекурсивно).
    def target_size(path)
      File.directory?(path) ? Paths.dir_size(path) : (File.size(path) rescue 0)
    rescue StandardError
      0
    end

    def target_mtime(path)
      File.mtime(path).strftime('%Y-%m-%d %H:%M')
    rescue StandardError
      nil
    end

    # Orphan-zip папки backups года: файлы, которых нет в history.json.
    def scan_backups_dir(dir, year)
      return [] unless File.directory?(dir)

      Dir.children(dir).filter_map do |name|
        next unless name.start_with?(ARCHIVE_PREFIX) && name.end_with?('.zip')

        path = File.join(dir, name)
        next unless File.file?(path)

        entry_from_zip(path, year.to_s)
      end
    rescue StandardError
      []
    end

    def scan_custom_dir(dir)
      return [] unless File.directory?(dir)

      Dir.children(dir).filter_map do |name|
        next unless name.start_with?(ARCHIVE_PREFIX) && name.end_with?('.zip')

        path = File.join(dir, name)
        next unless File.file?(path)

        entry_from_zip(path, nil)
      end
    rescue StandardError
      []
    end

    # Запись истории по zip: манифест (год/версия/комментарий/пути) если
    # читается, иначе минимум по mtime файла.
    def entry_from_zip(path, year)
      manifest = Archiver.read_manifest(path)
      name = File.basename(path)
      if manifest
        {
          'file' => name,
          'created_at' => manifest['created_at'].to_s.empty? ? mtime_of(path) : manifest['created_at'].to_s,
          'comment' => manifest['comment'].to_s,
          'kind' => manifest['kind'].to_s.empty? ? 'manual' : manifest['kind'].to_s,
          'size' => File.size(path),
          'su_version' => manifest['sketchup_version'].to_s,
          'su_year' => manifest['sketchup_year'].to_s,
          'paths' => Array(manifest['paths']),
          'labels' => Array(manifest['targets']).map { |t| t['label'] },
          'store_year' => (year || manifest['sketchup_year']).to_s,
          'available' => true,
          'orphan' => true
        }
      else
        {
          'file' => name,
          'created_at' => mtime_of(path),
          'comment' => '',
          'kind' => 'manual',
          'size' => File.size(path),
          'su_version' => '',
          'su_year' => year.to_s,
          'paths' => [],
          'labels' => [],
          'store_year' => year.to_s,
          'available' => true,
          'orphan' => true
        }
      end
    rescue StandardError
      nil
    end

    def entry_year(entry)
      y = entry['su_year'].to_s
      return y if SUPPORTED_YEARS.include?(y)

      v = entry['su_version'].to_s
      # major-версия 24/25/26/27 → год 2024/2025/2026/2027 (SketchUp 2021+: major = год − 2000)
      if v =~ /\A(\d{2,4})/
        major = Regexp.last_match(1).to_i
        guess = major >= 1000 ? major.to_s : (major >= 21 ? (2000 + major).to_s : '')
        return guess if SUPPORTED_YEARS.include?(guess)
      end
      # created_at 'YYYY-…'
      return Regexp.last_match(1) if entry['created_at'].to_s =~ /\A(202[4567])\b/ && SUPPORTED_YEARS.include?(Regexp.last_match(1))

      entry['store_year'].to_s
    end

    def mtime_of(path)
      File.mtime(path).strftime('%Y-%m-%d %H:%M:%S')
    rescue StandardError
      ''
    end
  end
end
