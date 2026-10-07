# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/settings.rb — пользовательские настройки расширения
# (settings.json в хранилище). Главный параметр — папка архивов: куда
# сохраняются новые резервные копии и где прежде всего ищутся существующие.
# Пустое значение = стандартная папка Store.dir/backups.
#
# Повреждённый/отсутствующий файл не ломает работу — настройки читаются
# как стандартные (сами архивы остаются на местах).
# =============================================================================

require 'json'
require 'fileutils'

module Dn1supSaveSettings
  module Settings
    extend self

    FILE_NAME = 'settings.json'
    VERSION = 1

    def path
      File.join(Store.dir, FILE_NAME)
    end

    # Папка архивов: нормализованный путь (прямые слэши, без хвостовых)
    # или '' — стандартная папка.
    def archive_dir
      normalize(read['archive_dir'])
    end

    def custom?
      !archive_dir.empty?
    end

    # Задаёт папку архивов (создаёт при отсутствии). Возвращает нормализованный
    # путь. Относительные и диско-относительные пути ('C:') отклоняются.
    def set_archive_dir!(dir)
      raw = dir.is_a?(String) ? dir.strip : ''
      raise Error, 'Папка архивов не указана' if raw.empty?
      raise Error, "Путь не является абсолютным: #{raw}" unless File.absolute_path?(raw)

      normalized = normalize(raw)
      if inside_backed_up?(normalized)
        raise Error,
              'Папка находится внутри архивируемых каталогов SketchUp. ' \
              'Выберите расположение вне «…\\SketchUp 202x\\SketchUp» ' \
              '(Roaming и Local), иначе архив будет захватывать сам себя.'
      end

      FileUtils.mkdir_p(normalized)
      write('archive_dir' => normalized)
      normalized
    end

    def reset_archive_dir!
      write('archive_dir' => '')
      ''
    end

    # Запускать ли SketchUp после отложенного применения файлов настроек
    # (запоминается выбор галочки в окне восстановления).
    def restore_relaunch
      read['restore_relaunch'] != false
    end

    def set_restore_relaunch!(value)
      value = value ? true : false
      write('restore_relaunch' => value)
      value
    end

    private

    # Обратные слэши → прямые, без хвостовых; пустые/не-строки → ''.
    def normalize(dir)
      return '' unless dir.is_a?(String) && !dir.strip.empty?

      File.expand_path(dir.strip).tr('\\', '/').sub(%r{/+\z}, '')
    end

    # Папка (или её родитель) совпадает с одной из архивируемых целей —
    # архив захватил бы сам себя.
    def inside_backed_up?(dir)
      probe = "#{dir.downcase}/"
      Paths::TARGETS.any? do |t|
        target = File.expand_path(Paths.resolve(t)).downcase
        probe.start_with?("#{target}/")
      end
    rescue StandardError
      false
    end

    def read
      data = JSON.parse(File.read(path, encoding: 'UTF-8'))
      data.is_a?(Hash) ? data : {}
    rescue StandardError => e
      warn_once("Не удалось прочитать настройки (#{path}): #{e.class}: #{e.message} — используются стандартные значения")
      {}
    end

    # read вызывается при каждом обновлении интерфейса — предупреждение
    # о повреждённом файле пишется в журнал один раз за сессию.
    def warn_once(message)
      return if @read_warned

      @read_warned = true
      Log.warn(message)
    end

    def write(data)
      FileUtils.mkdir_p(Store.dir)
      File.write(path, JSON.pretty_generate({ 'settings_version' => VERSION }.merge(data)))
    rescue StandardError => e
      raise Error, "Не удалось записать настройки (#{path}): #{e.message}"
    end
  end
end
