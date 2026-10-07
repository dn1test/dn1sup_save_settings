# frozen_string_literal: true

# -------------------------------------------------------------------------------
# Standalone CLI Script: Обновление DN1SUP Save Settings из dev-папки в SketchUp Plugins
# Запуск:
#   ruby update_from_dev.rb
# -------------------------------------------------------------------------------

require_relative 'dn1sup_save_settings/dn1sup_save_settings/dev_updater'
require 'net/http'
require 'json'

puts '=========================================================='
puts '  DN1SUP Save Settings — Обновление из dev-папки'
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
bridge_port = 9877
begin
  uri = URI("http://127.0.0.1:#{bridge_port}/eval")
  ruby_code = <<~RUBY
    if defined?(Dn1supSaveSettings::DevUpdater)
      Dn1supSaveSettings::DevUpdater.reload!
    else
      load File.join(Sketchup.find_support_file("Plugins"), "dn1sup_save_settings.rb")
    end
  RUBY

  req = Net::HTTP::Post.new(uri)
  req['Content-Type'] = 'application/json'
  req.body = JSON.generate({ code: ruby_code })

  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = 1.0
  http.read_timeout = 15.0
  response = http.request(req)

  if response.is_a?(Net::HTTPSuccess)
    puts "  ⚡ SketchUp обнаружен (порт #{bridge_port}): плагин успешно перезагружен на лету!"
  else
    puts "  ⚡ SketchUp ответил (код #{response.code}), расширение обновлено в Plugins."
  end
rescue Errno::ECONNREFUSED, Net::OpenTimeout, StandardError
  puts "  ℹ️  SketchUp dev-мост не запущен на порту #{bridge_port}."
  puts "     Файлы в каталоге Plugins обновлены. При следующем открытии SketchUp"
  puts "     или через меню 'Extensions -> DN1SUP -> Save Settings -> Обновить из dev-папки' изменения вступят в силу."
end

puts "\nГотово!"
