<script setup>
import { computed, onMounted, ref, watch } from 'vue'
import {
  Archive, ArchiveRestore, CheckCircle2, CircleHelp, Clock3, Eye, FileText, FolderOpen,
  Loader2, Moon, PackageX, Pen, RotateCw, Save, Sun, Trash2, TriangleAlert, Upload, X
} from 'lucide-vue-next'
import {
  state, isMock, toast, loadState, createBackup, restoreBackup, deleteBackup,
  importZip, readArchiveInfo, readArchiveLog, openBackupsFolder, revealBackup, updateFromDev,
  chooseArchiveDir, resetArchiveDir, cancelPendingRestore, dismissRestoreResult, resetTarget
} from './composables/useSketchupBridge'
import { useTheme } from './composables/useTheme'
import Modal from './components/Modal.vue'
import HelpModal from './components/HelpModal.vue'
import Toast from './components/Toast.vue'

const { isDark, toggleTheme } = useTheme()

// -- справка ----------------------------------------------------------------
// Открывается кнопкой «?» в шапке; автопоказ — по одноразовому флагу
// state.showHelp (пункт меню «Справка» в Ruby передаёт его в push_state).

const helpOpen = ref(false)
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
const canCreate = computed(() => state.tarOk && selectedCount.value > 0 && !state.busy)
const comment = ref('')

