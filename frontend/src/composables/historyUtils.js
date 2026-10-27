import { state } from './useSketchupBridge'

export function formatBytes(bytes) {
  const n = Number(bytes) || 0
  if (n <= 0) return '0 Б'
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ']
  let v = n
  let i = 0
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++ }
  return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`
}

export function formatDate(s) {
  // '2026-10-06 18:22:33' → '06.10.2026 18:22'
  const m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})/.exec(s || '')
  return m ? `${m[3]}.${m[2]}.${m[1]} ${m[4]}:${m[5]}` : (s || '')
}

export const kindInfo = {
  manual:   { label: 'Ручная',  cls: 'bg-brand-100 text-brand-700 dark:bg-brand-900/60 dark:text-brand-300' },
  quick:    { label: 'Быстрая', cls: 'bg-emerald-100 text-emerald-700 dark:bg-emerald-900/60 dark:text-emerald-300' },
  auto:     { label: 'Авто',    cls: 'bg-amber-100 text-amber-700 dark:bg-amber-900/60 dark:text-amber-300' },
  imported: { label: 'Импорт',  cls: 'bg-violet-100 text-violet-700 dark:bg-violet-900/60 dark:text-violet-300' }
}

// Подсказка строки истории: имя файла плюс то, что не влезло в одну строку
// списка (тип копии, комментарий/метки, версия SketchUp).
export function entryTitle(entry) {
  const parts = [entry.file]
  const kind = kindInfo[entry.kind]?.label
  if (kind) parts.push(`Тип: ${kind}`)
  const note = entry.comment || (entry.labels || []).join(', ')
  if (note) parts.push(note)
  if (entry.su_version) parts.push(`SketchUp ${entry.su_version} · путей: ${(entry.paths || []).length}`)
  return parts.join('\n')
}

export function storeYearOf(entry) {
  return entry.store_year || entry.su_year || ''
}

export function isForeignEntry(entry) {
  const y = storeYearOf(entry)
  return !!y && !!state.suYear && y !== String(state.suYear)
}

// -- запрет даунгрейда (зеркало Ruby VersionGuard) ---------------------------
// Сравнение полных версий SketchUp ("27.0.100" vs "26.2.243"), численно по
// компонентам; хвосты-нули равны ("27" == "27.0.0"). null — хотя бы одна
// версия неизвестна (сравнивать нечего).
export function parseVersion(v) {
  const digits = String(v || '').match(/\d+/g)
  return digits && digits.length ? digits.map(Number) : null
}

export function isUnknownVersion(v) {
  return parseVersion(v) === null
}

export function compareVersions(a, b) {
  const pa = parseVersion(a)
  const pb = parseVersion(b)
  if (!pa || !pb) return null
  const len = Math.max(pa.length, pb.length)
  for (let i = 0; i < len; i++) {
    const x = pa[i] || 0
    const y = pb[i] || 0
    if (x < y) return -1
    if (x > y) return 1
  }
  return 0
}

// Источник новее текущей — восстановление запрещено (hard-блок, без обхода).
export function isDowngradeEntry(entry, currentVersion) {
  const cur = currentVersion || state.suVersion
  if (!cur || isUnknownVersion(cur)) return false
  const src = entry?.su_version || entry?.sketchup_version || ''
  if (isUnknownVersion(src)) return false
  return compareVersions(src, cur) === 1
}

// Неизвестная версия источника: блок, кроме kind 'imported' (пользователь
// сам загрузил профиль через импорт — разрешить с предупреждением).
export function isUnknownEntryBlocked(entry) {
  const src = entry?.su_version || entry?.sketchup_version || ''
  return isUnknownVersion(src) && entry?.kind !== 'imported'
}

export function isRestoreBlocked(entry, currentVersion) {
  if (!entry) return false
  if (isDowngradeEntry(entry, currentVersion)) return true
  return isUnknownEntryBlocked(entry)
}
