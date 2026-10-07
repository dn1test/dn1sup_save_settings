# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/backup.rb — создание резервной копии настроек:
# сборка манифеста + выбранных путей в zip через Archiver и запись
# записи в историю.
#
# Архив:
#   dn1sup_settings_YYYY-MM-DD_HHMMSS.zip
#     ├── dn1sup_settings_manifest.json   ← метаданные
#     ├── dn1sup_settings_log.txt         ← лог архивации (читается из UI)
#     ├── roaming/Materials/… , roaming/SharedPreferences.json …
#     └── local/PrivatePreferences.json
# Пути относительные — восстановление работает на другой машине и в другой
# версии SketchUp (манифест отображает содержимое на текущие каталоги).
# =============================================================================

require 'fileutils'
require 'json'

module Dn1supSaveSettings
  module Backup
    extend self

    # keys — массив ключей путей (nil/[] = все существующие).
    # kind: 'manual' (кнопка в диалоге) | 'quick' (пункт меню) |
    #       'auto' (автобэкап перед восстановлением) | 'imported' (импорт zip).
    def create!(comment: '', keys: nil, kind: 'manual')
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Log.info("Создание резервной копии: kind=#{kind}, пути=#{Array(keys).inspect}, комментарий=#{comment.to_s[0, 100].inspect}")
      raise Error, 'Встроенный zip-движок (tar.exe) недоступен' unless Archiver.available?

      selected = select_targets(keys)
      raise Error, 'Не выбрано ни одного существующего пути для сохранения' if selected.empty?

      Store.ensure_dirs!
      # kind в имени отличает архив от ручного сохранения той же секунды
      # (например, автобэкап перед восстановлением); цикл страхует от коллизий.
      stamp = Time.now.strftime('%Y-%m-%d_%H%M%S')
      prefix = kind == 'manual' ? '' : "#{kind}_"
      file = "dn1sup_settings_#{prefix}#{stamp}.zip"
      n = 2
      while File.exist?(File.join(Store.backups_dir, file))
        file = "dn1sup_settings_#{prefix}#{stamp}_#{n}.zip"
        n += 1
      end
      dest = File.join(Store.backups_dir, file)

      manifest = {
        'app' => 'dn1sup_save_settings',
        'manifest_version' => 1,
        'created_at' => Time.now.strftime('%Y-%m-%d %H:%M:%S'),
        'sketchup_version' => Paths.su_version,
        'sketchup_year' => Paths.su_year,
        'user' => Paths.username,
        'comment' => comment.to_s,
        'kind' => kind,
        'paths' => selected.map { |t| t[:key] },
        'targets' => selected.map do |t|
          { 'key' => t[:key], 'scope' => t[:scope], 'kind' => t[:kind],
            'name' => t[:name], 'label' => t[:label] }
        end
      }

      entries = selected.map do |t|
        { scope: t[:scope], name: t[:name], src: Paths.resolve(t) }
      end
      Archiver.create(manifest, entries, dest)
      Paths.reset_sizes!

      entry = HistoryStore.append(
        'file' => file,
        'created_at' => manifest['created_at'],
        'comment' => comment.to_s,
        'kind' => kind,
        'size' => File.size(dest),
        'su_version' => manifest['sketchup_version'],
        'paths' => manifest['paths'],
        'labels' => selected.map { |t| t[:label] }
      )
      Log.info(format('Резервная копия создана: %s (%d байт, %.2f сек)',
                      entry['file'], entry['size'],
                      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started))
      entry
    end

    # Импорт внешнего zip-архива настроек (созданного этим расширением) в
    # хранилище. Возвращает запись истории.
    def import!(zip_path, comment: '')
      Log.info("Импорт zip-архива: #{zip_path}")
      raise Error, "Файл не найден: #{zip_path}" unless File.file?(zip_path)

      manifest = Archiver.read_manifest(zip_path)
      raise Error, 'В архиве нет манифеста dn1sup_settings_manifest.json — это не архив настроек dn1sup' unless manifest

      Store.ensure_dirs!
      stamp = Time.now.strftime('%Y-%m-%d_%H%M%S')
      file = "dn1sup_settings_#{stamp}_imported.zip"
      dest = File.join(Store.backups_dir, file)
      FileUtils.cp(zip_path, dest)

      entry = HistoryStore.append(
        'file' => file,
        'created_at' => Time.now.strftime('%Y-%m-%d %H:%M:%S'),
        'source_created_at' => manifest['created_at'].to_s,
        'comment' => comment.to_s,
        'kind' => 'imported',
        'size' => File.size(dest),
        'su_version' => manifest['sketchup_version'].to_s,
        'paths' => Array(manifest['paths']),
        'labels' => Array(manifest['targets']).map { |t| t['label'] }
      )
      Log.info("Архив импортирован: #{entry['file']} (#{entry['size']} байт)")
      entry
    end

    private

    def select_targets(keys)
      wanted = Array(keys)
      Paths::TARGETS.select do |t|
        (wanted.empty? || wanted.include?(t[:key])) && File.exist?(Paths.resolve(t))
      end
    end
  end
end
