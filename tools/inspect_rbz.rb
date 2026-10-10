#!/usr/bin/env ruby
# frozen_string_literal: true

# tools/inspect_rbz.rb — контроль содержимого собранного .rbz (read-only).
#   ruby tools/inspect_rbz.rb dist/dn1sup_save_settings-0.12.3.rbz

data = File.binread(ARGV[0])

def entries(data)
  list = []
  idx = 0
  while (i = data.index("PK\x01\x02", idx))
    name_len = data[i + 28, 2].unpack1('v')
    list << data[i + 46, name_len]
    idx = i + 4
  end
  list
end

# Тело файла из local file header (pack.rb пишет STORE — тело лежит как есть).
def entry_body(data, wanted)
  idx = 0
  while (i = data.index("PK\x03\x04", idx))
    name_len = data[i + 26, 2].unpack1('v')
    extra_len = data[i + 28, 2].unpack1('v')
    name = data[i + 30, name_len]
    size = data[i + 18, 4].unpack1('V')
    body = data[i + 30 + name_len + extra_len, size]
    return body if name == wanted

    idx = i + 4
  end
  nil
end

list = entries(data)
puts list.sort
puts '--- structure ---'
puts 'dev_manifest_absent=' + (list.none? { |n| n.downcase.include?('.sketchup_dev.json') } ? 'OK' : 'FAIL')
puts 'dev_updater_absent=' + (list.none? { |n| n.downcase.include?('dev_updater') } ? 'OK' : 'FAIL')
puts 'updater_present=' + (list.any? { |n| n.end_with?('dn1sup_updater.rb') } ? 'OK' : 'FAIL')
puts 'registry_present=' + (list.any? { |n| n.end_with?('registry.json') } ? 'OK' : 'FAIL')
puts 'loader_root=' + (list.include?('dn1sup_save_settings.rb') ? 'OK' : 'FAIL')

puts '--- contents ---'
up = entry_body(data, 'dn1sup_save_settings/dn1sup_updater.rb')
ld = entry_body(data, 'dn1sup_save_settings.rb')
rg = entry_body(data, 'dn1sup_save_settings/registry.json')
puts 'updater_new(dev_install?)=' + (up.to_s.include?('def dev_install?') ? 'OK' : 'FAIL')
puts 'updater_new(repo_meta)=' + (up.to_s.include?('def repo_meta') ? 'OK' : 'FAIL')
puts 'updater_new(log_rotation_fix)=' + (up.to_s.include?('File.delete(old) if File.file?(old)') ? 'OK' : 'FAIL')
puts "loader_version=" + (ld.to_s[/ext\.version\s*=\s*'([^']+)'/, 1] || '?')
require 'json'
puts "registry_version=" + (JSON.parse(rg).first['version'] rescue '?')
