<script setup>
import { computed, onMounted, ref, watch } from 'vue'
import {
  Archive, ArchiveRestore, CheckCircle2, CircleHelp, Clock3, Eraser, FolderOpen,
  LayoutGrid, List, ListChecks, Loader2, Moon, PackageX, RotateCw, Save, Settings as SettingsIcon, Sun, Trash2, TriangleAlert, Upload, X
} from 'lucide-vue-next'
import {
  state, isMock, toast, loadState, createBackup, restoreBackup, deleteBackup,
  importZip, readArchiveInfo, readArchiveLog, openBackupsFolder, revealBackup, checkUpdate,
  chooseArchiveDir, resetArchiveDir, quitSketchup,
  cancelPendingRestore, dismissRestoreResult, resetTargets
} from './composables/useSketchupBridge'
import { useTheme } from './composables/useTheme'
import { formatBytes, formatDate, storeYearOf, compareVersions, isUnknownVersion, isDowngradeEntry, isRestoreBlocked } from './composables/historyUtils'
import Modal from './components/Modal.vue'
import HistoryList from './components/HistoryList.vue'
import HelpModal from './components/HelpModal.vue'
import Toast from './components/Toast.vue'

const { isDark, toggleTheme } = useTheme()

// -- справка ----------------------------------------------------------------
// Открывается кнопкой «?» в шапке; автопоказ — по одноразовому флагу
// state.showHelp (пункт меню «Справка» в Ruby передаёт его в push_state).

const helpOpen = ref(false)
const extSettingsOpen = ref(false)
const settingsOpen = ref(false)
watch(() => state.showHelp, (v) => {
  if (v) {
    helpOpen.value = true
    state.showHelp = false
  }
})

// -- выбор путей ----------------------------------------------------------------

const selectedKeys = ref(null) // null — ещё не инициализировано
watch(() => state.targets, (targets) => {
  if (selectedKeys.value === null && targets.length) {
    selectedKeys.value = targets.map(t => t.key)
  }
}, { immediate: true })

function toggleKey(key) {
  const list = selectedKeys.value || []
  const i = list.indexOf(key)
  if (i >= 0) list.splice(i, 1)
  else list.push(key)
  selectedKeys.value = list
}

const selectedCount = computed(() => (selectedKeys.value || []).length)
const canCreate = computed(() => state.tarOk && selectedCount.value > 0 && !state.busy && !pendingActive.value)
const comment = ref('')

// -- вид истории: «строки» (один архив — одна строка) или «карточки» ----------
// Выбор запоминается в localStorage так же, как тема.

const historyView = ref('rows')
try {
  const saved = localStorage.getItem('dn1sup_history_view')
  if (saved === 'cards' || saved === 'rows') historyView.value = saved
} catch {
  // ignore
}

function setHistoryView(view) {
  historyView.value = view
  try {
    localStorage.setItem('dn1sup_history_view', view)
  } catch {
    // ignore
  }
}

function doCreate() {
  if (!canCreate.value) return
  createBackup(comment.value.trim(), selectedKeys.value || [])
}

// -- восстановление -------------------------------------------------------------

const restoreModal = ref(null)

// Активная вкладка: год версии, 'history' (общая история) или 'settings'.

// Группы истории по версиям SketchUp: берутся из Ruby (history_by_version),
// fallback — одна группа текущей версии из плоской истории.
const historyGroups = computed(() => {
  const groups = state.historyByVersion
  if (Array.isArray(groups) && groups.length) return groups
  return [{
    year: state.suYear || '',
    current: true,
    store_exists: true,
    backups_path: state.backupsPath || '',
    count: (state.history || []).length,
    history: state.history || []
  }]
})

const totalHistoryCount = computed(() =>
  historyGroups.value.reduce((n, g) => n + (g.history || []).length, 0)
)

// Две зоны вкладок: текущая версия — слева, остальные — справа.
// current — по флагу Ruby, fallback — первая группа.
const currentGroup = computed(() =>
  historyGroups.value.find(g => g.current) || historyGroups.value[0] || null
)
const otherGroups = computed(() =>
  historyGroups.value
    .filter(g => g !== currentGroup.value)
    .slice()
    .sort((a, b) => String(b.year).localeCompare(String(a.year)))
)

// Активная вкладка версии. Внутри вкладки — подвкладки «Настройки»
// и «История» (выбор запоминается).
const activeYear = ref(null)
watch(historyGroups, (groups) => {
  if (activeYear.value === null && groups.length) {
    const cur = groups.find(g => g.current) || groups[0]
    activeYear.value = cur.year
  }
}, { immediate: true })

function selectYear(year) {
  activeYear.value = year
}

const activeGroup = computed(() =>
  historyGroups.value.find(g => g.year === activeYear.value) || historyGroups.value[0] || null
)

const activeHistory = computed(() => activeGroup.value?.history || [])

// Подсказки совместимости путей при переносе между версиями SketchUp:
// JSON-настройки лежат одной схемой (лишние ключи игнорируются), файлы
// контента переносимы как есть, код расширений версионно-зависим.
const targetHints = {
  private_prefs: 'Настройки интерфейса — безопасно между версиями',
  shared_prefs: 'Системные настройки — безопасно между версиями',
  components: 'Файлы библиотек — полностью переносимы',
  materials: 'Файлы библиотек — полностью переносимы',
  styles: 'Файлы библиотек — полностью переносимы',
  templates: 'Файлы библиотек — полностью переносимы',
  plugins: 'Код расширений может не подойти другой версии SketchUp'
}

async function openRestore(entry) {
  if (isLocked.value) {
    toast('err', 'Закройте SketchUp или отмените запланированную задачу — настройки заблокированы до перезагрузки')
    return
  }
  const info = await readArchiveInfo(entry.file, storeYearOf(entry))
  if (!info || !info.manifest) {
    toast('err', 'Не удалось прочитать состав архива')
    return
  }
  const targets = info.manifest.targets || []
  restoreModal.value = {
    file: entry.file,
    kind: entry.kind || '',
    store_year: storeYearOf(entry),
    created_at: info.manifest.created_at || entry.created_at,
    su_version: info.manifest.sketchup_version || entry.su_version,
    su_year: info.manifest.sketchup_year || entry.su_year || storeYearOf(entry),
    comment: info.manifest.comment || entry.comment || '',
    targets,
    native: info.native || [],
    selected: targets.map(t => t.key),
    autoBackup: true,
    version_check: info.version_check || null
  }
}

