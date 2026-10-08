/**
 * Mock-режим для разработки интерфейса в браузере (npm run dev).
 * Имитирует ответы Ruby: pushState / pushResult.
 */

const mockTargets = [
  { key: 'private_prefs', label: 'Настройки интерфейса (PrivatePreferences.json)', scope: 'local', kind: 'file', name: 'PrivatePreferences.json', path: 'C:\\Users\\User\\AppData\\Local\\SketchUp\\SketchUp 2026\\SketchUp\\PrivatePreferences.json', exists: true, size: 48213, modified: '2026-10-06 20:02' },
  { key: 'shared_prefs', label: 'Системные настройки (SharedPreferences.json)', scope: 'roaming', kind: 'file', name: 'SharedPreferences.json', path: 'C:\\Users\\User\\AppData\\Roaming\\SketchUp\\SketchUp 2026\\SketchUp\\SharedPreferences.json', exists: true, size: 8124, modified: '2026-10-06 20:02' },
  { key: 'components', label: 'Компоненты (Components)', scope: 'roaming', kind: 'dir', name: 'Components', path: 'C:\\Users\\User\\AppData\\Roaming\\SketchUp\\SketchUp 2026\\SketchUp\\Components', exists: true, size: 152_043_264 },
  { key: 'materials', label: 'Материалы (Materials)', scope: 'roaming', kind: 'dir', name: 'Materials', path: 'C:\\Users\\User\\AppData\\Roaming\\SketchUp\\SketchUp 2026\\SketchUp\\Materials', exists: true, size: 25_165_824 },
  { key: 'plugins', label: 'Расширения (Plugins)', scope: 'roaming', kind: 'dir', name: 'Plugins', path: 'C:\\Users\\User\\AppData\\Roaming\\SketchUp\\SketchUp 2026\\SketchUp\\Plugins', exists: true, size: 214_748_364 },
  { key: 'styles', label: 'Стили (Styles)', scope: 'roaming', kind: 'dir', name: 'Styles', path: 'C:\\Users\\User\\AppData\\Roaming\\SketchUp\\SketchUp 2026\\SketchUp\\Styles', exists: false, size: 0 },
  { key: 'templates', label: 'Шаблоны (Templates)', scope: 'roaming', kind: 'dir', name: 'Templates', path: 'C:\\Users\\User\\AppData\\Roaming\\SketchUp\\SketchUp 2026\\SketchUp\\Templates', exists: true, size: 3_145_728 }
]

let mockHistory = [
  { file: 'dn1sup_settings_2026-10-05_182233.zip', created_at: '2026-10-05 18:22:33', comment: 'Перед обновлением SketchUp', kind: 'manual', size: 18_241_331, su_version: '26.2.243', paths: ['private_prefs', 'materials', 'plugins'], labels: ['Настройки интерфейса (PrivatePreferences.json)', 'Материалы (Materials)', 'Расширения (Plugins)'] },
  { file: 'dn1sup_settings_auto_2026-10-05_181002.zip', created_at: '2026-10-05 18:10:02', comment: 'Автоматически перед восстановлением', kind: 'auto', size: 17_998_112, su_version: '26.2.243', paths: ['private_prefs', 'materials'], labels: ['Настройки интерфейса (PrivatePreferences.json)', 'Материалы (Materials)'] },
  { file: 'dn1sup_settings_2026-10-04_090115.zip', created_at: '2026-10-04 09:01:15', comment: '', kind: 'quick', size: 9_812_004, su_version: '26.1.340', paths: ['materials', 'styles'], labels: ['Материалы (Materials)', 'Стили (Styles)'] }
]

export function mockPayload() {
  return {
    version: '0.5.0-mock',
    su_version: '26.2.243',
    su_year: '2026',
    tar_ok: true,
    store_path: 'C:\\Users\\User\\AppData\\Roaming\\SketchUp\\SketchUp 2026\\dn1sup_save_settings',
    default_backups_path: 'C:\\Users\\User\\AppData\\Roaming\\SketchUp\\SketchUp 2026\\dn1sup_save_settings\\backups',
    archive_dir: '',
    archive_dir_custom: false,
    backups_path: 'C:\\Users\\User\\AppData\\Roaming\\SketchUp\\SketchUp 2026\\dn1sup_save_settings\\backups',
    history_path: 'C:\\Users\\User\\AppData\\Roaming\\SketchUp\\SketchUp 2026\\dn1sup_save_settings\\history.json',
    user: 'User',
    targets: mockTargets,
    history: mockHistory,
    pending_restore: null,
    restore_relaunch: true
  }
}

