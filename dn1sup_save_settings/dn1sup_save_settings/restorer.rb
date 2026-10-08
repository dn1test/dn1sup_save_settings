# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/restorer.rb — восстановление параметров из архива:
# манифест → (по желанию) автобэкап текущего состояния → распаковка во
# временную папку → применение.
#
# Всё применение — ОТЛОЖЕННОЕ (DeferredApply, отсоединённый helper):
# SketchUp держит настройки в памяти и перезаписывает их при выходе,
# а файлы плагинов (нативные .so/.dll) держит открытыми — попытка копировать
# каталоги в работающем SketchUp падает на первом занятом файле (EACCES на
# загруженной библиотеке). Поэтому и файлы настроек, и каталоги применяются
# сразу после закрытия SketchUp, после чего он запускается снова.
# defer_files: false — старое поведение «копировать сразу»: работает для
# отладки, но каталоги могут восстановиться частично (занятые файлы).
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
    #   defer_files: false — применить сразу, не откладывая (старое поведение;
    #                  файл настроек будет перезаписан при выходе SketchUp,
    #                  каталоги — с риском частичного восстановления);
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

      Dir.mktmpdir('dn1sup_rs_') do |tmp|
        Archiver.extract(zip_path, tmp)

        if opts[:defer_files] != false
          defer_all!(wanted, tmp, result, zip_path, opts)
        else
          apply_now!(wanted, tmp, result)
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

    # Обычный сценарий: ВСЕ цели (каталоги и файлы настроек) уходят в
    # отложенное применение — helper применит их после закрытия SketchUp.
    def defer_all!(wanted, tmp, result, zip_path, opts)
      entries = wanted.filter_map do |t|
        src = File.join(tmp, t[:scope], t[:name])
        exists = t[:kind] == 'dir' ? File.directory?(src) : File.file?(src)
        unless exists
          result.skipped << t[:name]
          next nil
        end
        { target: t, src: src }
      end
      return if entries.empty?

      result.pending_dir = DeferredApply.arm!(
        entries,
        archive: File.basename(zip_path.to_s),
        relaunch: opts[:relaunch] != false,
        auto_backup: opts[:auto_backup] != false,
        spawn_process: opts[:spawn] != false
      )
      result.deferred.concat(entries.map { |e| e[:target][:name] })
    end

    # Старое поведение (defer_files: false): копировать сразу. Ошибка одной
    # цели не останавливает остальные.
    def apply_now!(wanted, tmp, result)
      wanted.each do |t|
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
          Log.exception(e, "восстановление цели: #{t[:name]}")
        end
      end
    end

    # Копирует распакованную цель поверх текущей (каталог — слиянием,
    # файл — перезаписью).
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
