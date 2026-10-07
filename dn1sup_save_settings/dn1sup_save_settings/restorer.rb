# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/restorer.rb — восстановление параметров из архива:
# манифест → (по желанию) автобэкап текущего состояния → распаковка во
# временную папку → применение.
#
# Цели применяются по-разному (SketchUp держит настройки в памяти и
# перезаписывает их на диск при выходе):
#   • каталоги (Components, Materials, …) — копируются сразу, вступают в
#     силу после перезапуска SketchUp;
#   • файлы настроек (PrivatePreferences.json, SharedPreferences.json) —
#     НЕ копируются в запущенный SketchUp: он затёр бы их при выходе.
#     Они уходят в DeferredApply и применяются отсоединённым скриптом сразу
#     после закрытия SketchUp. defer_files: false — применить сразу
#     (старое поведение; файл будет перезаписан при выходе SketchUp).
# =============================================================================

require 'fileutils'
require 'json'
require 'tmpdir'

module Dn1supSaveSettings
  module Restorer
    extend self

    Result = Struct.new(:restored, :skipped, :errors, :deferred, :pending_dir,
                        :auto_backup_file, keyword_init: true)

    # zip_path — архив настроек; opts:
    #   auto_backup: true — перед восстановлением сохранить текущее состояние
    #                        тех путей, которые сейчас существуют (kind 'auto');
    #   keys: [...override] — восстановить только часть путей из архива
    #                         (по умолчанию все записанные в манифесте);
    #   relaunch: true — после отложенного применения запустить SketchUp снова
    #                     (передаётся в DeferredApply);
    #   defer_files: false — применить файлы настроек сразу, не откладывая;
    #   spawn: false — подготовить отложенное применение, но скрипт не
    #                  запускать (тесты).
    def restore!(zip_path, opts = {})
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Log.info("Восстановление из архива: #{File.basename(zip_path.to_s)}, пути=#{Array(opts[:keys]).inspect}, " \
               "авто-бэкап=#{opts[:auto_backup] != false}, отложенно=#{opts[:defer_files] != false}")
      manifest = Archiver.read_manifest(zip_path)
      raise Error, 'В архиве нет манифеста dn1sup_settings_manifest.json — это не архив настроек dn1sup' unless manifest

      wanted = select_targets(manifest, opts[:keys])
      raise Error, 'В архиве нет выбранных путей для восстановления' if wanted.empty?

      auto_entry = nil
      if opts[:auto_backup]
        current_keys = wanted.select { |t| File.exist?(Paths.resolve(t)) }.map { |t| t[:key] }
        if current_keys.any?
          auto_entry = Backup.create!(comment: 'Автоматически перед восстановлением',
                                      keys: current_keys, kind: 'auto')
        end
      end

      result = Result.new(restored: [], skipped: [], errors: [], deferred: [],
                          pending_dir: nil, auto_backup_file: nil)
      result.auto_backup_file = auto_entry['file'] if auto_entry

      defer_files = opts[:defer_files] != false
      file_targets, dir_targets = wanted.partition { |t| t[:kind] == 'file' }

      Dir.mktmpdir('dn1sup_rs_') do |tmp|
        Archiver.extract(zip_path, tmp)
        dir_targets.each do |t|
          src = File.join(tmp, t[:scope], t[:name])
          unless File.exist?(src)
            result.skipped << t[:name]
            next
          end
          begin
            copy_over!(src, t)
            result.restored << t[:name]
          rescue StandardError => e
            result.errors << "#{t[:name]}: #{e.message}"
            Log.exception(e, "восстановление каталога: #{t[:name]}")
          end
        end

        if defer_files
          entries = file_targets.filter_map do |t|
            src = File.join(tmp, t[:scope], t[:name])
            if File.file?(src)
              { target: t, src: src }
            else
              result.skipped << t[:name]
              nil
            end
          end
          unless entries.empty?
            result.pending_dir = DeferredApply.arm!(
              entries,
              archive: File.basename(zip_path.to_s),
              relaunch: opts[:relaunch] != false,
              auto_backup: opts[:auto_backup] != false,
              spawn_process: opts[:spawn] != false
            )
            result.deferred.concat(entries.map { |e| e[:target][:name] })
          end
        else
          file_targets.each do |t|
            src = File.join(tmp, t[:scope], t[:name])
            unless File.exist?(src)
              result.skipped << t[:name]
              next
            end
            begin
              copy_over!(src, t)
              result.restored << t[:name]
            rescue StandardError => e
              result.errors << "#{t[:name]}: #{e.message}"
              Log.exception(e, "восстановление файла: #{t[:name]}")
            end
          end
        end
      end
      Paths.reset_sizes!
      Log.info(format('Восстановление завершено: восстановлено %d, пропущено %d, отложено %d, ошибок %d (%.2f сек)',
                      result.restored.size, result.skipped.size, result.deferred.size,
                      result.errors.size,
                      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started))
      result.errors.each { |message| Log.error("Ошибка восстановления: #{message}") } unless result.errors.empty?
      result
    end

    private

    def select_targets(manifest, keys)
      wanted_keys = Array(keys)
      wanted_keys = Array(manifest['paths']) if wanted_keys.empty?
      Paths::TARGETS.select { |t| wanted_keys.include?(t[:key]) }
    end

    # Копирует распакованную цель поверх текущей (каталог — слиянием,
    # файл — перезаписью). Ошибка отдельной цели не останавливает остальные.
    def copy_over!(src, target)
      dst = Paths.resolve(target)
      if target[:kind] == 'dir'
        FileUtils.mkdir_p(dst)
        FileUtils.cp_r(File.join(src, '.'), dst)
      else
        FileUtils.mkdir_p(File.dirname(dst))
        FileUtils.rm(dst) if File.exist?(dst)
        FileUtils.cp(src, dst)
      end
    end
  end
end
