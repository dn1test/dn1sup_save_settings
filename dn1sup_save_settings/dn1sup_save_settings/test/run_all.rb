# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/test/run_all.rb — локальный запуск всех тестов
# (в обычном Ruby, без SketchUp). Тесты с tar.exe помечаются skip,
# если встроенный zip-движок недоступен.
# Запуск: ruby test/run_all.rb
# =============================================================================

require_relative 'test_helper'

Dir.glob(File.join(__dir__, '*_test.rb')).sort.each do |file|
  require file
end

report = Dn1supSaveSettings::Test.run!

puts '————————————————————————————————————'
puts "Тестов: #{report['total']}  Прошло: #{report['passed']}  " \
      "Провалено: #{report['failures'].size}  Пропущено: #{report['skipped'].size}  " \
      "за #{report['duration_ms']} мс"

report['failures'].each do |failure|
  puts "\n✗ #{failure['name']}\n  #{failure['error']}"
  Array(failure['backtrace']).each { |line| puts "    #{line}" }
end
report['skipped'].each { |s| puts "  ⊘ #{s['name']}: #{s['reason']}" }

exit(report['failures'].empty? ? 0 : 1)
