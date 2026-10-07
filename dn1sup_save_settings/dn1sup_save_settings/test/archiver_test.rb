# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/test/archiver_test.rb — zip через встроенный tar.exe:
# создание (структура roaming/local + манифест + лог), чтение манифеста и
# лога архивации, распаковка.
# =============================================================================

require 'fileutils'
require 'tmpdir'
require 'open3'

module Dn1supSaveSettings
  module Test
    test 'archiver: встроенный tar.exe (bsdtar) доступен' do
      skip('tar.exe недоступен') unless Archiver.available?
    end

    test 'archiver: создание zip со структурой roaming/local и манифестом' do
      skip('tar.exe недоступен') unless Archiver.available?

      Dir.mktmpdir do |root|
        src = File.join(root, 'roaming_src')
        FileUtils.mkdir_p(File.join(src, 'Materials', 'sub'))
        File.write(File.join(src, 'Materials', 'a.txt'), 'mat')
        File.write(File.join(src, 'Materials', 'sub', 'b.txt'), 'sub')
        File.write(File.join(src, 'SharedPreferences.json'), 'prefs')

        zip = File.join(root, 'out.zip')
        Archiver.create({ 'app' => 'dn1sup_save_settings', 'paths' => %w[materials shared_prefs] },
                        [
                          { scope: 'roaming', name: 'Materials', src: File.join(src, 'Materials') },
                          { scope: 'roaming', name: 'SharedPreferences.json', src: File.join(src, 'SharedPreferences.json') }
                        ], zip)
        assert File.file?(zip), 'zip не создан'

        manifest = Archiver.read_manifest(zip)
        assert_equal 'dn1sup_save_settings', manifest['app']
        assert_equal %w[materials shared_prefs], manifest['paths']

        # Лог архивации: шапка, секции записей, построчный список файлов, итог.
        log = Archiver.read_log(zip)
        assert log.to_s.include?('dn1sup_save_settings — лог архивации'), 'в логе нет шапки'
        assert log.include?('[roaming] Materials — папка'), "нет секции папки: #{log}"
        assert log.include?('a.txt — 3'), "нет строки файла: #{log}"
        assert log.include?('[roaming] SharedPreferences.json — файл'), 'нет секции файла'
        assert log.include?('Итог: путей 2 · файлов 3'), "нет итога: #{log}"

        # Состав проверяем распаковкой: внутри SketchUp stdout дочерних
        # процессов пуст, поэтому tar -tf там не работает.
        Dir.mktmpdir do |tmp|
          Archiver.extract(zip, tmp)
          entries = Dir.glob(File.join(tmp, '**', '*'))
                       .map { |p| p.sub(tmp + '/', '').tr('\\', '/') }
                       .reject { |p| File.directory?(p) }
                       .sort
          assert entries.include?('roaming/Materials/a.txt'), "нет записи: #{entries.inspect}"
          assert entries.include?('roaming/Materials/sub/b.txt'), 'рекурсивное содержимое потеряно'
          assert entries.include?('roaming/SharedPreferences.json')
          assert entries.include?(Archiver::MANIFEST_NAME)
          assert entries.include?(Archiver::LOG_NAME), 'лог архивации не попал в архив'
          assert_equal 'sub', File.read(File.join(tmp, 'roaming', 'Materials', 'sub', 'b.txt'))
        end
      end
    end

    test 'archiver: распаковка и чтение манифеста' do
      skip('tar.exe недоступен') unless Archiver.available?

      Dir.mktmpdir do |root|
        src = File.join(root, 'local_src')
        FileUtils.mkdir_p(src)
        File.write(File.join(src, 'PrivatePreferences.json'), '{"pref":1}')

        zip = File.join(root, 'out.zip')
        Archiver.create({ 'created_at' => '2026-10-06 12:00:00' },
                        [{ scope: 'local', name: 'PrivatePreferences.json', src: File.join(src, 'PrivatePreferences.json') }], zip)

        Dir.mktmpdir do |tmp|
          Archiver.extract(zip, tmp)
          assert_equal '{"pref":1}', File.read(File.join(tmp, 'local', 'PrivatePreferences.json'))
          assert File.file?(File.join(tmp, Archiver::MANIFEST_NAME))
        end

        manifest = Archiver.read_manifest(zip)
        assert_equal '2026-10-06 12:00:00', manifest['created_at']
        assert_nil Archiver.read_manifest(File.join(root, 'missing.zip')), 'чужой/отсутствующий архив → nil'
      end
    end

    test 'archiver: лог архивации — чтение и отсутствие в старом формате' do
      skip('tar.exe недоступен') unless Archiver.available?

      Dir.mktmpdir do |root|
        src = File.join(root, 'src')
        FileUtils.mkdir_p(src)
        File.write(File.join(src, 'x.rb'), 'x=1')

        zip = File.join(root, 'with_log.zip')
        Archiver.create({ 'created_at' => '2026-10-06 12:00:00' },
                        [{ scope: 'roaming', name: 'Plugins', src: src }], zip)
        log = Archiver.read_log(zip)
        assert log.to_s.include?('dn1sup_save_settings — лог архивации'), 'в логе нет шапки'
        assert log.include?('[roaming] Plugins — папка'), "нет секции записи: #{log}"
        assert log.include?('x.rb — 3'), "нет строки файла: #{log}"

        # Архив старого формата (без лога) — собирается tar-ом вручную.
        Dir.mktmpdir do |tmp|
          File.write(File.join(tmp, 'whatever.txt'), 'no log here')
          old_zip = File.join(root, 'old.zip')
          _out, _err, st = Open3.capture3('tar', '-acf', old_zip, '-C', tmp, 'whatever.txt')
          assert st.success?, 'не удалось собрать тестовый zip без лога'
          assert_nil Archiver.read_log(old_zip), 'архив без лога → nil'
        end

        assert_nil Archiver.read_log(File.join(root, 'missing.zip')), 'отсутствующий архив → nil'
      end
    end
  end
end
