<script setup>
import { ArchiveRestore, Clock3, Eye, FileText, Trash2 } from 'lucide-vue-next'
import { state } from '../composables/useSketchupBridge'
import { formatBytes, formatDate, kindInfo, entryTitle, storeYearOf, isForeignEntry } from '../composables/historyUtils'

defineProps({
  entries: { type: Array, default: () => [] },
  view: { type: String, default: 'rows' } // 'rows' | 'cards'
})

defineEmits(['restore', 'log', 'reveal', 'del'])
</script>

<template>
  <div :class="view === 'rows' ? 'space-y-0.5' : 'space-y-1.5'">
    <!-- Вид «строки»: один архив — одна строка; действия появляются при наведении -->
    <template v-if="view === 'rows'">
      <div
        v-for="entry in entries"
        :key="entry.file"
        class="group/entry relative flex items-center gap-2 rounded-lg px-2.5 py-1.5 hover:bg-slate-100/70 dark:hover:bg-slate-800/60 transition-colors"
        :title="entryTitle(entry)"
      >
        <Clock3 :size="13" class="text-slate-400 shrink-0" />
        <span class="min-w-0 flex-1 break-all text-[11px] leading-snug font-mono text-slate-600 dark:text-slate-300">{{ entry.file }}</span>
        <span
          v-if="isForeignEntry(entry)"
          class="shrink-0 text-[10px] px-1.5 py-0.5 rounded-full font-medium bg-violet-100 text-violet-700 dark:bg-violet-900/60 dark:text-violet-300"
          :title="`Копия из SketchUp ${storeYearOf(entry)} — восстановится в текущую ${state.suYear}`"
        >
          из {{ storeYearOf(entry) }}
        </span>
        <span class="shrink-0 text-xs tabular-nums text-slate-500 dark:text-slate-400">{{ formatDate(entry.created_at) }}</span>
        <span class="w-14 shrink-0 text-right text-[11px] tabular-nums text-slate-400">{{ formatBytes(entry.size) }}</span>
        <!-- Действия строки появляются при наведении; подложка повторяет фон
             строки и растворяется градиентом, гася метаданные под кнопками -->
        <div class="absolute inset-y-0 right-0 hidden group-hover/entry:flex items-center gap-1 rounded-lg pr-1.5 pl-10 bg-gradient-to-l from-slate-100/70 via-slate-100/70 to-transparent dark:from-slate-800/60 dark:via-slate-800/60">
          <button class="ss-btn-primary !px-2 !py-1 !text-[11px]" :disabled="!state.tarOk || !!state.busy" @click="$emit('restore', entry)">
            <ArchiveRestore :size="12" />
            Восстановить
          </button>
          <button class="p-1.5 rounded-lg text-slate-400 hover:text-slate-600 dark:hover:text-slate-200 hover:bg-slate-200/70 dark:hover:bg-slate-700" title="Лог архивации" :disabled="!state.tarOk" @click="$emit('log', entry)">
            <FileText :size="14" />
          </button>
          <button class="p-1.5 rounded-lg text-slate-400 hover:text-slate-600 dark:hover:text-slate-200 hover:bg-slate-200/70 dark:hover:bg-slate-700" title="Показать в папке" @click="$emit('reveal', entry)">
            <Eye :size="14" />
          </button>
          <button class="p-1.5 rounded-lg text-slate-400 hover:text-red-500 hover:bg-red-50 dark:hover:bg-red-950/40" title="Удалить архив" @click="$emit('del', entry)">
            <Trash2 :size="14" />
          </button>
        </div>
      </div>
    </template>
    <!-- Вид «карточки»: дата, тип, комментарий и кнопки — всё на карточке -->
    <template v-else>
      <div
        v-for="entry in entries"
        :key="entry.file"
        class="rounded-lg border border-slate-200 dark:border-slate-800 px-3 py-2 hover:border-brand-300 dark:hover:border-brand-800 transition-colors"
      >
        <div class="flex items-center gap-2">
          <Clock3 :size="13" class="text-slate-400 shrink-0" />
          <span class="text-xs font-semibold tabular-nums">{{ formatDate(entry.created_at) }}</span>
          <span class="text-[10px] px-1.5 py-0.5 rounded-full font-medium" :class="kindInfo[entry.kind]?.cls || 'bg-slate-100 text-slate-500'">
            {{ kindInfo[entry.kind]?.label || entry.kind }}
          </span>
          <span
            v-if="isForeignEntry(entry)"
            class="text-[10px] px-1.5 py-0.5 rounded-full font-medium bg-violet-100 text-violet-700 dark:bg-violet-900/60 dark:text-violet-300"
            :title="`Копия из SketchUp ${storeYearOf(entry)} — восстановится в текущую ${state.suYear}`"
          >
            из {{ storeYearOf(entry) }}
          </span>
          <span class="ml-auto text-[11px] text-slate-400 shrink-0 tabular-nums">{{ formatBytes(entry.size) }}</span>
        </div>
        <div class="mt-1 text-xs text-slate-500 dark:text-slate-400 break-words">
          <span v-if="entry.comment" class="italic">{{ entry.comment }}</span>
          <span v-else>{{ (entry.labels || []).join(', ') || '—' }}</span>
        </div>
        <div class="mt-1.5 flex items-center gap-1">
          <span class="text-[10px] text-slate-400 mr-auto">SU {{ entry.su_version }} · путей: {{ (entry.paths || []).length }}</span>
          <button class="ss-btn-primary !px-2.5 !py-1 !text-xs" :disabled="!state.tarOk || !!state.busy" @click="$emit('restore', entry)">
            <ArchiveRestore :size="13" />
            Восстановить
          </button>
          <button class="p-1.5 rounded-lg text-slate-400 hover:text-slate-600 dark:hover:text-slate-200 hover:bg-slate-100 dark:hover:bg-slate-800" title="Лог архивации" :disabled="!state.tarOk" @click="$emit('log', entry)">
            <FileText :size="14" />
          </button>
          <button class="p-1.5 rounded-lg text-slate-400 hover:text-slate-600 dark:hover:text-slate-200 hover:bg-slate-100 dark:hover:bg-slate-800" title="Показать в папке" @click="$emit('reveal', entry)">
            <Eye :size="14" />
          </button>
          <button class="p-1.5 rounded-lg text-slate-400 hover:text-red-500 hover:bg-red-50 dark:hover:bg-red-950/40" title="Удалить архив" @click="$emit('del', entry)">
            <Trash2 :size="14" />
          </button>
        </div>
      </div>
    </template>
  </div>
</template>
