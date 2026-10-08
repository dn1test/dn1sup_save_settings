# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/deferred_apply.rb — отложенное применение изменений
# настроек: восстановление файлов из архива (arm!) и сброс к заводскому
# состоянию (arm_reset!).
#
# SketchUp держит настройки в памяти и ПЕРЕЗАПИСЫВАЕТ оба JSON-файла при
# выходе (и по отдельным событиям сессии), а файлы плагинов держит
# открытыми, поэтому менять их в запущенном SketchUp бессмысленно —
# изменения затираются или блокируются. arm! складывает файл-цели архива
# в pending-папку хранилища и запускает ОТСОЕДИНЁННЫЙ PowerShell-скрипт,
# который:
#   1) запоминает путь SketchUp.exe (пока процесс жив);
#   2) опросом Get-Process дожидается закрытия SketchUp (именно после
#      выхода файлы на диске — финальное состояние);
#   3) делает страховочную копию текущих файлов в pre_restore_<штамп>/;
#   4) выполняет действия по каждой цели: copy — копирует файл из staged
#      в каталоги SketchUp (Local/Roaming); delete_file — удаляет файл
#      (сброс интерфейса); clear_dir — очищает содержимое каталога
#      (сброс плагинов: сам каталог остаётся, а элементы из списка keep
#      цели — файлы самого расширения — не удаляются);
#   5) пишет result.txt (ok|error) и опционально запускает SketchUp снова.
# Отмена (cancel!) удаляет pending-папку: скрипт, не найдя pending.json,
# выходит, ничего не меняя. Повторный arm!/arm_reset! пересоздаёт папку.
# =============================================================================

require 'json'
require 'fileutils'