function toggleRestoreKey(key) {
  const m = restoreModal.value
  if (!m) return
  const list = m.selected || []
  const i = list.indexOf(key)
  if (i >= 0) list.splice(i, 1)
  else list.push(key)
  m.selected = [...list]
}

const restoreSelectedCount = computed(() => (restoreModal.value?.selected || []).length)
const restoreIsPartial = computed(() => {
  const m = restoreModal.value
  return !!m && m.selected.length > 0 && m.selected.length < (m.targets || []).length
})

function doRestore() {
  const m = restoreModal.value
  if (!m || !m.selected.length) return
  if (restoreBlocked.value) return
  restoreModal.value = null
  // Все выбраны — null (весь архив); подмножество — явный список ключей.
  const keys = m.selected.length === (m.targets || []).length ? null : [...m.selected]
  restoreBackup(m.file, m.autoBackup, keys, m.store_year)
}

// -- запрет даунгрейда --------------------------------------------------------
// Источник новее текущей версии — hard-блок без обхода. Ruby-вариант
// (version_check из read_archive_info) авторитетен; клиентский пересчёт —
// страховка, если version_check отсутствует (старый ответ/мок).
const restoreDowngrade = computed(() => {
  const m = restoreModal.value
  if (!m) return false
  if (m.version_check && typeof m.version_check.downgrade !== 'undefined') return !!m.version_check.downgrade
  return isDowngradeEntry({ su_version: m.su_version }, state.suVersion)
})
const restoreUnknown = computed(() => {
  const m = restoreModal.value
  if (!m) return false
  if (m.version_check && typeof m.version_check.unknown !== 'undefined') return !!m.version_check.unknown
  return isUnknownVersion(m.su_version)
})
const restoreBlocked = computed(() => {
  const m = restoreModal.value
  if (!m) return false
  if (m.version_check && typeof m.version_check.blocked !== 'undefined') return !!m.version_check.blocked
  return isRestoreBlocked({ su_version: m.su_version, kind: m.kind }, state.suVersion)
})
const restoreBlockReason = computed(() => {
  const m = restoreModal.value
  if (!m) return ''
  if (m.version_check?.reason) return m.version_check.reason
  if (restoreDowngrade.value) {
    return `Архив создан в SketchUp ${m.su_version} — восстановление в SketchUp ${state.suVersion} запрещено: бэкапы можно переносить только на ту же или более новую версию.`
  }
  if (restoreUnknown.value) {
    return 'Версию SketchUp архива определить нельзя — восстановление запрещено (исключение: архивы, загруженные через импорт).'
  }
  return ''
})
// Неизвестная версия + imported: разрешено с предупреждением.
const restoreUnknownAllowed = computed(() => {
  const m = restoreModal.value
  return !!m && restoreUnknown.value && !restoreBlocked.value
})

const hasPlugins = computed(() => (restoreModal.value?.targets || []).some(t => t.key === 'plugins'))
const hasDirs = computed(() => (restoreModal.value?.targets || []).some(t => t.kind !== 'file'))

// -- отложенное применение файлов настроек ---------------------------------------
// pendingRestore: from_current_session=false без result — задача прошлой
// сессии, helper не сработал (например, заблокирован политикой).

const pendingActive = computed(() => {
  const p = state.pendingRestore
  return !!p && p.from_current_session && !p.result
})
const pendingResult = computed(() => !!state.pendingRestore?.result)
const pendingStale = computed(() => {
  const p = state.pendingRestore
  return !!p && !p.from_current_session && !p.result
})

// Жёсткая блокировка до перезагрузки: пока отложенная задача активна,
// все изменения запрещены — только «Закрыть SketchUp», «Отменить»,
// просмотр и закрытие диалога.
const isLocked = computed(() => pendingActive.value)

const pendingKindText = computed(() =>
  state.pendingRestore?.kind === 'reset' ? 'Сброс настроек' : 'Отложенное применение настроек'
)

const pendingResultText = computed(() => {
  const r = state.pendingRestore?.result
  if (!r) return ''
  const when = r.finished ? formatDate(r.finished) : ''
  if (r.status === 'ok') {
    return `${pendingKindText.value} выполнено успешно${when ? ` (${when})` : ''}. Изменения применены до запуска SketchUp.`
  }
  const fail = (r.lines || []).find(line => line.startsWith('fail'))
  return `${pendingKindText.value} выполнилось с ошибками${when ? ` (${when})` : ''}.${fail ? ` ${fail}` : ''}`
})

function cancelPending() {
  cancelPendingRestore()
}

function quitSu() {
  quitSketchup()
}

function dismissResult() {
  dismissRestoreResult()
}

const confirmDelete = ref(null) // {file, store_year} — архив к удалению

function askDelete(entry) {
  if (isLocked.value) {
    toast('err', 'Закройте SketchUp или отмените запланированную задачу — настройки заблокированы до перезагрузки')
    return
  }
  confirmDelete.value = { file: entry.file, store_year: storeYearOf(entry) }
}

function onRevealEntry(entry) {
  revealBackup(entry.file, storeYearOf(entry))
}

function doDelete() {
  if (!confirmDelete.value) return
  deleteBackup(confirmDelete.value.file, confirmDelete.value.store_year)
  confirmDelete.value = null
}

// -- сброс к заводским настройкам -------------------------------------------------
// resetModal: { keys: ['private_prefs' | 'plugins', …] }. Применение —
// отложенное (сразу после закрытия SketchUp: он закроется сам и запустится
// снова), перед сбросом Ruby принудительно создаёт резервную копию.
// Пока сброс запланирован (pendingActive), все кнопки сброса заблокированы —
// и в интерфейсе, и на стороне Ruby.

const resetModal = ref(null)

// Единая блокировка всех кнопок сброса: busy-операция или уже запланированный
// сброс (после нажатия любой кнопки — до применения или отмены).
const resetBlocked = computed(() => !state.tarOk || !!state.busy || pendingActive.value)

const resetTargetsState = computed(() => ({
  private_prefs: state.targets.find(t => t.key === 'private_prefs')?.exists,
  plugins: state.targets.find(t => t.key === 'plugins')?.exists
}))

const canResetNow = computed(() =>
  state.tarOk && !state.busy && !pendingActive.value && !!resetModal.value
)

const resetIsAll = computed(() => (resetModal.value?.keys || []).length > 1)

