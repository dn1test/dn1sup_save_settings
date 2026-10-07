# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/paths.rb — 7 путей настроек SketchUp, подлежащих
# сохранению (см. AGENTS.md):
#   Local : %LOCALAPPDATA%\SketchUp\SketchUp 202x\SketchUp\PrivatePreferences.json
#   Roaming: %APPDATA%\SketchUp\SketchUp 202x\SketchUp\
#            Components, Materials, Plugins, Styles, Templates,
#            SharedPreferences.json
#
# Для тестов вне SketchUp корни переопределяются переменными окружения
# DN1SUP_SAVE_SETTINGS_ROAMING_ROOT / DN1SUP_SAVE_SETTINGS_LOCAL_ROOT.
# =============================================================================

module Dn1supSaveSettings
  module Paths
    extend self

    TARGETS = [
      { key: 'private_prefs', scope: 'local',   kind: 'file', name: 'PrivatePreferences.json',
        label: 'Настройки интерфейса (PrivatePreferences.json)' },
      { key: 'shared_prefs',  scope: 'roaming', kind: 'file', name: 'SharedPreferences.json',
        label: 'Системные настройки (SharedPreferences.json)' },
      { key: 'components', scope: 'roaming', kind: 'dir', name: 'Components', label: 'Компоненты (Components)' },
      { key: 'materials',  scope: 'roaming', kind: 'dir', name: 'Materials',  label: 'Материалы (Materials)' },
      { key: 'plugins',    scope: 'roaming', kind: 'dir', name: 'Plugins',    label: 'Расширения (Plugins)' },
      { key: 'styles',     scope: 'roaming', kind: 'dir', name: 'Styles',     label: 'Стили (Styles)' },
      { key: 'templates',  scope: 'roaming', kind: 'dir', name: 'Templates',  label: 'Шаблоны (Templates)' }
    ].freeze

    DEFAULT_KEYS = TARGETS.map { |t| t[:key] }.freeze

    # -- корни Local/Roaming ------------------------------------------------------

    def roaming_root
      custom = ENV['DN1SUP_SAVE_SETTINGS_ROAMING_ROOT']
      return custom.tr('\\', '/').sub(%r{/+\z}, '') if custom && !custom.empty?

      if defined?(Sketchup) && Sketchup.respond_to?(:find_support_file)
        plugins = Sketchup.find_support_file('Plugins')
        if plugins && !plugins.empty?
          root = File.expand_path('..', plugins) # Plugins → «…\SketchUp»
          return root.tr('\\', '/') if File.basename(root) == 'SketchUp'
        end
      end

      File.join(appdata_root('APPDATA'), 'SketchUp', version_dir, 'SketchUp')
    end

    def local_root
      custom = ENV['DN1SUP_SAVE_SETTINGS_LOCAL_ROOT']
      return custom.tr('\\', '/').sub(%r{/+\z}, '') if custom && !custom.empty?

      File.join(appdata_root('LOCALAPPDATA'), 'SketchUp', version_dir, 'SketchUp')
    end

    # -- цели сохранения -----------------------------------------------------------

    # Полный путь цели; scope-файл может ещё не существовать.
    def resolve(target)
      root = target[:scope] == 'local' ? local_root : roaming_root
      File.join(root, target[:name])
    end

    # Состояние всех целей для интерфейса (существование + размер).
    # Размер считается лениво и кэшируется — сбрасывается после записи.
    # 'modified' у файлов — время последней записи SketchUp: файлы настроек
    # перезаписываются при выходе/по событиям, поэтому на диске может быть
    # состояние не текущей сессии (важно понимать при восстановлении).
    def states
      TARGETS.map do |target|
        path = resolve(target)
        exists = File.exist?(path)
        {
          'key' => target[:key], 'label' => target[:label], 'scope' => target[:scope],
          'kind' => target[:kind], 'name' => target[:name], 'path' => path,
          'exists' => exists, 'size' => exists ? size_of(target) : 0,
          'modified' => exists && target[:kind] == 'file' ? modified_at(path) : nil
        }
      end
    end

    def size_of(target)
      path = resolve(target)
      @sizes ||= {}
      @sizes[target[:key]] ||= begin
        File.directory?(path) ? dir_size(path) : (File.size(path) rescue 0)
      end
    end

    def reset_sizes!
      @sizes = nil
    end

    # Размер каталога рекурсивно; недоступные файлы пропускаются.
    def dir_size(dir)
      total = 0
      Dir.glob(File.join(dir, '**', '*')).each do |entry|
        total += File.size(entry) if File.file?(entry)
      rescue StandardError
        nil
      end
      total
    rescue StandardError
      0
    end

    # -- сведения о среде ------------------------------------------------------------

    def su_version
      return Sketchup.version.to_s if defined?(Sketchup) && Sketchup.respond_to?(:version)
      '—'
    end

    def su_year
      major = defined?(Sketchup) && Sketchup.respond_to?(:version) ? Sketchup.version.to_i : 0
      year = major >= 1000 ? major : (major.positive? ? 2000 + major : 2026)
      year.to_s
    end

    def username
      ENV['USERNAME'].to_s
    end

    private

    def modified_at(path)
      File.mtime(path).strftime('%Y-%m-%d %H:%M')
    rescue StandardError
      nil
    end

    def appdata_root(env_key)
      # Нормализуем разделители: ENV может отдавать пути с «\»
      (ENV[env_key] || Dir.home).to_s.tr('\\', '/')
    end

    def version_dir
      "SketchUp #{su_year}"
    end
  end
end
