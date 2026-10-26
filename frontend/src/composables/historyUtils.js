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