const resetTitle = computed(() => {
  if (resetIsAll.value) return 'Сбросить всё?'
  return resetModal.value?.keys?.[0] === 'plugins' ? 'Сброс плагинов?' : 'Сброс интерфейса?'
})

function openReset(keys) {
  if (isLocked.value) {
    toast('err', 'Сброс уже запланирован — дождитесь перезапуска SketchUp или отмените его в баннере')
    return
  }
  resetModal.value = { keys: Array.isArray(keys) ? keys : [keys] }
}

function doReset() {
  const m = resetModal.value
  if (!m) return
  resetModal.value = null
  resetTargets(m.keys)
}

// -- лог архивации ------------------------------------------------------------------
// log: undefined — чтение из архива, string — текст лога,
// null — в архиве нет лога (старый формат) / не удалось прочитать.

const logModal = ref(null)

async function openLog(entry) {
  logModal.value = { file: entry.file, log: undefined, failed: false }
  const res = await Promise.race([
    readArchiveLog(entry.file, storeYearOf(entry)),
    new Promise(resolve => setTimeout(() => resolve(undefined), 31000))
  ])
  if (!logModal.value || logModal.value.file !== entry.file) return
  if (res === undefined) {
    logModal.value = { file: entry.file, log: null, failed: true }
  } else {
    logModal.value = { file: entry.file, log: res.log ?? null, failed: false }
  }
}

// -- папка архивов ----------------------------------------------------------------

const dirModal = ref(false) // модал «Папка архивов»

onMounted(loadState)
</script>