/** Имитация действий Ruby: возвращает результат и пушит состояние. */
export function applyMockAction(name, params) {
  if (name === 'create_backup') {
    const keys = params.keys && params.keys.length ? params.keys : mockTargets.filter(t => t.exists).map(t => t.key)
    const now = new Date()
    const stamp = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}_${String(now.getHours()).padStart(2, '0')}${String(now.getMinutes()).padStart(2, '0')}${String(now.getSeconds()).padStart(2, '0')}`
    const entry = {
      file: `dn1sup_settings_${stamp}.zip`,
      created_at: `${stamp.slice(0, 10)} ${stamp.slice(11, 13)}:${stamp.slice(13, 15)}:${stamp.slice(15, 17)}`,
      comment: params.comment || '',
      kind: 'manual',
      size: 12_345_678,
      su_version: '26.2.243',
      paths: keys,
      labels: mockTargets.filter(t => keys.includes(t.key)).map(t => t.label)
    }
    mockHistory = [entry, ...mockHistory]
    window.pushResult('backup_created', { entry, backups_path: mockPayload().backups_path })
    setTimeout(() => window.pushState(mockPayload()), 150)
  }
  if (name === 'restore_backup') {
    window.pushResult('restore_done', {
      restored: ['Materials'],
      deferred: ['PrivatePreferences.json', 'SharedPreferences.json'],
      skipped: ['Templates'],
      errors: [],
      pending_dir: 'C:\\mock\\pending_restore',
      auto_backup_file: 'dn1sup_settings_auto_2026-10-06_120000.zip'
    })
    setTimeout(() => window.pushState({
      ...mockPayload(),
      pending_restore: {
        created_at: '2026-10-06 12:00:00',
        archive: 'dn1sup_settings_2026-10-06_120000.zip',
        labels: ['Настройки интерфейса (PrivatePreferences.json)', 'Системные настройки (SharedPreferences.json)'],
        from_current_session: true,
        result: null
      }
    }), 150)
  }
  if (name === 'cancel_pending_restore') {
    window.pushState({ ...mockPayload(), pending_restore: null })
  }
  if (name === 'dismiss_restore_result') {
    window.pushState({ ...mockPayload(), pending_restore: null })
  }
  if (name === 'delete_backup') {
    mockHistory = mockHistory.filter(e => e.file !== params.file)
    window.pushState(mockPayload())
  }
  if (name === 'archive_info') {
    const entry = mockHistory.find(e => e.file === params.file) || mockHistory[0]
    return {
      file: params.file,
      exists: true,
      manifest: {
        created_at: entry.created_at,
        sketchup_version: entry.su_version,
        comment: entry.comment,
        paths: entry.paths,
        targets: entry.paths.map((key, i) => ({
          key,
          label: entry.labels[i],
          scope: key === 'private_prefs' ? 'local' : 'roaming',
          kind: key === 'private_prefs' || key === 'shared_prefs' ? 'file' : 'dir',
          name: key
        }))
      }
    }
  }
  if (name === 'archive_log') {
    return {
      file: params.file,
      exists: true,
      log: [
        'dn1sup_save_settings — лог архивации',
        '============================================',
        'Создан:       2026-10-06 12:34:56',
        'SketchUp:     26.2.243 (2026)',
        'Пользователь: User',
        'Тип:          manual',
        'Комментарий:  Перед обновлением SketchUp',
        'Пути:         private_prefs, materials',
        '',
        '[roaming] Materials — папка',
        '  Источник: C:\\Users\\User\\AppData\\Roaming\\SketchUp\\SketchUp 2026\\SketchUp\\Materials',
        '  Файлов: 2 · Размер: 15 Б',
        '    styles/a.skm — 3',
        '    wood.skm — 12',
        '',
        '[local] PrivatePreferences.json — файл',
        '  Источник: C:\\Users\\User\\AppData\\Local\\SketchUp\\SketchUp 2026\\SketchUp\\PrivatePreferences.json',
        '  Размер: 48213',
        '',
        '---',
        'Итог: путей 2 · файлов 3 · 47.2 КБ (48231 байт)',
        'Архив: dn1sup_settings_2026-10-06_123456.zip'
      ].join('\n')
    }
  }
  if (name === 'choose_archive_dir') {
    const dir = 'D:\\Архивы SketchUp'
    window.pushResult('archive_dir_set', { archive_dir: dir })
    setTimeout(() => window.pushState({ ...mockPayload(), archive_dir: dir, archive_dir_custom: true, backups_path: dir }), 150)
  }
  if (name === 'reset_archive_dir') {
    const base = mockPayload()
    window.pushResult('archive_dir_set', { archive_dir: base.backups_path })
    setTimeout(() => window.pushState({ ...base, archive_dir: '', archive_dir_custom: false }), 150)
  }
  if (name === 'reset_target') {
    const keys = Array.isArray(params.keys) && params.keys.length ? params.keys : [params.key]
    const labels = keys.map(k => mockTargets.find(t => t.key === k)?.label || k)
    window.pushResult('reset_armed', { labels, backup_file: 'dn1sup_settings_auto_2026-10-06_120001.zip' })
    setTimeout(() => window.pushState({
      ...mockPayload(),
      pending_restore: {
        kind: 'reset',
        created_at: '2026-10-06 12:00:01',
        archive: '',
        labels,
        from_current_session: true,
        result: null
      }
    }), 150)
  }
  return null
}
