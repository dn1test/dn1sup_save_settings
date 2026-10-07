# frozen_string_literal: true
# Одноразовая функциональная проверка apply_restore.ps1 вне SketchUp:
# процесс-«двойник» SketchUp спит 4 секунды, скрипт должен дождаться его
# выхода, сделать страховочную копию текущих файлов и применить staged.
# Запускается и настоящий скрипт, и его трассированная копия.

require 'tmpdir'
require 'fileutils'
require 'open3'
require_relative '../dn1sup_save_settings/store'
require_relative '../dn1sup_save_settings/paths'
require_relative '../dn1sup_save_settings/deferred_apply'

D = Dn1supSaveSettings::DeferredApply
P = Dn1supSaveSettings::Paths

DEBUG_PS = <<~'PS'
  param([int]$SuPid = 0, [string]$PendingDir = '')
  Write-Host "step0: SuPid=$SuPid PendingDir=$PendingDir"
  $pendingFile = Join-Path $PendingDir 'pending.json'
  Write-Host "step1: pending exists = $(Test-Path -LiteralPath $pendingFile)"
  $proc = Get-Process -Id $SuPid -ErrorAction SilentlyContinue
  Write-Host "step2: proc found = $($null -ne $proc)"
  try { Wait-Process -Id $SuPid -Timeout 86400 -ErrorAction SilentlyContinue } catch { Write-Host "step3: wait threw: $($_.Exception.Message)" }
  Write-Host 'step3: wait done'
  $still = Get-Process -Id $SuPid -ErrorAction SilentlyContinue
  Write-Host "step4: still running = $($null -ne $still)"
  Write-Host "step5: pending exists = $(Test-Path -LiteralPath $pendingFile)"
  $cfg = $null
  try { $cfg = Get-Content -LiteralPath $pendingFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Host "step6: parse threw: $($_.Exception.Message)" }
  Write-Host "step7: cfg ok = $($null -ne $cfg); targets=$(@($cfg.targets).Count); relaunch=$($cfg.relaunch); auto=$($cfg.auto_backup)"
  Write-Host "step8: roots.local=$($cfg.roots.'local')"
  Write-Host "step9: roots.roaming=$($cfg.roots.'roaming')"
PS

Dir.mktmpdir do |root|
  roaming = File.join(root, 'roaming')
  local   = File.join(root, 'local')
  store   = File.join(root, 'store')
  FileUtils.mkdir_p([roaming, local, store])
  ENV['DN1SUP_SAVE_SETTINGS_ROAMING_ROOT'] = roaming
  ENV['DN1SUP_SAVE_SETTINGS_LOCAL_ROOT']   = local
  ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR']    = store

  # Текущее состояние — его скрипт должен убрать в pre_restore_*
  File.write(File.join(local, 'PrivatePreferences.json'), '{"current":1}')
  File.write(File.join(roaming, 'SharedPreferences.json'), '{"current":2}')

  src = File.join(root, 'src')
  FileUtils.mkdir_p(src)
  priv   = File.join(src, 'PrivatePreferences.json')
  shared = File.join(src, 'SharedPreferences.json')
  File.write(priv, '{"restored":1}')
  File.write(shared, '{"restored":2}')

  entries = [
    { target: P::TARGETS.find { |t| t[:key] == 'private_prefs' }, src: priv },
    { target: P::TARGETS.find { |t| t[:key] == 'shared_prefs' }, src: shared }
  ]
  dir = D.arm!(entries, archive: 't.zip', relaunch: false, auto_backup: true, spawn_process: false)
  puts "pending: #{dir}"
  puts "pending.json exists: #{File.file?(File.join(dir, 'pending.json'))}"

  dbg = File.join(dir, 'debug_steps.ps1')
  File.write(dbg, DEBUG_PS)

  sleeper = Process.spawn('powershell', '-NoProfile', '-Command', 'Start-Sleep -Seconds 4',
                          out: File::NULL, err: File::NULL)
  puts "двойник PID=#{sleeper}"

  puts '--- трассированная копия ---'
  out, err, _st = Open3.capture3('powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                                 '-File', dbg, '-SuPid', sleeper.to_s, '-PendingDir', dir)
  puts out
  puts "err: #{err.strip}" unless err.strip.empty?

  puts '--- настоящий скрипт ---'
  t0 = Time.now
  _out2, err2, st2 = Open3.capture3('powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                                    '-File', File.join(dir, 'apply_restore.ps1'),
                                    '-SuPid', sleeper.to_s, '-PendingDir', dir)
  Process.wait(sleeper) rescue nil
  puts "exit=#{st2.exitstatus} elapsed=#{(Time.now - t0).round(1)}s err=#{err2.strip.inspect}"

  puts "local   = #{File.read(File.join(local, 'PrivatePreferences.json')).strip}"
  puts "roaming = #{File.read(File.join(roaming, 'SharedPreferences.json')).strip}"
  result_path = File.join(dir, 'result.txt')
  if File.file?(result_path)
    puts '--- result.txt ---'
    puts File.read(result_path)
    puts '--- result через API ---'
    puts D.last_result.inspect
  else
    puts 'result.txt НЕ СОЗДАН'
  end
  stash = Dir.glob(File.join(dir, 'pre_restore_*'))
  puts "stash=#{stash.map { |d| [File.basename(d), Dir.children(d)] }.inspect}"

  ok = File.file?(result_path) &&
       File.read(File.join(local, 'PrivatePreferences.json')).include?('restored') &&
       File.read(File.join(roaming, 'SharedPreferences.json')).include?('restored') &&
       stash.size == 1
  puts(ok ? 'FUNCTIONAL OK' : 'FUNCTIONAL FAIL')
  exit(ok ? 0 : 1)
end
