# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/history_store.rb — история сохранений (history.json
# в хранилище расширения). Записи отсортированы по дате — новые первыми.
#
# Повреждённый файл не ломает работу: история начинается с чистого листа
# (сами архивы в backups/ остаются нетронутыми).
# =============================================================================

require 'json'
require 'fileutils'

module Dn1supSaveSettings
  module HistoryStore
    extend self

    FILE_NAME = 'history.json'

    def path
      File.join(Store.dir, FILE_NAME)
    end

    def list
      read.sort_by { |entry| entry['created_at'].to_s }.reverse
    end

    def find(file_name)
      list.find { |entry| entry['file'] == file_name }
    end

    def append(entry)
      entries = read
      entries << entry
      write(entries)
      entry
    end

    # Удаляет запись по имени файла архива. true — запись была.
    def remove(file_name)
      entries = read
      remaining = entries.reject { |entry| entry['file'] == file_name }
      write(remaining)
      remaining.size != entries.size
    end

    private

    def read
      return [] unless File.file?(path)

      data = JSON.parse(File.read(path, encoding: 'UTF-8'))
      data.is_a?(Array) ? data : []
    rescue StandardError => e
      warn_once("Не удалось прочитать историю (#{path}): #{e.class}: #{e.message} — история начинается заново, архивы не тронуты")
      []
    end

    # list вызывается при каждом обновлении интерфейса — предупреждение
    # о повреждённом файле пишется в журнал один раз за сессию.
    def warn_once(message)
      return if @read_warned

      @read_warned = true
      Log.warn(message)
    end

    def write(entries)
      FileUtils.mkdir_p(Store.dir)
      File.write(path, JSON.pretty_generate(entries))
    rescue StandardError => e
      raise Error, "Не удалось записать историю (#{path}): #{e.message}"
    end
  end
end