function formatBytes(bytes) {
  const n = Number(bytes) || 0
  if (n <= 0) return '0 Б'
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ']
  let v = n
  let i = 0
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++ }
  return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`
}

function formatDate(s) {
  // '2026-10-06 18:22:33' → '06.10.2026 18:22'
  const m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})/.exec(s || '')
  return m ? `${m[3]}.${m[2]}.${m[1]} ${m[4]}:${m[5]}` : (s || '')
}

const kindInfo = {
  manual:   { label: 'Ручная',  cls: 'bg-brand-100 text-brand-700 dark:bg-brand-900/60 dark:text-brand-300' },
  quick:    { label: 'Быстрая', cls: 'bg-emerald-100 text-emerald-700 dark:bg-emerald-900/60 dark:text-emerald-300' },
  auto:     { label: 'Авто',    cls: 'bg-amber-100 text-amber-700 dark:bg-amber-900/60 dark:text-amber-300' },
  imported: { label: 'Импорт',  cls: 'bg-violet-100 text-violet-700 dark:bg-violet-900/60 dark:text-violet-300' }
}

function doCreate() {
  if (!canCreate.value) return
  createBackup(comment.value.trim(), selectedKeys.value || [])
}

// -- восстановление -------------------------------------------------------------

const restoreModal = ref(null)

async function openRestore(entry) {
  const info = await readArchiveInfo(entry.file)
  if (!info || !info.manifest) {
    toast('err', 'Не удалось прочитать состав архива')
    return
  }
  restoreModal.value = {
    file: entry.file,
    created_at: info.manifest.created_at || entry.created_at,
    su_version: info.manifest.sketchup_version || entry.su_version,
    comment: info.manifest.comment || entry.comment || '',
    targets: info.manifest.targets || [],
    autoBackup: true,
    relaunch: state.restoreRelaunch !== false
  }
}

function doRestore() {
  const m = restoreModal.value
  if (!m) return
  restoreModal.value = null
  restoreBackup(m.file, m.autoBackup, null, m.relaunch)
}

const hasPlugins = computed(() => (restoreModal.value?.targets || []).some(t => t.key === 'plugins'))
const hasFiles = computed(() => (restoreModal.value?.targets || []).some(t => t.kind === 'file'))
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

function dismissResult() {
  dismissRestoreResult()
}

const confirmDelete = ref(null) // имя файла архива

function doDelete() {
  if (!confirmDelete.value) return
  deleteBackup(confirmDelete.value)
  confirmDelete.value = null
}

// -- сброс к заводским настройкам -------------------------------------------------
// resetModal: { key: 'private_prefs' | 'plugins', relaunch }. Применение —
// отложенное (после закрытия SketchUp), перед сбросом Ruby принудительно
// создаёт резервную копию.

const resetModal = ref(null)

const resetTargetsState = computed(() => ({
  private_prefs: state.targets.find(t => t.key === 'private_prefs')?.exists,
  plugins: state.targets.find(t => t.key === 'plugins')?.exists
}))

const canResetNow = computed(() =>
  state.tarOk && !state.busy && !!resetModal.value
)

const resetTitle = computed(() =>
  resetModal.value?.key === 'plugins' ? 'Сброс плагинов?' : 'Сброс интерфейса?'
)

function openReset(key) {
  resetModal.value = { key, relaunch: state.restoreRelaunch !== false }
}

function doReset() {
  const m = resetModal.value
  if (!m) return
  resetModal.value = null
  resetTarget(m.key, m.relaunch)
}

// -- лог архивации ------------------------------------------------------------------
// log: undefined — чтение из архива, string — текст лога,
// null — в архиве нет лога (старый формат) / не удалось прочитать.

const logModal = ref(null)

async function openLog(entry) {
  logModal.value = { file: entry.file, log: undefined, failed: false }
  const res = await Promise.race([
    readArchiveLog(entry.file),
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
      <div class="w-8 h-8 rounded-lg bg-brand-500 text-white flex items-center justify-center shrink-0">
        <Archive :size="17" />
      </div>
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
        <button class="p-1.5 rounded-lg text-slate-500 hover:bg-slate-100 dark:hover:bg-slate-800" title="Обновить сведения" @click="loadState">
          <RotateCw :size="15" />
        </button>
        <button v-if="!isMock" class="p-1.5 rounded-lg text-slate-500 hover:bg-slate-100 dark:hover:bg-slate-800 text-[10px] font-bold" title="Обновить из dev-папки" @click="updateFromDev">
          DEV
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

    <!-- Баннер: перезапуск после восстановления -->
    <div
      v-if="state.restartBanner"
      class="flex items-center gap-2 px-4 py-2 bg-amber-50 dark:bg-amber-950/50 border-b border-amber-200 dark:border-amber-900 text-amber-800 dark:text-amber-200 text-xs"
    >
      <TriangleAlert :size="14" class="shrink-0" />
      <span class="flex-1">Настройки восстановлены. Перезапустите SketchUp, чтобы изменения вступили в силу полностью.</span>
      <button class="p-0.5 rounded hover:bg-amber-100 dark:hover:bg-amber-900" @click="state.restartBanner = false">
        <X :size="14" />
      </button>
    </div>

    <!-- Баннер: активное отложенное восстановление (применится после закрытия) -->
    <div
      v-if="pendingActive"
      class="flex items-center gap-2 px-4 py-2 bg-sky-50 dark:bg-sky-950/50 border-b border-sky-200 dark:border-sky-900 text-sky-800 dark:text-sky-200 text-xs"
    >
      <Clock3 :size="14" class="shrink-0" />
      <span v-if="state.pendingRestore.kind === 'reset'" class="flex-1">
        Сброс ({{ (state.pendingRestore.labels || []).join(', ') }})
        применится автоматически сразу после закрытия SketchUp.
      </span>
      <span v-else class="flex-1">
        Файлы настроек из архива <span class="font-mono">{{ state.pendingRestore.archive }}</span>
        применятся автоматически сразу после закрытия SketchUp.
      </span>
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
        не применилась автоматически — возможно, helper заблокирован антивирусом или политикой.
        Повторите операцию и закройте SketchUp; подготовленные файлы лежат в папке pending_restore хранилища.
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

    <!-- Основная область -->
    <main class="flex-1 min-h-0 grid grid-cols-[340px_1fr] gap-3 p-3">
      <!-- Сохранение параметров -->
      <section class="ss-card flex flex-col min-h-0 overflow-hidden">
        <div class="px-3.5 pt-3 pb-2.5 border-b border-slate-100 dark:border-slate-800">
          <h2 class="text-xs font-semibold uppercase tracking-wide">Сохранение параметров</h2>
          <div class="mt-0.5 flex items-center gap-1">
            <p class="min-w-0 flex-1 text-[10px] text-slate-400 truncate" :title="state.backupsPath">Хранилище: {{ state.backupsPath }}</p>
            <button
              class="p-1 rounded shrink-0 text-slate-400 hover:text-slate-600 dark:hover:text-slate-200 hover:bg-slate-100 dark:hover:bg-slate-800"
              title="Папка архивов — куда сохранять и где читать"
              @click="dirModal = true"
            >
              <Pen :size="12" />
            </button>
          </div>
        </div>
        <div
          v-if="!state.archiveDirCustom"
          class="flex items-start gap-2 mx-2 mt-2 p-2 rounded-lg bg-amber-50 dark:bg-amber-950/40 text-amber-800 dark:text-amber-200 text-[10px] leading-snug"
        >
          <TriangleAlert :size="12" class="shrink-0 mt-0.5" />
          <span class="flex-1">
            Папка по умолчанию лежит в профиле SketchUp: при удалении SketchUp архивы удалятся вместе с ней.
          </span>
          <button class="ss-btn-ghost !px-1.5 !py-0.5 !text-[10px] shrink-0" title="Выбрать папку вне каталогов SketchUp" @click="chooseArchiveDir">
            Выбрать…
          </button>
        </div>
        <div class="flex-1 overflow-y-auto px-2 py-2">
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
              :disabled="!t.exists"
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
        <div class="p-3 border-t border-slate-100 dark:border-slate-800 space-y-2">
          <input
            v-model="comment"
            type="text"
            class="ss-input"
            placeholder="Комментарий к копии (необязательно)"
            @keyup.enter="doCreate"
          >
          <button class="ss-btn-primary w-full" :disabled="!canCreate" @click="doCreate">
            <Loader2 v-if="state.busy === 'create'" :size="15" class="animate-spin" />
            <Save v-else :size="15" />
            Создать резервную копию
          </button>
        </div>
      </section>

      <!-- История сохранений -->
      <section class="ss-card flex flex-col min-h-0 overflow-hidden">
        <div class="flex items-center px-3.5 pt-3 pb-2.5 border-b border-slate-100 dark:border-slate-800">
          <h2 class="text-xs font-semibold uppercase tracking-wide">История сохранений</h2>
          <span class="ml-2 text-[10px] px-1.5 py-0.5 rounded-full bg-slate-100 dark:bg-slate-800 text-slate-500">{{ state.history.length }}</span>
        </div>
        <div class="flex-1 overflow-y-auto p-2 space-y-1.5">
          <div
            v-for="entry in state.history"
            :key="entry.file"
            class="rounded-lg border border-slate-200 dark:border-slate-800 px-3 py-2 hover:border-brand-300 dark:hover:border-brand-800 transition-colors"
          >
            <div class="flex items-center gap-2">
              <Clock3 :size="13" class="text-slate-400 shrink-0" />
              <span class="text-xs font-semibold tabular-nums">{{ formatDate(entry.created_at) }}</span>
              <span class="text-[10px] px-1.5 py-0.5 rounded-full font-medium" :class="kindInfo[entry.kind]?.cls || 'bg-slate-100 text-slate-500'">
                {{ kindInfo[entry.kind]?.label || entry.kind }}
              </span>
              <span class="ml-auto text-[11px] text-slate-400 shrink-0 tabular-nums">{{ formatBytes(entry.size) }}</span>
            </div>
            <div class="mt-1 text-xs text-slate-500 dark:text-slate-400">
              <span v-if="entry.comment" class="italic">{{ entry.comment }}</span>
              <span v-else class="block truncate">{{ (entry.labels || []).join(', ') || '—' }}</span>
            </div>
            <div class="mt-1.5 flex items-center gap-1">
              <span class="text-[10px] text-slate-400 mr-auto">SU {{ entry.su_version }} · путей: {{ (entry.paths || []).length }}</span>
              <button class="ss-btn-primary !px-2.5 !py-1 !text-xs" :disabled="!state.tarOk || !!state.busy" @click="openRestore(entry)">
                <ArchiveRestore :size="13" />
                Восстановить
              </button>
              <button class="p-1.5 rounded-lg text-slate-400 hover:text-slate-600 dark:hover:text-slate-200 hover:bg-slate-100 dark:hover:bg-slate-800" title="Лог архивации" :disabled="!state.tarOk" @click="openLog(entry)">
                <FileText :size="14" />
              </button>
              <button class="p-1.5 rounded-lg text-slate-400 hover:text-slate-600 dark:hover:text-slate-200 hover:bg-slate-100 dark:hover:bg-slate-800" title="Показать в папке" @click="revealBackup(entry.file)">
                <Eye :size="14" />
              </button>
              <button class="p-1.5 rounded-lg text-slate-400 hover:text-red-500 hover:bg-red-50 dark:hover:bg-red-950/40" title="Удалить архив" @click="confirmDelete = entry.file">
                <Trash2 :size="14" />
              </button>
            </div>
          </div>
          <div
            v-if="!state.history.length"
            class="h-full min-h-[120px] flex flex-col items-center justify-center gap-1.5 text-slate-400 dark:text-slate-600"
          >
            <Archive :size="28" />
            <span class="text-xs">Пока нет сохранений — создайте первую резервную копию</span>
          </div>
        </div>
      </section>
    </main>

    <!-- Подвал: слева сброс к заводским настройкам, справа импорт и папка копий -->
    <footer class="flex items-center gap-1.5 px-4 py-1.5 border-t border-slate-200 dark:border-slate-800">
      <span class="text-[10px] text-slate-400 mr-1">Сброс к заводским настройкам:</span>
      <button
        class="ss-btn-ghost !px-2.5 !py-1 !text-[11px]"
        :disabled="!state.tarOk || !!state.busy || !resetTargetsState.private_prefs"
        title="Вернуть вид SketchUp к заводскому: PrivatePreferences.json будет удалён сразу после закрытия SketchUp (перед этим — принудительная резервная копия)"
        @click="openReset('private_prefs')"
      >
        <RotateCw :size="12" />
        Сброс интерфейса
      </button>
      <button
        class="ss-btn-ghost !px-2.5 !py-1 !text-[11px]"
        :disabled="!state.tarOk || !!state.busy || !resetTargetsState.plugins"
        title="Удалить все установленные расширения, кроме самого Save Settings: папка Plugins будет очищена сразу после закрытия SketchUp (перед этим — принудительная резервная копия)"
        @click="openReset('plugins')"
      >
        <PackageX :size="12" />
        Сброс плагинов
      </button>
      <div class="ml-auto flex items-center gap-1">
        <button class="ss-btn-ghost !px-2.5 !py-1 !text-[11px]" :disabled="!state.tarOk" title="Импортировать zip-архив с диска" @click="importZip">
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

    <!-- Модал восстановления -->
    <Modal :open="!!restoreModal" title="Восстановление из архива" max-width="max-w-lg" @close="restoreModal = null">
      <div v-if="restoreModal" class="space-y-2">
        <div class="font-mono text-xs break-all text-slate-600 dark:text-slate-300">{{ restoreModal.file }}</div>
        <div class="text-xs text-slate-500">
          Сохранён: {{ formatDate(restoreModal.created_at) }} · SketchUp {{ restoreModal.su_version }}
        </div>
        <div v-if="restoreModal.comment" class="text-xs italic text-slate-500">«{{ restoreModal.comment }}»</div>

        <ul class="mt-2 space-y-1">
          <li
            v-for="t in restoreModal.targets"
            :key="t.key + t.name"
            class="flex items-center gap-2 text-xs"
          >
            <CheckCircle2 :size="13" class="text-emerald-500 shrink-0" />
            <span class="truncate">{{ t.label || t.name }}</span>
          </li>
        </ul>

        <label class="flex items-start gap-2 mt-3 p-2.5 rounded-lg bg-slate-50 dark:bg-slate-800/60 cursor-pointer">
          <input v-model="restoreModal.autoBackup" type="checkbox" class="accent-brand-500 w-3.5 h-3.5 mt-0.5 shrink-0">
          <span class="text-xs leading-snug">
            Сначала сохранить текущие настройки
            <span class="block text-[10px] text-slate-400">Автоматическая копия состояния перед восстановлением (рекомендуется)</span>
          </span>
        </label>

        <div
          v-if="hasPlugins"
          class="flex items-start gap-2 p-2.5 rounded-lg bg-sky-50 dark:bg-sky-950/40 text-sky-800 dark:text-sky-200 text-[11px] leading-snug"
        >
          <TriangleAlert :size="13" class="shrink-0 mt-0.5" />
          <span>В архив включены расширения (Plugins): в копию попадает и сам плагин; после восстановления нужен перезапуск SketchUp.</span>
        </div>

        <div
          v-if="hasFiles"
          class="flex items-start gap-2 p-2.5 rounded-lg bg-sky-50 dark:bg-sky-950/40 text-sky-800 dark:text-sky-200 text-[11px] leading-snug"
        >
          <Clock3 :size="13" class="shrink-0 mt-0.5" />
          <span>
            Файлы настроек (PrivatePreferences.json / SharedPreferences.json) применятся
            автоматически сразу после закрытия SketchUp — он перезаписывает их при выходе,
            поэтому применить их в работающем SketchUp нельзя.
          </span>
        </div>

        <label v-if="hasFiles" class="flex items-start gap-2 p-2.5 rounded-lg bg-slate-50 dark:bg-slate-800/60 cursor-pointer">
          <input v-model="restoreModal.relaunch" type="checkbox" class="accent-brand-500 w-3.5 h-3.5 mt-0.5 shrink-0">
          <span class="text-xs leading-snug">
            Запустить SketchUp после применения файлов
            <span class="block text-[10px] text-slate-400">Иначе откройте SketchUp вручную</span>
          </span>
        </label>

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
        <button class="ss-btn-primary" :disabled="!!state.busy" @click="doRestore">
          <ArchiveRestore :size="14" />
          Восстановить
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
        Архив <span class="font-mono break-all text-slate-600 dark:text-slate-300">{{ confirmDelete }}</span>
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
          <template v-if="resetModal.key === 'plugins'">
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
            текущего состояния. Изменения применятся автоматически сразу после закрытия SketchUp.
          </span>
        </div>

        <div
          v-if="resetModal.key === 'plugins'"
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
          v-if="pendingActive"
          class="flex items-start gap-2 p-2.5 rounded-lg bg-amber-50 dark:bg-amber-950/40 text-amber-800 dark:text-amber-200 text-[11px] leading-snug"
        >
          <TriangleAlert :size="13" class="shrink-0 mt-0.5" />
          <span>Уже запланирована другая отложенная операция — сброс заменит её.</span>
        </div>

        <label class="flex items-start gap-2 p-2.5 rounded-lg bg-slate-50 dark:bg-slate-800/60 cursor-pointer">
          <input v-model="resetModal.relaunch" type="checkbox" class="accent-brand-500 w-3.5 h-3.5 mt-0.5 shrink-0">
          <span class="text-xs leading-snug">
            Запустить SketchUp после применения
            <span class="block text-[10px] text-slate-400">Иначе откройте SketchUp вручную</span>
          </span>
        </label>
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
        <button v-if="state.archiveDirCustom" class="ss-btn-ghost" @click="resetArchiveDir">
          <RotateCw :size="13" />
          Сбросить
        </button>
        <button class="ss-btn-ghost" @click="dirModal = false">Закрыть</button>
        <button class="ss-btn-primary" @click="chooseArchiveDir">
          <FolderOpen :size="14" />
          Выбрать папку…
        </button>
      </template>
    </Modal>

    <!-- Индикатор длительной операции -->
    <div v-if="state.busy" class="fixed inset-0 z-40 flex items-center justify-center bg-slate-900/30 dark:bg-black/40">
      <div class="ss-card px-6 py-5 flex flex-col items-center gap-2 shadow-xl">
        <Loader2 :size="26" class="animate-spin text-brand-500" />
        <div class="text-sm font-medium">
          {{ state.busy === 'create' ? 'Создание резервной копии…' : state.busy === 'reset' ? 'Подготовка сброса (создание резервной копии)…' : 'Восстановление настроек…' }}
        </div>
        <div class="text-[11px] text-slate-400">Не закрывайте SketchUp до завершения операции</div>
      </div>
    </div>

    <Toast />
  </div>
</template>
