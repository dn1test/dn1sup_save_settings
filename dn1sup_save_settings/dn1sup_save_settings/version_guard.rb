# frozen_string_literal: true
# =============================================================================
# dn1sup_save_settings/version_guard.rb — запрет восстановления «сверху вниз».
#
# Правило: бэкап можно восстанавливать только на ту же или более новую версию
# SketchUp. Источник новее текущей — hard-блок без обхода. Сравнение — по
# полной строке sketchup_version из манифеста ("27.0.100" vs "26.2.243"),
# численно по компонентам; недостающие хвосты считаются нулями
# ("27" == "27.0.0"). sketchup_year — только запасной фолбэк, когда версия
# не распарсилась, но год известен обоим.
#
# Неизвестная версия источника: блокируется, кроме случая allow_unknown
# (архив с kind == 'imported' — пользователь сам загрузил профиль через
# импорт: разрешить с предупреждением, фронт показывает жёлтый баннер).
# Неизвестная текущая версия ("—" вне SketchUp, тесты): enforcement
# невозможен — разрешить, чтобы не ломать тесты и dev-среду.
# =============================================================================

module Dn1supSaveSettings
  module VersionGuard
    extend self

    UNKNOWN_CURRENT = ['—', '', nil].freeze

    # "27.0.100" → [27, 0, 100]; "26.2" → [26, 2]; "—"/"" → nil.
    def parse(version)
      digits = version.to_s.scan(/\d+/).map(&:to_i)
      digits.empty? ? nil : digits
    end

    def unknown?(version)
      parse(version).nil?
    end

    # -1 — a < b, 0 — равны, 1 — a > b, nil — хотя бы одна неизвестна.
    def compare(a, b)
      pa = parse(a)
      pb = parse(b)
      return nil if pa.nil? || pb.nil?

      len = [pa.size, pb.size].max
      len.times do |i|
        x = pa[i] || 0
        y = pb[i] || 0
        return -1 if x < y
        return 1 if x > y
      end
      0
    end

    def downgrade?(source_version, current_version)
      compare(source_version, current_version) == 1
    end

    # Год из манифеста/текущий ("2026", 2026) → Integer или nil.
    def parse_year(value)
      m = value.to_s.strip.match(/\A(202\d)\b/)
      m ? m[1].to_i : nil
    end

    # Не бросающая проверка для UI (read_archive_info): возвращает хэш
    # { blocked:, reason:, unknown:, downgrade: } — фронт решает баннер
    # и disabled кнопки; backend при restore! всё равно бросает.
    def check_info(manifest, current_version, allow_unknown: false)
      cur = current_version.to_s
      # Вне SketchUp текущая версия неизвестна ("—", тесты/dev): enforcement
      # невозможен — разрешить, чтобы не ломать тесты и dev-среду.
      return ok if UNKNOWN_CURRENT.include?(cur) || (parse(cur).nil? && parse_year(current_year_of(cur)).nil?)

      src_version = manifest.is_a?(Hash) ? manifest['sketchup_version'].to_s : ''
      src_year = manifest.is_a?(Hash) ? parse_year(manifest['sketchup_year']) : nil
      cur_year = parse_year(current_year_of(current_version))
      cmp = compare(src_version, current_version.to_s)

      if cmp.nil?
        # Версия не сравнилась — пробуем год как фолбэк.
        if !src_year.nil? && !cur_year.nil?
          if src_year > cur_year
            return blocked("Архив создан в SketchUp #{src_year} — восстановление в SketchUp #{cur_year} запрещено: " \
                           'бэкапы можно переносить только на ту же или более новую версию SketchUp.')
          end
          return ok
        end
        return unknown_result(src_version, allow_unknown)
      end

      return blocked("Архив создан в SketchUp #{src_version} — восстановление в SketchUp #{current_version} запрещено: " \
                     'бэкапы можно переносить только на ту же или более новую версию SketchUp.') if cmp == 1

      ok
    end

    # Бросающая проверка для Restorer.restore! (до автобэкапа и распаковки).
    def check!(manifest, current_version, allow_unknown: false)
      info = check_info(manifest, current_version, allow_unknown: allow_unknown)
      raise Error, info[:reason] if info[:blocked]

      Log.warn("Восстановление архива с неизвестной версией (текущая #{current_version}): разрешено как импорт") if info[:unknown]
      info
    end

    private

    def current_year_of(current_version)
      v = current_version.to_s
      return nil if UNKNOWN_CURRENT.include?(v)

      major = v.scan(/\d+/).first.to_i
      major >= 1000 ? major.to_s : (major.positive? ? (2000 + major).to_s : '')
    end

    def ok
      { blocked: false, reason: nil, unknown: false, downgrade: false }
    end

    def blocked(reason)
      { blocked: true, reason: reason, unknown: false, downgrade: true }
    end

    def unknown_result(src_version, allow_unknown)
      label = src_version.to_s.empty? ? 'не указана' : src_version.to_s
      if allow_unknown
        { blocked: false, reason: nil, unknown: true, downgrade: false }
      else
        { blocked: true,
          reason: "Версию SketchUp архива определить нельзя (#{label}) — восстановление запрещено. " \
                  'Исключение — архивы, загруженные через импорт: они восстанавливаются с предупреждением.',
          unknown: true, downgrade: false }
      end
    end
  end
end
