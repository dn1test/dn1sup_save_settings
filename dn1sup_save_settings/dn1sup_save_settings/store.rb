# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/store.rb — хранилище расширения: %APPDATA%/SketchUp/
# «SketchUp <год>»/dn1sup_save_settings. Каталог — СОСЕДЬ бэкапируемого
# «…\SketchUp 202x\SketchUp\», поэтому архив не захватывает сам себя.
# =============================================================================

require 'fileutils'

module Dn1supSaveSettings
  module Store
    extend self

    DIR_NAME = 'dn1sup_save_settings'

    def dir
      custom = ENV['DN1SUP_SAVE_SETTINGS_STORE_DIR']
      return custom.tr('\\', '/').sub(%r{/+\z}, '') if custom && !custom.empty?

      File.join(data_root, DIR_NAME)
    end

    def backups_dir
      custom = Settings.archive_dir
      return custom unless custom.empty?

      default_backups_dir
    end

    # Стандартная папка архивов внутри хранилища.
    def default_backups_dir
      File.join(dir, 'backups')
    end

    def ensure_dirs!
      FileUtils.mkdir_p(backups_dir)
      backups_dir
    end

    # Папки, в которых разрешена работа с архивами: активная + стандартная.
    # Архивы, созданные до смены папки, остаются доступны.
    def archive_search_dirs
      [backups_dir, default_backups_dir].uniq
    end

    # Полный путь архива по имени: ищется в активной папке, затем в стандартной;
    # если файла нет нигде — путь в активной папке (для сообщений об ошибке).
    def resolve_archive(file_name)
      name = File.basename(file_name.to_s)
      found = archive_search_dirs.map { |d| File.join(d, name) }.find { |p| File.file?(p) }
      found || File.join(backups_dir, name)
    end

    # Каталог пользователя SketchUp: %APPDATA%/SketchUp/SketchUp <год>.
    # Надёжный источник — путь Plugins из самого SketchUp; при недоступности —
    # номер версии: у 2021+ major-версия равна году − 2000 (26.2 → «SketchUp 2026»).
    def data_root
      if defined?(Sketchup) && Sketchup.respond_to?(:find_support_file)
        plugins = Sketchup.find_support_file('Plugins')
        if plugins && !plugins.empty?
          root = File.expand_path('../..', plugins) # Plugins → «SketchUp 2026»
          return root if File.basename(root).start_with?('SketchUp')
        end
      end

      appdata = ENV['APPDATA'] || Dir.home
      major = defined?(Sketchup) && Sketchup.respond_to?(:version) ? Sketchup.version.to_i : 26
      year = major >= 1000 ? major : 2000 + major
      File.join(appdata, 'SketchUp', "SketchUp #{year}")
    end
  end
end
