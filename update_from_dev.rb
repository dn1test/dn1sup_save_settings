# frozen_string_literal: true

# -------------------------------------------------------------------------------
# Standalone CLI Script: Обновление DN1Sup Save Settings из dev-папки в SketchUp Plugins
# Запуск:
#   ruby update_from_dev.rb
# -------------------------------------------------------------------------------

require_relative 'dn1sup_save_settings/dn1sup_save_settings/dev_updater'
require 'json'
require 'socket'

puts '=========================================================='
puts '  DN1Sup Save Settings — Обновление из dev-папки'
puts '=========================================================='

dev_dir = ARGV[0] || File.expand_path(__dir__)
plugins_dir = ARGV[1]

puts '[1/3] Поиск каталогов...'
src = Dn1supSaveSettings::DevUpdater.resolve_dev_dir(dev_dir)
dst = Dn1supSaveSettings::DevUpdater.resolve_plugins_dir(plugins_dir)

puts "  • Dev папка:     #{src || '(не найдена)'}"
puts "  • Plugins папка: #{dst || '(не найдена)'}"

unless src && Dir.exist?(src)
  warn "ОШИБКА: Исходный каталог разработки не найден: #{dev_dir}"
  exit 1
end

unless dst && Dir.exist?(dst)
  warn "ОШИБКА: Целевой каталог Plugins SketchUp не найден: #{dst}"
  exit 1
end

puts "\n[2/3] Копирование файлов расширения..."
res = Dn1supSaveSettings::DevUpdater.update!(src, dst)

if res['success']
  if res['same_dir']
    puts '  ℹ️  Каталоги совпадают: расширение работает напрямую из dev-папки.'
  else
    puts "  ✅ Скопировано файлов: #{res['files_copied']}"
    puts "  ✅ Дата обновления:    #{res['updated_at']}"
    if res['warnings'] && !res['warnings'].empty?
      puts "  ⚠️ Предупреждения:     #{res['warnings'].join('; ')}"
    end
  end
else
  warn "  ❌ Ошибка копирования: #{res['error']}"
  exit 1
end

puts "\n[3/3] Проверка запущенного SketchUp и горячая перезагрузка..."
# Мост dn1sup_mcp2 слушает 127.0.0.1:9877 по TCP newline-JSON (НЕ HTTP):
# один запрос = одно соединение, одна строка JSON с "\n", ответ — одна строка JSON.
# Команды: eval | status | ping | stop. HTTP POST /eval мост не понимает —
# такой запрос всегда уходил в ложное "мост не запущен", хотя SketchUp работал.
bridge_port = 9877
begin
  ruby_code = <<~RUBY
    if defined?(Dn1supSaveSettings::DevUpdater)
      Dn1supSaveSettings::DevUpdater.reload!
    else
      load File.join(Sketchup.find_support_file("Plugins"), "dn1sup_save_settings.rb")
    end
  RUBY

  request = JSON.generate({ id: rand(1..1_000_000_000), cmd: "eval", code: ruby_code }) + "\n"

  sock = Socket.tcp("127.0.0.1", bridge_port, connect_timeout: 2)
  sock.write(request)
  line = nil
  line = sock.gets if IO.select([sock], nil, nil, 15.0)
  sock.close

  if line
    resp = (JSON.parse(line) rescue {})
    err = resp["error"] || resp["backtrace"]
    if err
      puts "  ⚠️  SketchUp ответил с ошибкой: #{err}"
      puts "     Файлы в каталоге Plugins обновлены — перезагрузите расширение вручную."
    else
      puts "  ⚡ SketchUp обнаружен (порт #{bridge_port}): плагин успешно перезагружен на лету!"
    end
  else
    puts "  ⚠️  Мост на порту #{bridge_port} закрыл соединение без ответа."
    puts "     Файлы в каталоге Plugins обновлены — перезагрузите расширение вручную."
  end
rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, SocketError
  puts "  ℹ️  SketchUp-мост не отвечает на порту #{bridge_port} (SketchUp закрыт?)."
  puts "     Файлы в каталоге Plugins обновлены. При следующем открытии SketchUp"
  puts "     или через меню 'Extensions -> DN1Sup -> Save Settings -> Обновить из dev-папки' изменения вступят в силу."
rescue StandardError => e
  puts "  ⚠️  Hot Reload не удался (#{e.class}: #{e.message})."
  puts "     Файлы в каталоге Plugins обновлены — перезагрузите расширение вручную."
end

puts "\nГотово!"
