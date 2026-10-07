import { reactive } from 'vue'
import { applyMockAction, mockPayload } from '../mocks'

/**
 * Мост Ruby ↔ JS (единый паттерн с dn1sup_create_project / dn1sup_time_project2):
 *  — JS → Ruby: sketchup.call_ruby(name, param) — один экшен-колбэк 'call_ruby';
 *  — Ruby → JS: window.pushState(state) и window.pushResult(kind, payload).
 *
 * Вне SketchUp (npm run dev в браузере) включается mock-режим.
 */

function getSketchup() {
  if (typeof sketchup !== 'undefined' && sketchup && typeof sketchup.call_ruby === 'function') {
    return sketchup
  }
  if (typeof window !== 'undefined' && window.sketchup && typeof window.sketchup.call_ruby === 'function') {
    return window.sketchup
  }
  return null
}

const isMock = !getSketchup()

// -- общее состояние UI -------------------------------------------------------

const state = reactive({
  ready: false,
  version: '…',
  suVersion: '',
  suYear: '',
  tarOk: true,
  storePath: '',
  backupsPath: '',
  defaultBackupsPath: '',
  archiveDir: '',
  archiveDirCustom: false,
  historyPath: '',
  user: '',
  targets: [],   // [{key,label,scope,kind,name,path,exists,size,modified}]
  history: [],   // [{file,created_at,comment,kind,size,su_version,paths,labels}]
  busy: null,    // 'create' | 'restore' | null — длительные операции
  toast: null,   // { kind: 'ok' | 'err', text }
  restartBanner: false,
  pendingRestore: null,  // {created_at, archive, labels, from_current_session, result} | null
  restoreRelaunch: true, // запускать SketchUp после отложенного применения
  showHelp: false        // одноразовый флаг Ruby: открыть справку (пункт меню «Справка»)
})

let toastTimer = null
function toast(kind, text, ms = 4500) {
  state.toast = { kind, text }
  if (toastTimer) clearTimeout(toastTimer)
  toastTimer = setTimeout(() => { state.toast = null }, ms)
}

// -- обработчики пушей Ruby (регистрируются до монтирования Vue) --------------

const resultHandlers = new Map() // kind -> Set<fn>
let archiveInfoResolver = null   // Promise-резолвер состава архива (readArchiveInfo)
let archiveLogResolver = null    // Promise-резолвер лога архивации (readArchiveLog)

function emitResult(kind, payload) {
  if (kind === 'archive_info') {
    const resolve = archiveInfoResolver
    archiveInfoResolver = null
    if (resolve) resolve(payload)
    return
  }
  if (kind === 'archive_log') {
    const resolve = archiveLogResolver
    archiveLogResolver = null
    if (resolve) resolve(payload)
    return
  }
  if (kind === 'error') {
    state.busy = null
    toast('err', payload.message || 'Ошибка Ruby', 7000)
    return
  }
  if (kind === 'backup_created') {
    state.busy = null
    toast('ok', `Резервная копия создана: ${payload.entry?.file || ''}`)
  }
  if (kind === 'restore_done') {
    state.busy = null
    const n = (payload.restored || []).length
    const d = (payload.deferred || []).length
    const errs = payload.errors || []
    if (n || d) {
      state.restartBanner = n > 0
      const parts = []
      if (n) parts.push(`Восстановлено путей: ${n} (нужен перезапуск SketchUp)`)
      if (d) parts.push(`файлов настроек применится автоматически после закрытия SketchUp: ${d}`)
      if (errs.length) {
        toast('err', `${parts.join('; ')}. С ошибками: ${errs.length}. ${errs[0]}`, 8000)
      } else {
        toast('ok', parts.join('; '), 8000)
      }
    } else {
      toast('err', 'Нечего восстанавливать: в архиве нет выбранных путей', 7000)
    }
  }
  if (kind === 'imported') {
    state.busy = null
    toast('ok', `Архив импортирован: ${payload.entry?.file || ''}`)
  }
  if (kind === 'reset_armed') {
    state.busy = null
    toast('ok', `Сброс подготовлен (${payload.label || ''}): применится после закрытия SketchUp. Резервная копия: ${payload.backup_file || ''}`, 8000)
  }
  if (kind === 'archive_dir_set') {
    state.busy = null
    toast('ok', `Папка архивов: ${payload.archive_dir || ''}`)
  }

  const set = resultHandlers.get(kind)
  if (set) set.forEach(fn => { try { fn(payload) } catch (e) { console.warn(e) } })
}

if (typeof window !== 'undefined') {
  window.pushState = function (payload) {
    if (!payload) return
    state.ready = true
    state.version = payload.version || '—'
    state.suVersion = payload.su_version || ''
    state.suYear = payload.su_year || ''
    state.tarOk = payload.tar_ok !== false
    state.storePath = payload.store_path || ''
    state.backupsPath = payload.backups_path || ''
    state.defaultBackupsPath = payload.default_backups_path || ''
    state.archiveDir = payload.archive_dir || ''
    state.archiveDirCustom = !!payload.archive_dir_custom
    state.historyPath = payload.history_path || ''
    state.user = payload.user || ''
    state.targets = payload.targets || []
    state.history = payload.history || []
    state.pendingRestore = payload.pending_restore || null
    state.restoreRelaunch = payload.restore_relaunch !== false
    state.showHelp = !!payload.show_help
    state.busy = null
  }
  window.pushResult = function (kind, payload) {
    emitResult(kind, payload || {})
  }
}