module Dn1supSaveSettings
  module DeferredApply
    extend self

    PENDING_DIR_NAME = 'pending_restore'
    PENDING_FILE     = 'pending.json'
    SCRIPT_NAME      = 'apply_restore.ps1'
    RESULT_FILE      = 'result.txt'

    # Действие по виду цели: файл настроек удаляется целиком (сброс интерфейса
    # — SketchUp создаст его заново с заводскими значениями), содержимое
    # каталога очищается (сброс плагинов; собственные файлы расширения
    # передаются в keep и не удаляются), обычное восстановление копирует
    # staged-файл поверх.
    RESET_ACTION_BY_KIND = { 'file' => 'delete_file', 'dir' => 'clear_dir' }.freeze

    # entries — массив { target: <хэш Paths::TARGETS>, src: <файл для copy>,
    #                    action: 'copy'|'delete_file'|'clear_dir' (по умолчанию copy) }.
    # opts:
    #   archive:      имя архива — только для отображения в состоянии;
    #   relaunch:     true — после применения запустить SketchUp снова;
    #   auto_backup:  true — скрипт перед копированием сохранит текущие файлы
    #                     в pre_restore_<штамп>/ внутри pending-папки;
    #   spawn_process: false — только подготовка (тесты), скрипт не запускать.
    # Возвращает путь pending-папки.
    def arm!(entries, archive: '', relaunch: true, auto_backup: true, spawn_process: true)
      arm_entries(entries, kind: 'restore', archive: archive, relaunch: relaunch,
                           auto_backup: auto_backup, spawn_process: spawn_process)
    end

    # Подготовка сброса целей к заводскому состоянию (после закрытия SketchUp):
    # файл настроек будет удалён, содержимое каталога — очищено. Принимает
    # одну цель или массив («Сбросить всё»). Резервную копию перед сбросом
    # создаёт вызывающий код (принудительно).
    # При сбросе плагинов из очистки исключаются собственные файлы
    # расширения (keep) — оно остаётся в меню после сброса.
    def arm_reset!(target, relaunch: true, spawn_process: true)
      # Hash в Array не оборачивается, а разбирается на пары — только явная
      # проверка вида.
      targets = target.is_a?(Array) ? target : [target]
      entries = targets.map do |t|
        action = RESET_ACTION_BY_KIND.fetch(t[:kind]) do
          raise Error, "Неподдерживаемый вид цели для сброса: #{t[:kind]}"
        end
        entry = { target: t, action: action }
        entry[:keep] = self_keep_names if action == 'clear_dir' && t[:key] == 'plugins'
        entry
      end
      arm_entries(entries, kind: 'reset', archive: '',
                  relaunch: relaunch, auto_backup: false, spawn_process: spawn_process)
    end

    # Отменяет отложенное применение (пока SketchUp ещё работает).
    def cancel!
      return false unless File.directory?(pending_dir)

      FileUtils.rm_rf(pending_dir)
      true
    end

    def pending?
      !read_config.nil?
    end

    # Состояние для интерфейса: активная отложенная задача и/или результат
    # прошлого применения. nil — ничего нет.
    def state
      config = read_config
      return nil unless config

      {
        'kind' => config['kind'] == 'reset' ? 'reset' : 'restore',
        'created_at' => config['created_at'].to_s,
        'archive' => config['archive'].to_s,
        'labels' => Array(config['targets']).map { |t| t['label'] },
        # false = задача осталась от прошлой сессии без result.txt:
        # helper не сработал (заблокирован политиками/антивирусом).
        'from_current_session' => config['su_pid'] == Process.pid,
        'result' => last_result
      }
    rescue StandardError
      nil
    end

    # Результат прошлого применения (result.txt пишет скрипт): nil — его нет.
    # Результат логируется один раз — при первом чтении (state вызывается при
    # каждом обновлении интерфейса); ошибки helper'а, отработавшего после
    # выхода SketchUp, попадают в журнал следующей сессии.
    def last_result
      path = File.join(pending_dir, RESULT_FILE)
      return nil unless File.file?(path)

      lines = File.readlines(path, encoding: 'UTF-8')
                  .map { |line| line.gsub("\uFEFF", '').strip }
                  .reject(&:empty?)
      return nil if lines.empty?

      status = lines.shift
      result = { 'status' => status == 'ok' ? 'ok' : 'error',
                 'finished' => lines.shift.to_s.sub(/\Afinished\s+/, ''),
                 'lines' => lines }
      log_applied_result(result)
      result
    rescue StandardError
      nil
    end

    # Убирает показанный результат (после нажатия «OK» в интерфейсе).
    def clear_result!
      FileUtils.rm_f(File.join(pending_dir, RESULT_FILE))
      true
    end

    def pending_dir
      File.join(Store.dir, PENDING_DIR_NAME)
    end

    private

    def arm_entries(entries, kind:, archive:, relaunch:, auto_backup:, spawn_process:)
      raise Error, 'Отложенное применение доступно только в Windows' unless win?

      prepared = Array(entries).map { |e| normalize_entry(e) }
      raise Error, 'Нет файлов настроек для отложенного применения' if prepared.empty?

      dir = pending_dir
      FileUtils.rm_rf(dir) # повторный arm!/arm_reset! заменяет подготовленную задачу
      staged = File.join(dir, 'staged')
      FileUtils.mkdir_p(staged)

      prepared.each do |entry|
        next unless entry[:action] == 'copy'

        t = entry[:target]
        dest = File.join(staged, t[:scope].to_s, t[:name])
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(entry[:src], dest)
      end

      config = {
        'app'              => 'dn1sup_save_settings',
        'pending_version'  => 1,
        'kind'             => kind.to_s,
        'created_at'       => Time.now.strftime('%Y-%m-%d %H:%M:%S'),
        'su_pid'           => Process.pid,
        'su_version'       => Paths.su_version,
        'archive'          => archive.to_s,
        'relaunch'         => relaunch ? true : false,
        'auto_backup'      => auto_backup ? true : false,
        'roots'            => { 'local' => Paths.local_root, 'roaming' => Paths.roaming_root },
        'targets'          => prepared.map do |entry|
          t = entry[:target]
          item = { 'key' => t[:key], 'scope' => t[:scope].to_s, 'name' => t[:name],
                   'label' => t[:label].to_s, 'action' => entry[:action] }
          item['keep'] = entry[:keep] if entry[:keep]
          item
        end
      }
      File.write(File.join(dir, PENDING_FILE), JSON.pretty_generate(config))
      File.write(File.join(dir, SCRIPT_NAME), SCRIPT)

      Log.info("Подготовлено отложенное применение: kind=#{kind}, цели=#{prepared.map { |e| e[:target][:name] }.join(', ')}, " \
               "relaunch=#{relaunch}, запуск helper=#{spawn_process}")
      launch_script!(dir) if spawn_process
      dir
    end

    # Нормализует запись задачи: action по умолчанию 'copy'; копировать можно
    # только файлы настроек с существующим src, удаление/очистка не требуют
    # staged-файла. keep (имена внутри очищаемого каталога, которые нельзя
    # удалять) имеет смысл только для clear_dir.
    def normalize_entry(entry)
      action = entry[:action] || 'copy'
      unless %w[copy delete_file clear_dir].include?(action)
        raise Error, "Неизвестное действие отложенного применения: #{action}"
      end

      if action == 'copy'
        unless entry[:target][:kind] == 'file'
          raise Error, "Отложенно копировать можно только файлы настроек: #{entry[:target][:name]}"
        end
        src = entry[:src].to_s
        raise Error, 'Нет файлов настроек для отложенного применения' unless File.file?(src)

        { target: entry[:target], action: action, src: src }
      else
        item = { target: entry[:target], action: action }
        keep = Array(entry[:keep]).map(&:to_s).reject(&:empty?).uniq.sort
        item[:keep] = keep unless keep.empty?
        item
      end
    end

    # Имена собственных файлов расширения в папке Plugins: регистратор и
    # пакет. Вычисляется по факту вызова — при загрузке файла константа ID
    # ещё не определена (порядок require в main.rb).
    def self_keep_names
      id = defined?(Dn1supSaveSettings::ID) ? Dn1supSaveSettings::ID : 'dn1sup_save_settings'
      [id, "#{id}.rb"]
    end

    def read_config
      path = File.join(pending_dir, PENDING_FILE)
      return nil unless File.file?(path)

      data = JSON.parse(File.read(path, encoding: 'UTF-8'))
      data.is_a?(Hash) && data['pending_version'] ? data : nil
    rescue StandardError
      nil
    end

    # Повторные чтения одного и того же result.txt (каждое обновление
    # интерфейса) в журнал не пишутся — только первый.
    def log_applied_result(result)
      finished = result['finished'].to_s
      return if finished.empty? || finished == @last_logged_result

      @last_logged_result = finished
      summary = result['lines'].join('; ')
      if result['status'] == 'ok'
        Log.info("Отложенное применение выполнено (#{finished}): #{summary}")
      else
        Log.error("Отложенное применение — ОШИБКА (#{finished}): #{summary}")
      end
    end

    def launch_script!(dir)
      script = File.join(dir, SCRIPT_NAME)
      # Полный путь к Windows PowerShell 5.1 — как у tar.exe в archiver.rb,
      # детерминированно вместо поиска по PATH.
      ps = File.join(ENV['SystemRoot'] || ENV['WINDIR'] || 'C:\\Windows',
                     'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe').tr('/', '\\')
      args = [ps, '-NoProfile', '-ExecutionPolicy', 'Bypass',
              '-WindowStyle', 'Hidden', '-File', script,
              '-SuPid', Process.pid.to_s, '-PendingDir', dir]
      # WinProcess.run_detached: скрытый запуск без ожидания. Отдельная
      # группа процессов из прежнего new_pgroup не нужна — у консольного
      # ребёнка GUI-процесса и так своя консоль, а дочерние процессы Windows
      # при выходе SketchUp не убивает. Вывод в NUL не нужен: он не читается.
      return true if WinProcess.run_detached(*args)

      raise Error, 'Не удалось запустить helper отложенного применения'
    end

    def win?
      defined?(Gem) && Gem.respond_to?(:win_platform?) ? Gem.win_platform? : RUBY_PLATFORM =~ /mswin|mingw/
    end

    # -- apply_restore.ps1 -------------------------------------------------------
    # Только ASCII (кодировка скрипта не важна) и без тернарников/операторов
    # PS7: в SketchUp используется Windows PowerShell 5.1.
    SCRIPT = <<~'PS'
      param(
          [int]$SuPid = 0,
          [string]$PendingDir = ''
      )

      $ErrorActionPreference = 'Continue'
      $pendingFile = Join-Path $PendingDir 'pending.json'
      if (-not (Test-Path -LiteralPath $pendingFile)) { exit 0 }

      # Remember the SketchUp executable while the process still runs.
      $suExe = $null
      $proc = Get-Process -Id $SuPid -ErrorAction SilentlyContinue
      if ($proc) {
          $suExe = $proc.Path
          if (-not $suExe) {
              try { $suExe = $proc.MainModule.FileName } catch { $suExe = $null }
          }
      }

      # Wait for SketchUp to exit: it rewrites the preference files at exit,
      # so they can only be replaced afterwards. Polling: Wait-Process
      # -Timeout accepts at most 32767 seconds, we need a full day.
      $deadline = (Get-Date).AddSeconds(86400)
      while ((Get-Date) -lt $deadline) {
          if (-not (Get-Process -Id $SuPid -ErrorAction SilentlyContinue)) { break }
          Start-Sleep -Milliseconds 500
      }
      if (Get-Process -Id $SuPid -ErrorAction SilentlyContinue) { exit 0 }
      if (-not (Test-Path -LiteralPath $pendingFile)) { exit 0 }

      $cfg = $null
      try { $cfg = Get-Content -LiteralPath $pendingFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
      if (-not $cfg) { exit 1 }

      $ok = $true
      $lines = New-Object System.Collections.Generic.List[string]

      try {
          if ($cfg.auto_backup) {
              $stash = Join-Path $PendingDir ('pre_restore_' + (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
              New-Item -ItemType Directory -Force -Path $stash | Out-Null
              foreach ($t in @($cfg.targets)) {
                  $root = $cfg.roots.($t.scope)
                  $dst = Join-Path $root $t.name
                  if (Test-Path -LiteralPath $dst) {
                      Copy-Item -LiteralPath $dst -Destination (Join-Path $stash $t.name) -Recurse -Force
                      $lines.Add('backup ' + $t.name)
                  }
              }
          }

          foreach ($t in @($cfg.targets)) {
              try {
                  $root = $cfg.roots.($t.scope)
                  $dst = Join-Path $root $t.name
                  $action = 'copy'
                  if ($t.PSObject.Properties['action'] -and $t.action) { $action = [string]$t.action }
                  if ($action -eq 'delete_file') {
                      if (Test-Path -LiteralPath $dst) {
                          Remove-Item -LiteralPath $dst -Force
                          $lines.Add('ok ' + $t.name + ' deleted')
                      } else {
                          $lines.Add('ok ' + $t.name + ' absent')
                      }
                  } elseif ($action -eq 'clear_dir') {
                      if (Test-Path -LiteralPath $dst) {
                          # keep: names inside the directory that must survive
                          # the reset (the Save Settings extension itself).
                          $keep = @()
                          if ($t.PSObject.Properties['keep']) { $keep = @($t.keep) }
                          $kept = 0
                          Get-ChildItem -LiteralPath $dst -Force | ForEach-Object {
                              if ($keep -contains $_.Name) {
                                  $kept++
                              } else {
                                  Remove-Item -LiteralPath $_.FullName -Recurse -Force
                              }
                          }
                          if ($kept -gt 0) {
                              $lines.Add('ok ' + $t.name + ' cleared, kept ' + $kept + ' items')
                          } else {
                              $lines.Add('ok ' + $t.name + ' cleared')
                          }
                      } else {
                          $lines.Add('ok ' + $t.name + ' absent')
                      }
                  } else {
                      $src = Join-Path (Join-Path $PendingDir 'staged') (Join-Path $t.scope $t.name)
                      New-Item -ItemType Directory -Force -Path $root | Out-Null
                      Copy-Item -LiteralPath $src -Destination $dst -Force
                      $lines.Add('ok ' + $t.name)
                  }
              } catch {
                  $ok = $false
                  $lines.Add('fail ' + $t.name + ' : ' + $_.Exception.Message)
              }
          }
      } catch {
          $ok = $false
          $lines.Add('fail : ' + $_.Exception.Message)
      }

      $status = 'error'
      if ($ok) { $status = 'ok' }
      $lines.Insert(0, 'finished ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
      $lines.Insert(0, $status)
      Set-Content -LiteralPath (Join-Path $PendingDir 'result.txt') -Value $lines -Encoding UTF8

      if ($cfg.relaunch -and $suExe -and (Test-Path -LiteralPath $suExe)) {
          Start-Process -FilePath $suExe
      }
    PS
  end
end