<template>
  <div class="h-full flex flex-col">
    <!-- Шапка -->
    <header class="flex items-center gap-3 px-4 py-2.5 border-b border-slate-200 dark:border-slate-800 bg-white/70 dark:bg-slate-900/70">
      <img src="./assets/logo.svg" width="32" height="32" class="shrink-0" alt="DN1Sup Save Settings">
      <div class="min-w-0">
        <div class="flex items-center gap-2">
          <h1 class="text-sm font-semibold leading-tight">Save Settings</h1>
          <span class="text-[10px] px-1.5 py-0.5 rounded bg-slate-100 dark:bg-slate-800 text-slate-500">v{{ state.version }}</span>
        </div>
        <p class="text-[11px] text-slate-400 dark:text-slate-500 truncate">
          SketchUp {{ state.suYear }} · {{ state.suVersion }} · {{ state.user }}
        </p>
      </div>
      <div class="ml-auto flex items-center gap-1">
        <button
          class="p-1.5 rounded-full text-slate-500 hover:bg-slate-100 dark:hover:bg-slate-800 disabled:opacity-40 disabled:cursor-wait"
          :title="state.checkingUpdate ? 'Проверка обновлений…' : 'Проверить обновление на GitHub'"
          :disabled="state.checkingUpdate"
          @click="checkUpdate"
        >
          <RotateCw :size="15" :class="{ 'animate-spin': state.checkingUpdate }" />
        </button>
        <button class="p-1.5 rounded-lg text-slate-500 hover:bg-slate-100 dark:hover:bg-slate-800" title="Настройки расширения: папка архивов, сведения" @click="extSettingsOpen = true">
          <SettingsIcon :size="16" />
        </button>
        <button class="p-1.5 rounded-lg text-slate-500 hover:bg-slate-100 dark:hover:bg-slate-800" title="Справка: как пользоваться" @click="helpOpen = true">
          <CircleHelp :size="16" />
        </button>
        <button class="p-1.5 rounded-lg text-slate-500 hover:bg-slate-100 dark:hover:bg-slate-800" :title="isDark ? 'Светлая тема' : 'Тёмная тема'" @click="toggleTheme">
          <Sun v-if="isDark" :size="16" />
          <Moon v-else :size="16" />
        </button>
      </div>
    </header>

    <!-- Баннер: активное отложенное восстановление (применится после закрытия) -->
    <div
      v-if="pendingActive"
      class="flex items-center gap-2 px-4 py-2 bg-sky-50 dark:bg-sky-950/50 border-b border-sky-200 dark:border-sky-900 text-sky-800 dark:text-sky-200 text-xs"
    >
      <Clock3 :size="14" class="shrink-0" />
      <span v-if="state.pendingRestore.kind === 'reset'" class="flex-1">
        Сброс ({{ (state.pendingRestore.labels || []).join(', ') }})
        запланирован: закройте SketchUp сами — изменения применятся, затем откройте его вручную.
      </span>
      <span v-else class="flex-1">
        Восстановление из архива <span class="font-mono">{{ state.pendingRestore.archive }}</span>
        ({{ (state.pendingRestore.labels || []).join(', ') }})
        запланировано: закройте SketchUp сами — изменения применятся, затем откройте его вручную.
      </span>
      <button class="ss-btn-primary !px-2 !py-1 !text-[10px] shrink-0" @click="quitSu">Закрыть SketchUp</button>
      <button class="ss-btn-ghost !px-2 !py-1 !text-[10px] shrink-0" @click="cancelPending">Отменить</button>
    </div>

    <!-- Баннер: результат отложенного применения (показывается после перезапуска) -->
    <div
      v-else-if="pendingResult"
      class="flex items-center gap-2 px-4 py-2 border-b text-xs"
      :class="state.pendingRestore.result.status === 'ok'
        ? 'bg-emerald-50 dark:bg-emerald-950/50 border-emerald-200 dark:border-emerald-900 text-emerald-800 dark:text-emerald-200'
        : 'bg-red-50 dark:bg-red-950/50 border-red-200 dark:border-red-900 text-red-800 dark:text-red-200'"
    >
      <CheckCircle2 v-if="state.pendingRestore.result.status === 'ok'" :size="14" class="shrink-0" />
      <TriangleAlert v-else :size="14" class="shrink-0" />
      <span class="flex-1" :title="(state.pendingRestore.result.lines || []).join('\n')">{{ pendingResultText }}</span>
      <button class="p-0.5 rounded hover:bg-black/5 dark:hover:bg-white/10" title="Скрыть" @click="dismissResult">
        <X :size="14" />
      </button>
    </div>

    <!-- Баннер: отложенная задача прошлой сессии не применилась -->
    <div
      v-else-if="pendingStale"
      class="flex items-center gap-2 px-4 py-2 bg-red-50 dark:bg-red-950/50 border-b border-red-200 dark:border-red-900 text-red-800 dark:text-red-200 text-xs"
    >
      <TriangleAlert :size="14" class="shrink-0" />
      <span class="flex-1">
        Отложенная задача прошлой сессии ({{ state.pendingRestore.kind === 'reset' ? 'сброс' : 'восстановление' }})
        не применилась автоматически: помощник ждёт закрытия SketchUp, а что-то его держит
        (другое открытое окно SketchUp — помощник ждёт все; либо он заблокирован антивирусом/политикой).
        Закройте ВСЕ окна SketchUp всех версий и подождите полминуты; если не помогло —
        повторите операцию. Подготовленные файлы лежат в папке pending_restore хранилища.
      </span>
      <button class="p-0.5 rounded hover:bg-black/5 dark:hover:bg-white/10" title="Убрать" @click="cancelPending">
        <X :size="14" />
      </button>
    </div>

    <!-- Нет tar.exe -->
    <div
      v-if="!state.tarOk"
      class="flex items-center gap-2 px-4 py-2 bg-red-50 dark:bg-red-950/50 border-b border-red-200 dark:border-red-900 text-red-800 dark:text-red-200 text-xs"
    >
      <TriangleAlert :size="14" class="shrink-0" />
      <span class="flex-1">Встроенный zip-движок (tar.exe) не найден — операции с архивами недоступны. Утилита входит в состав Windows 10 (1803+) / Windows 11.</span>
    </div>

    <!-- Вкладки версий SketchUp: текущая — слева, остальные — справа -->
    <div class="flex items-stretch gap-2 px-3 pt-2">
      <div class="flex items-center gap-1 shrink-0">
        <button
          v-if="currentGroup"
          :key="currentGroup.year"
          class="flex items-center gap-1.5 px-3 py-1.5 rounded-t-lg text-xs font-medium border-b-2 -mb-px transition-colors"
          :class="activeYear === currentGroup.year
            ? 'border-brand-500 text-slate-800 dark:text-slate-100'
            : 'border-transparent text-slate-400 hover:text-slate-600 dark:hover:text-slate-200'"
          title="Запущенная версия"
          @click="selectYear(currentGroup.year)"
        >
          SketchUp {{ currentGroup.year }}
          <span class="text-[10px] px-1.5 py-0.5 rounded-full bg-slate-100 dark:bg-slate-800 text-slate-500">{{ (currentGroup.history || []).length }}</span>
          <span
            class="text-[10px] px-1.5 py-0.5 rounded-full font-medium bg-brand-100 text-brand-700 dark:bg-brand-900/60 dark:text-brand-300"
          >
            текущая
          </span>
        </button>
      </div>
      <div class="w-px self-stretch bg-slate-200 dark:bg-slate-700/60 shrink-0"></div>
      <div class="flex items-center gap-1 flex-1 min-w-0 overflow-x-auto">
        <button
          v-for="group in otherGroups"
          :key="group.year"
          class="flex items-center gap-1.5 px-3 py-1.5 rounded-t-lg text-xs font-medium border-b-2 -mb-px transition-colors whitespace-nowrap"
          :class="activeYear === group.year
            ? 'border-brand-500 text-slate-800 dark:text-slate-100'
            : 'border-transparent text-slate-400 hover:text-slate-600 dark:hover:text-slate-200'"
          :title="`Настройки и копии SketchUp ${group.year}`"
          @click="selectYear(group.year)"
        >
          SketchUp {{ group.year }}
          <span class="text-[10px] px-1.5 py-0.5 rounded-full bg-slate-100 dark:bg-slate-800 text-slate-500">{{ (group.history || []).length }}</span>
        </button>
        <span v-if="!otherGroups.length" class="text-[10px] text-slate-400 px-1">других версий нет</span>
      </div>
      <span class="ml-auto text-[10px] text-slate-400 shrink-0 self-center">всего копий: {{ totalHistoryCount }}</span>
    </div>

    <!-- Основная область: история активной версии -->
    <main class="flex-1 min-h-0 overflow-y-auto p-3">
      <section class="ss-card flex flex-col min-h-0 overflow-hidden">
        <div class="flex items-center gap-1 px-3.5 pt-3 pb-2.5 border-b border-slate-100 dark:border-slate-800">
          <h2 class="text-xs font-semibold uppercase tracking-wide">История сохранений</h2>
          <span class="text-[10px] px-1.5 py-0.5 rounded-full bg-slate-100 dark:bg-slate-800 text-slate-500">{{ activeHistory.length }}</span>
          <div class="ml-auto flex items-center gap-0.5">
            <button
              class="p-1.5 rounded-lg"
              :class="historyView === 'rows'
                ? 'bg-slate-100 dark:bg-slate-800 text-slate-600 dark:text-slate-200'
                : 'text-slate-400 hover:text-slate-600 dark:hover:text-slate-200 hover:bg-slate-100 dark:hover:bg-slate-800'"
              title="Вид: строки — один архив в строке, действия при наведении"
              @click="setHistoryView('rows')"
            >
              <List :size="14" />
            </button>
            <button
              class="p-1.5 rounded-lg"
              :class="historyView === 'cards'
                ? 'bg-slate-100 dark:bg-slate-800 text-slate-600 dark:text-slate-200'
                : 'text-slate-400 hover:text-slate-600 dark:hover:text-slate-200 hover:bg-slate-100 dark:hover:bg-slate-800'"
              title="Вид: карточки — дата, тип, комментарий и кнопки на каждой"
              @click="setHistoryView('cards')"
            >
              <LayoutGrid :size="14" />
            </button>
            <button v-if="activeGroup?.current" class="ss-btn-ghost !px-2.5 !py-1 !text-[11px] whitespace-nowrap ml-1" title="Какие пути включать в резервную копию" @click="settingsOpen = true">
              <ListChecks :size="13" />
              Что сохранять
            </button>
          </div>
        </div>
        <div v-if="activeGroup?.current" class="px-3 py-2.5 border-b border-slate-100 dark:border-slate-800 space-y-2">
          <div class="flex items-center gap-2">
            <input
              v-model="comment"
              type="text"
              class="ss-input flex-1"
              placeholder="Комментарий к копии (необязательно)"
              @keyup.enter="doCreate"
            >
            <button class="ss-btn-primary whitespace-nowrap" :disabled="!canCreate" @click="doCreate">
              <Loader2 v-if="state.busy === 'create'" :size="15" class="animate-spin" />
              <Save v-else :size="15" />
              Создать резервную копию
            </button>
          </div>
          <p class="text-[10px] text-slate-400 leading-snug">
            Сохраняет отмеченные в «Что сохранять» пути ({{ selectedCount }}) в zip-архив.
            Копия попадёт в историю текущей версии.
          </p>
        </div>
        <div class="flex-1 overflow-y-auto p-2">
          <div
            v-if="!activeHistory.length"
            class="px-2 py-3 text-center text-[11px] text-slate-400 dark:text-slate-600"
          >
            {{ activeGroup && !activeGroup.store_exists ? 'Хранилище этой версии не найдено — сохранений не было' : 'В этой версии сохранений нет' }}
          </div>
          <HistoryList
            :entries="activeHistory"
            :view="historyView"
            @restore="openRestore"
            @log="openLog"
            @reveal="onRevealEntry"
            @del="askDelete"
          />
          <div
            v-if="!activeHistory.length && activeGroup?.current"
            class="flex flex-col items-center justify-center gap-1.5 py-6 text-slate-400 dark:text-slate-600"
          >
            <Archive :size="28" />
            <span class="text-xs">Пока нет сохранений — создайте первую резервную копию</span>
          </div>
        </div>
      </section>
    </main>

    <!-- Подвал: слева сброс к заводским настройкам, справа импорт и папка копий -->
    <footer class="flex items-center gap-1.5 px-4 py-1.5 border-t border-slate-200 dark:border-slate-800">
      <span class="text-[10px] text-slate-400 mr-1 shrink-0">Сброс:</span>
      <button
        class="ss-btn-ghost !px-2.5 !py-1 !text-[11px] whitespace-nowrap"
        :disabled="resetBlocked || !resetTargetsState.private_prefs"
        title="Вернуть вид SketchUp к заводскому: PrivatePreferences.json будет удалён после того как вы сами закроете SketchUp (перед этим — принудительная резервная копия). Затем откройте SketchUp вручную"
        @click="openReset('private_prefs')"
      >
        <RotateCw :size="12" />
        Сброс интерфейса
      </button>
      <button
        class="ss-btn-ghost !px-2.5 !py-1 !text-[11px] whitespace-nowrap"
        :disabled="resetBlocked || !resetTargetsState.plugins"
        title="Удалить все установленные расширения, кроме самого Save Settings: папка Plugins будет очищена после того как вы сами закроете SketchUp (перед этим — принудительная резервная копия). Затем откройте SketchUp вручную"
        @click="openReset('plugins')"
      >
        <PackageX :size="12" />
        Сброс плагинов
      </button>
      <button
        class="ss-btn-ghost !px-2.5 !py-1 !text-[11px] whitespace-nowrap"
        :disabled="resetBlocked || !resetTargetsState.private_prefs || !resetTargetsState.plugins"
        title="Сбросить и интерфейс, и плагины: PrivatePreferences.json будет удалён, папка Plugins очищена (кроме самого Save Settings) после того как вы сами закроете SketchUp. Затем откройте SketchUp вручную"
        @click="openReset(['private_prefs', 'plugins'])"
      >
        <Eraser :size="12" />
        Сбросить всё
      </button>
      <div class="ml-auto flex items-center gap-1 shrink-0">
        <button class="ss-btn-ghost !px-2.5 !py-1 !text-[11px] whitespace-nowrap" :disabled="!state.tarOk || !!state.busy || isLocked" title="Импортировать zip-архив с диска" @click="importZip">
          <Upload :size="13" />
          Импорт zip
        </button>
        <button class="p-1.5 rounded-lg text-slate-500 hover:bg-slate-100 dark:hover:bg-slate-800" title="Открыть папку резервных копий" @click="openBackupsFolder">
          <FolderOpen :size="15" />
        </button>
      </div>
    </footer>

    <!-- Модал справки -->
    <HelpModal :open="helpOpen" @close="helpOpen = false" />

    <!-- Модал состава копии: выбор путей для копии текущей версии -->
    <Modal :open="settingsOpen" title="Что сохранять" max-width="max-w-lg" body-class="max-h-[70vh]" @close="settingsOpen = false">
      <div class="space-y-2">
        <div class="px-1 py-1">
          <label
            v-for="t in state.targets"
            :key="t.key"
            class="flex items-center gap-2.5 px-2 py-1.5 rounded-lg cursor-pointer hover:bg-slate-50 dark:hover:bg-slate-800/60"
            :class="{ 'opacity-45': !t.exists }"
          >
            <input
              type="checkbox"
              class="accent-brand-500 w-3.5 h-3.5 shrink-0"
              :checked="(selectedKeys || []).includes(t.key)"
              :disabled="!t.exists || isLocked"
              @change="toggleKey(t.key)"
            >
            <span class="min-w-0 flex-1">
              <span class="block text-xs font-medium leading-tight truncate">{{ t.label }}</span>
              <span class="block text-[10px] text-slate-400 truncate" :title="t.path">{{ t.path }}</span>
              <span
                v-if="t.kind === 'file' && t.modified"
                class="block text-[10px] text-slate-400"
                title="На диске — состояние последней записи SketchUp: изменения текущей сессии могли ещё не попасть в файл"
              >
                на диске изменён {{ formatDate(t.modified) }}
              </span>
            </span>
            <span class="text-[10px] text-slate-400 shrink-0 tabular-nums">{{ t.exists ? formatBytes(t.size) : 'нет' }}</span>
          </label>
        </div>
        <p class="text-[10px] text-slate-400 leading-snug">
          Отметьте, что сохранять. Выбрано: {{ selectedCount }}.
        </p>
      </div>
      <template #footer>
        <button class="ss-btn-primary" @click="settingsOpen = false">Готово</button>
      </template>
    </Modal>

    <!-- Модал настроек расширения -->
    <Modal :open="extSettingsOpen" title="Настройки расширения" max-width="max-w-lg" @close="extSettingsOpen = false">
      <div class="space-y-3">
        <div class="space-y-2">
          <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">Папка архивов</h4>
          <p class="text-[11px] text-slate-500 leading-snug">Куда сохранять новые копии и где прежде всего искать существующие.</p>
          <div class="p-2.5 rounded-lg bg-slate-50 dark:bg-slate-800/60">
            <span
              class="inline-block text-[10px] px-1.5 py-0.5 rounded-full font-medium"
              :class="state.archiveDirCustom
                ? 'bg-violet-100 text-violet-700 dark:bg-violet-900/60 dark:text-violet-300'
                : 'bg-slate-200/70 text-slate-500 dark:bg-slate-800 dark:text-slate-400'"
            >
              {{ state.archiveDirCustom ? 'своё расположение' : 'по умолчанию' }}
            </span>
            <div class="mt-1.5 font-mono text-[11px] break-all text-slate-600 dark:text-slate-300">{{ state.backupsPath || '—' }}</div>
            <div v-if="state.archiveDirCustom" class="mt-1 text-[10px] text-slate-400">
              Стандартная папка: <span class="font-mono break-all">{{ state.defaultBackupsPath }}</span>
            </div>
          </div>
          <div class="flex items-center gap-1.5">
            <button v-if="state.archiveDirCustom" class="ss-btn-ghost" :disabled="isLocked" @click="resetArchiveDir">
              <RotateCw :size="13" />
              Сбросить
            </button>
            <button class="ss-btn-primary" :disabled="isLocked" @click="chooseArchiveDir">
              <FolderOpen :size="14" />
              Выбрать папку…
            </button>
            <button class="ss-btn-ghost" @click="dirModal = true">Подробнее</button>
          </div>
        </div>

        <div class="space-y-1.5">
          <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">Сведения</h4>
          <div class="text-[11px] text-slate-500 space-y-1">
            <div>Расширение: <span class="font-mono">Save Settings v{{ state.version }}</span></div>
            <div>SketchUp: <span class="font-mono">{{ state.suYear }} · {{ state.suVersion }}</span> · {{ state.user }}</div>
            <div>Хранилище: <span class="font-mono break-all">{{ state.storePath || '—' }}</span></div>
            <div>История: <span class="font-mono break-all">{{ state.historyPath || '—' }}</span></div>
            <div>Zip-движок (tar.exe): {{ state.tarOk ? 'доступен' : 'НЕ НАЙДЕН' }}</div>
          </div>
        </div>
      </div>
      <template #footer>
        <button class="ss-btn-primary" @click="extSettingsOpen = false">Готово</button>
      </template>
    </Modal>

    <!-- Модал восстановления -->
    <Modal :open="!!restoreModal" title="Восстановление из архива" max-width="max-w-lg" @close="restoreModal = null">
      <div v-if="restoreModal" class="space-y-2">
        <div class="font-mono text-xs break-all text-slate-600 dark:text-slate-300">{{ restoreModal.file }}</div>
        <div class="text-xs text-slate-500">
          Сохранён: {{ formatDate(restoreModal.created_at) }} · SketchUp {{ restoreModal.su_version }}
          <span v-if="restoreModal.store_year && restoreModal.store_year !== String(state.suYear)">
            (хранилище {{ restoreModal.store_year }} → текущая {{ state.suYear }})
          </span>
        </div>
        <div v-if="restoreModal.comment" class="text-xs italic text-slate-500">«{{ restoreModal.comment }}»</div>

        <div
          v-if="restoreModal.store_year && restoreModal.store_year !== String(state.suYear)"
          class="flex items-start gap-2 p-2.5 rounded-lg bg-violet-50 dark:bg-violet-950/40 text-violet-800 dark:text-violet-200 text-[11px] leading-snug"
        >
          <TriangleAlert :size="13" class="shrink-0 mt-0.5" />
          <span>
            Копия из SketchUp {{ restoreModal.store_year }} переносится в SketchUp {{ state.suYear }}:
            файлы настроек и папки лягут на текущие каталоги. Расширения (Plugins) другой версии
            могут быть несовместимы — проверьте их после перезапуска.
          </span>
        </div>

        <div
          v-if="restoreBlocked"
          class="flex items-start gap-2 p-2.5 rounded-lg bg-red-50 dark:bg-red-950/40 text-red-800 dark:text-red-200 text-[11px] leading-snug"
        >
          <TriangleAlert :size="13" class="shrink-0 mt-0.5" />
          <span>{{ restoreBlockReason }} Восстановление архива из более новой версии SketchUp запрещено.</span>
        </div>

        <div
          v-if="restoreUnknownAllowed"
          class="flex items-start gap-2 p-2.5 rounded-lg bg-amber-50 dark:bg-amber-950/40 text-amber-800 dark:text-amber-200 text-[11px] leading-snug"
        >
          <TriangleAlert :size="13" class="shrink-0 mt-0.5" />
          <span>
            Версию SketchUp архива определить нельзя (архив загружен через импорт) —
            восстановление разрешено, но на ваш риск: проверьте результат после перезапуска.
          </span>
        </div>

        <div class="mt-2 space-y-1">
          <div class="text-[10px] uppercase tracking-wide text-slate-400">Что восстановить</div>
          <label
            v-for="t in restoreModal.targets"
            :key="t.key + t.name"
            class="flex items-start gap-2 rounded-lg px-2 py-1.5 cursor-pointer hover:bg-slate-50 dark:hover:bg-slate-800/60"
            :title="targetHints[t.key] || ''"
          >
            <input
              type="checkbox"
              class="accent-brand-500 w-3.5 h-3.5 mt-0.5 shrink-0"
              :checked="(restoreModal.selected || []).includes(t.key)"
              @change="toggleRestoreKey(t.key)"
            >
            <span class="min-w-0 flex-1">
              <span class="flex items-center gap-1.5 text-xs leading-tight">
                <CheckCircle2 :size="13" class="text-emerald-500 shrink-0" />
                <span class="truncate">{{ t.label || t.name }}</span>
              </span>
              <span v-if="targetHints[t.key]" class="block text-[10px] text-slate-400 leading-snug">{{ targetHints[t.key] }}</span>
            </span>
          </label>
          <div v-if="restoreIsPartial" class="text-[10px] text-slate-400 px-2">
            Частичное восстановление: {{ restoreSelectedCount }} из {{ (restoreModal.targets || []).length }}
          </div>
        </div>

        <div
          v-if="(restoreModal.native || []).length"
          class="flex items-start gap-2 p-2.5 rounded-lg bg-red-50 dark:bg-red-950/40 text-red-800 dark:text-red-200 text-[11px] leading-snug"
        >
          <TriangleAlert :size="13" class="shrink-0 mt-0.5" />
          <span>
            В архиве есть нативные бинарники ({{ restoreModal.native.length }}):
            <span class="font-mono break-all">{{ restoreModal.native.slice(0, 3).join(', ') }}{{ restoreModal.native.length > 3 ? ', …' : '' }}</span>
            Они собраны под другую версию SketchUp и могут не загрузиться — после перезапуска
            проверьте расширения, при проблемах снимите галочку с Plugins выше.
          </span>
        </div>

        <label class="flex items-start gap-2 mt-3 p-2.5 rounded-lg bg-slate-50 dark:bg-slate-800/60 cursor-pointer">
          <input v-model="restoreModal.autoBackup" type="checkbox" class="accent-brand-500 w-3.5 h-3.5 mt-0.5 shrink-0">
          <span class="text-xs leading-snug">
            Сначала сохранить текущие настройки
            <span class="block text-[10px] text-slate-400">Автоматическая копия состояния перед восстановлением (рекомендуется)</span>
          </span>
        </label>

        <div
          v-if="hasPlugins"
          class="flex items-start gap-2 p-2.5 rounded-lg bg-amber-50 dark:bg-amber-950/40 text-amber-800 dark:text-amber-200 text-[11px] leading-snug"
        >
          <TriangleAlert :size="13" class="shrink-0 mt-0.5" />
          <span>В архив включены расширения (Plugins): в копию попадает и сам плагин. Применение — после того как вы сами закроете SketchUp, затем откройте его вручную.</span>
        </div>

        <div
          class="flex items-start gap-2 p-2.5 rounded-lg bg-sky-50 dark:bg-sky-950/40 text-sky-800 dark:text-sky-200 text-[11px] leading-snug"
        >
          <Clock3 :size="13" class="shrink-0 mt-0.5" />
          <span>
            Восстановление применяется после того как вы сами закроете SketchUp —
            и файлы настроек, и папки: в работающем SketchUp настройки перезаписываются
            при выходе, а файлы расширений заняты. После применения откройте SketchUp вручную.
            До перезагрузки настройки заблокированы.
          </span>
        </div>

        <div
          v-if="hasDirs"
          class="flex items-start gap-2 p-2.5 rounded-lg bg-amber-50 dark:bg-amber-950/40 text-amber-800 dark:text-amber-200 text-[11px] leading-snug"
        >
          <TriangleAlert :size="13" class="shrink-0 mt-0.5" />
          <span>
            Каталоги применяются сразу и полностью вступают в силу после перезапуска SketchUp.
          </span>
        </div>
      </div>
      <template #footer>
        <button class="ss-btn-ghost" @click="restoreModal = null">Отмена</button>
        <button class="ss-btn-primary" :disabled="!!state.busy || !restoreSelectedCount || isLocked || restoreBlocked" @click="doRestore">
          <ArchiveRestore :size="14" />
          {{ restoreIsPartial ? `Восстановить выбранное (${restoreSelectedCount})` : 'Восстановить' }}
        </button>
      </template>
    </Modal>

    <!-- Модал лога архивации -->
    <Modal :open="!!logModal" title="Лог архивации" max-width="max-w-2xl" @close="logModal = null">
      <div v-if="logModal" class="space-y-2">
        <div class="font-mono text-xs break-all text-slate-600 dark:text-slate-300">{{ logModal.file }}</div>
        <div v-if="logModal.log === undefined" class="flex items-center justify-center py-6">
          <Loader2 :size="20" class="animate-spin text-brand-500" />
        </div>
        <div
          v-else-if="logModal.log === null"
          class="flex items-start gap-2 p-2.5 rounded-lg bg-amber-50 dark:bg-amber-950/40 text-amber-800 dark:text-amber-200 text-[11px] leading-snug"
        >
          <TriangleAlert :size="13" class="shrink-0 mt-0.5" />
          <span>
            {{ logModal.failed
              ? 'Не удалось прочитать лог из архива.'
              : 'В этом архиве нет лога — архив создан старой версией расширения (до v0.3.0) или другим инструментом. Лог есть у всех архивов, созданных начиная с v0.3.0.' }}
          </span>
        </div>
        <pre
          v-else
          class="font-mono text-[11px] leading-snug whitespace-pre-wrap break-words bg-slate-50 dark:bg-slate-800/60 rounded-lg p-2.5 text-slate-700 dark:text-slate-200"
        >{{ logModal.log }}</pre>
      </div>
      <template #footer>
        <button class="ss-btn-ghost" @click="logModal = null">Закрыть</button>
      </template>
    </Modal>

    <!-- Модал удаления -->
    <Modal :open="!!confirmDelete" title="Удалить архив?" max-width="max-w-sm" @close="confirmDelete = null">
      <p class="text-xs leading-relaxed">
        Архив <span class="font-mono break-all text-slate-600 dark:text-slate-300">{{ confirmDelete?.file }}</span>
        <span v-if="confirmDelete?.store_year"> (хранилище SketchUp {{ confirmDelete.store_year }})</span>
        будет удалён с диска безвозвратно. Запись истории будет удалена вместе с ним.
      </p>
      <template #footer>
        <button class="ss-btn-ghost" @click="confirmDelete = null">Отмена</button>
        <button class="ss-btn text-red-600 bg-red-50 hover:bg-red-100 dark:bg-red-950/50 dark:text-red-300" @click="doDelete">
          <Trash2 :size="14" />
          Удалить
        </button>
      </template>
    </Modal>

    <!-- Модал сброса к заводским настройкам -->
    <Modal :open="!!resetModal" :title="resetTitle" max-width="max-w-md" @close="resetModal = null">
      <div v-if="resetModal" class="space-y-2.5">
        <p class="text-xs leading-relaxed">
          <template v-if="resetIsAll">
            Файл <span class="font-mono text-slate-600 dark:text-slate-300">PrivatePreferences.json</span>
            будет удалён: вид SketchUp (панели инструментов, окна, раскладка) вернётся
            к заводскому. Содержимое папки
            <span class="font-mono text-slate-600 dark:text-slate-300">Plugins</span>
            будет очищено: все установленные расширения будут удалены,
            кроме самого Save Settings.
          </template>
          <template v-else-if="resetModal.keys[0] === 'plugins'">
            Содержимое папки <span class="font-mono text-slate-600 dark:text-slate-300">Plugins</span>
            будет очищено: все установленные расширения будут удалены,
            кроме самого Save Settings.
          </template>
          <template v-else>
            Файл <span class="font-mono text-slate-600 dark:text-slate-300">PrivatePreferences.json</span>
            будет удалён: вид SketchUp (панели инструментов, окна, раскладка)
            вернётся к заводскому при следующем запуске.
          </template>
        </p>

        <div
          class="flex items-start gap-2 p-2.5 rounded-lg bg-sky-50 dark:bg-sky-950/40 text-sky-800 dark:text-sky-200 text-[11px] leading-snug"
        >
          <Clock3 :size="13" class="shrink-0 mt-0.5" />
          <span>
            Перед сбросом будет <span class="font-semibold">принудительно</span> создана резервная копия
            текущего состояния. Изменения применятся после того как вы сами закроете SketchUp
            (кнопка «Закрыть SketchUp» в баннере). До перезагрузки настройки заблокированы.
          </span>
        </div>

        <div
          v-if="resetModal.keys.includes('plugins')"
          class="flex items-start gap-2 p-2.5 rounded-lg bg-amber-50 dark:bg-amber-950/40 text-amber-800 dark:text-amber-200 text-[11px] leading-snug"
        >
          <TriangleAlert :size="13" class="shrink-0 mt-0.5" />
          <span>
            Будут удалены все установленные расширения, кроме самого Save Settings —
            оно останется на месте и в меню SketchUp. Вернуть остальные расширения можно
            восстановлением созданной копии (папка Plugins) в SketchUp.
          </span>
        </div>

        <div
          class="flex items-start gap-2 p-2.5 rounded-lg bg-amber-50 dark:bg-amber-950/40 text-amber-800 dark:text-amber-200 text-[11px] leading-snug"
        >
          <TriangleAlert :size="13" class="shrink-0 mt-0.5" />
          <span>
            После подтверждения закройте SketchUp сами кнопкой «Закрыть SketchUp» в баннере —
            изменения применятся, затем откройте его вручную.
            Если модель не сохранена — SketchUp предложит сохранить изменения.
          </span>
        </div>
      </div>
      <template #footer>
        <button class="ss-btn-ghost" @click="resetModal = null">Отмена</button>
        <button class="ss-btn text-red-600 bg-red-50 hover:bg-red-100 dark:bg-red-950/50 dark:text-red-300" :disabled="!canResetNow" @click="doReset">
          <RotateCw :size="14" />
          Сбросить
        </button>
      </template>
    </Modal>

    <!-- Модал «Папка архивов» -->
    <Modal :open="dirModal" title="Папка архивов" max-width="max-w-lg" @close="dirModal = false">
      <div class="space-y-3">
        <p class="text-xs text-slate-500 leading-snug">
          Куда сохранять новые резервные копии и где прежде всего искать существующие.
        </p>

        <div class="p-2.5 rounded-lg bg-slate-50 dark:bg-slate-800/60">
          <span
            class="inline-block text-[10px] px-1.5 py-0.5 rounded-full font-medium"
            :class="state.archiveDirCustom
              ? 'bg-violet-100 text-violet-700 dark:bg-violet-900/60 dark:text-violet-300'
              : 'bg-slate-200/70 text-slate-500 dark:bg-slate-800 dark:text-slate-400'"
          >
            {{ state.archiveDirCustom ? 'своё расположение' : 'по умолчанию' }}
          </span>
          <div class="mt-1.5 font-mono text-[11px] break-all text-slate-600 dark:text-slate-300">{{ state.backupsPath || '—' }}</div>
          <div v-if="state.archiveDirCustom" class="mt-1 text-[10px] text-slate-400">
            Стандартная папка: <span class="font-mono break-all">{{ state.defaultBackupsPath }}</span>
          </div>
        </div>

        <div
          v-if="!state.archiveDirCustom"
          class="flex items-start gap-2 p-2.5 rounded-lg bg-amber-50 dark:bg-amber-950/40 text-amber-800 dark:text-amber-200 text-[11px] leading-snug"
        >
          <TriangleAlert :size="13" class="shrink-0 mt-0.5" />
          <span>
            Папка по умолчанию находится внутри профиля SketchUp
            (<span class="font-mono">%APPDATA%\SketchUp\…</span>): при удалении SketchUp
            с компьютера она будет удалена вместе со всеми архивами. Для долговременного
            хранения выберите папку вне каталогов SketchUp.
          </span>
        </div>

        <div class="flex items-start gap-2 p-2.5 rounded-lg bg-sky-50 dark:bg-sky-950/40 text-sky-800 dark:text-sky-200 text-[11px] leading-snug">
          <TriangleAlert :size="13" class="shrink-0 mt-0.5" />
          <span>
            История сохранений остаётся в хранилище расширения, архивы из прежней папки
            остаются доступны (восстановление, удаление). Не выбирайте папку внутри
            каталогов SketchUp (Materials, Plugins, …) — архив захватывал бы сам себя.
          </span>
        </div>
      </div>
      <template #footer>
        <button v-if="state.archiveDirCustom" class="ss-btn-ghost" :disabled="isLocked" @click="resetArchiveDir">
          <RotateCw :size="13" />
          Сбросить
        </button>
        <button class="ss-btn-ghost" @click="dirModal = false">Закрыть</button>
        <button class="ss-btn-primary" :disabled="isLocked" @click="chooseArchiveDir">
          <FolderOpen :size="14" />
          Выбрать папку…
        </button>
      </template>
    </Modal>

    <!-- Индикатор длительной операции -->
    <div v-if="state.busy" class="fixed inset-0 z-40 flex items-center justify-center bg-slate-900/30 dark:bg-black/40">
      <div class="ss-card px-6 py-5 flex flex-col items-center gap-2 shadow-xl w-[340px]">
        <Loader2 :size="26" class="animate-spin text-brand-500" />
        <div class="text-sm font-medium">
          {{ state.busy === 'create' ? 'Создание резервной копии…' : state.busy === 'reset' ? 'Подготовка сброса (создание резервной копии)…' : 'Восстановление настроек…' }}
        </div>
        <!-- Прогресс создания копии: что делает + шкала -->
        <template v-if="state.busy === 'create'">
          <div class="w-full h-2 rounded-full bg-slate-200 dark:bg-slate-700 overflow-hidden">
            <div
              class="h-full rounded-full bg-brand-500 transition-all duration-200"
              :style="{ width: `${state.progress?.percent ?? 2}%` }"
            />
          </div>
          <div class="w-full text-[11px] text-slate-500 dark:text-slate-400 text-center leading-snug">
            <span v-if="state.progress?.stage === 'copy' && state.progress.total">
              Копирование: {{ state.progress.label }} ({{ state.progress.current }}/{{ state.progress.total }})
            </span>
            <span v-else>{{ state.progress?.label || 'Подготовка…' }}</span>
          </div>
        </template>
        <div class="text-[11px] text-slate-400">Не закрывайте SketchUp до завершения операции</div>
      </div>
    </div>

    <Toast />
  </div>
</template>