// -- вызовы Ruby ---------------------------------------------------------------

function callRuby(name, param) {
  const bridge = getSketchup()
  if (bridge) {
    try {
      bridge.call_ruby(name, param === undefined ? '' : String(param))
      return true
    } catch (e) {
      console.warn('callRuby error:', e)
    }
  }
  return false
}

function callRubyJson(name, obj) {
  return callRuby(name, JSON.stringify(obj))
}

export function loadState() {
  if (isMock) {
    setTimeout(() => window.pushState(mockPayload()), 150)
    return
  }
  callRuby('get_state')
}

/** Создание резервной копии. keys — массив ключей путей ([] = все существующие). */
export function createBackup(comment, keys) {
  if (isMock) {
    applyMockAction('create_backup', { comment, keys })
    return
  }
  state.busy = 'create'
  callRubyJson('create_backup', { comment, keys })
}

/** Восстановление из архива хранилища. keys — null (все из архива) или массив.
 *  relaunch — запускать SketchUp после отложенного применения файлов настроек. */
export function restoreBackup(file, autoBackup, keys = null, relaunch = true) {
  if (isMock) {
    applyMockAction('restore_backup', { file, auto_backup: autoBackup, relaunch })
    return
  }
  state.busy = 'restore'
  callRubyJson('restore_backup', { file, auto_backup: !!autoBackup, keys, relaunch: !!relaunch })
}

/** Отменяет отложенное применение файлов настроек (пока SketchUp открыт). */
export function cancelPendingRestore() {
  if (isMock) {
    state.pendingRestore = null
    toast('ok', 'Отложенное восстановление отменено')
    return
  }
  callRuby('cancel_pending_restore')
}

/** Скрывает баннер результата отложенного применения. */
export function dismissRestoreResult() {
  if (isMock) {
    state.pendingRestore = null
    return
  }
  callRuby('dismiss_restore_result')
}

export function deleteBackup(file) {
  if (isMock) {
    applyMockAction('delete_backup', { file })
    return
  }
  callRuby('delete_backup', file)
}

/** Импорт внешнего zip-архива (диалог выбора открывает Ruby). */
export function importZip() {
  if (isMock) {
    toast('ok', 'Импорт zip (mock)')
    return
  }
  callRuby('import_zip')
}

/** Состав архива для окна подтверждения восстановления. */
export function readArchiveInfo(file) {
  return new Promise((resolve) => {
    if (isMock) {
      setTimeout(() => resolve(applyMockAction('archive_info', { file })), 100)
      return
    }
    archiveInfoResolver = resolve
    callRuby('read_archive_info', file)
    // страховка: если ответ не пришёл за 30 секунд — отпускаем
    setTimeout(() => {
      if (archiveInfoResolver === resolve) archiveInfoResolver = null
    }, 30000)
  })
}

/** Лог архивации из архива (log: null — в архиве нет лога, старый формат). */
export function readArchiveLog(file) {
  return new Promise((resolve) => {
    if (isMock) {
      setTimeout(() => resolve(applyMockAction('archive_log', { file })), 100)
      return
    }
    archiveLogResolver = resolve
    callRuby('read_archive_log', file)
    // страховка: если ответ не пришёл за 30 секунд — отпускаем
    setTimeout(() => {
      if (archiveLogResolver === resolve) archiveLogResolver = null
    }, 30000)
  })
}

export function openBackupsFolder() {
  if (isMock) { toast('ok', state.backupsPath || 'C:\\mock\\backups'); return }
  callRuby('open_backups_folder')
}

/** Выбор папки архивов (диалог выбора открывает Ruby). */
export function chooseArchiveDir() {
  if (isMock) { applyMockAction('choose_archive_dir'); return }
  callRuby('choose_archive_dir')
}

/** Сброс папки архивов на стандартную. */
export function resetArchiveDir() {
  if (isMock) { applyMockAction('reset_archive_dir'); return }
  callRuby('reset_archive_dir')
}

/** Сброс цели к заводским настройкам (key: 'private_prefs' | 'plugins').
 *  Ruby принудительно создаёт резервную копию, применение — после закрытия
 *  SketchUp. relaunch — запускать SketchUp после применения. */
export function resetTarget(key, relaunch = true) {
  if (isMock) {
    applyMockAction('reset_target', { key, relaunch })
    return
  }
  state.busy = 'reset'
  callRubyJson('reset_target', { key, relaunch: !!relaunch })
}

export function revealBackup(file) {
  if (isMock) { toast('ok', file); return }
  callRuby('reveal_backup', file)
}

export function updateFromDev() {
  if (isMock) { toast('ok', 'Обновление из dev-папки (mock)'); return }
  callRuby('update_from_dev')
}

export { state, isMock, toast }
