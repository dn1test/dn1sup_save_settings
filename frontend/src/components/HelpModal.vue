<script setup>
import { Clock3, TriangleAlert } from 'lucide-vue-next'
import { state } from '../composables/useSketchupBridge'
import Modal from './Modal.vue'

defineProps({
  open: { type: Boolean, default: false }
})
defineEmits(['close'])
</script>

<template>
  <Modal
    :open="open"
    title="Как пользоваться Save Settings"
    max-width="max-w-2xl"
    body-class="max-h-[72vh]"
    @close="$emit('close')"
  >
    <div class="space-y-4 text-xs leading-relaxed text-slate-600 dark:text-slate-300">
      <section class="space-y-1">
        <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">Что делает расширение</h4>
        <p>
          Save Settings сохраняет параметры SketchUp в zip-архив и возвращает их обратно —
          например, чтобы перенести настройки на другой компьютер или откатить неудачные изменения.
          Сохраняются: настройки интерфейса (<span class="font-mono">PrivatePreferences.json</span>),
          общие настройки (<span class="font-mono">SharedPreferences.json</span>) и папки
          <span class="font-mono">Components</span>, <span class="font-mono">Materials</span>,
          <span class="font-mono">Plugins</span>, <span class="font-mono">Styles</span>,
          <span class="font-mono">Templates</span>.
        </p>
        <p class="text-[11px] text-slate-400">
          Архивы создаются встроенной утилитой Windows (tar.exe) — ничего дополнительно устанавливать не нужно.
        </p>
      </section>

      <section class="space-y-1">
        <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">Создание резервной копии</h4>
        <p>
          На левой панели «Сохранение параметров» отметьте галочками, что сохранять
          (серые пункты отсутствуют на диске), при желании впишите комментарий
          и нажмите <span class="font-semibold">«Создать резервную копию»</span>.
        </p>
      </section>

      <section class="space-y-1">
        <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">Быстрая копия без окна</h4>
        <p>
          Меню <span class="font-mono">Extensions → DN1Sup → Save Settings → «Создать резервную копию настроек»</span>
          сразу сохраняет все существующие пути, не открывая диалог.
        </p>
      </section>

      <section class="space-y-1">
        <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">История сохранений</h4>
        <p>
          На правой панели — все копии с метками: Ручная, Быстрая, Авто (автоматическая копия
          перед восстановлением/сбросом), Импорт. Кнопки у записи:
          <span class="font-semibold">Восстановить</span>,
          <span class="font-semibold">Лог</span> (что и куда записывалось в архив),
          <span class="font-semibold">Показать в папке</span>,
          <span class="font-semibold">Удалить</span>.
        </p>
      </section>

      <section class="space-y-1">
        <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">Восстановление</h4>
        <p>
          Нажмите <span class="font-semibold">«Восстановить»</span> у нужной копии, проверьте состав
          архива и подтвердите. По умолчанию перед восстановлением создаётся автоматическая копия
          текущего состояния — из неё можно вернуться назад.
        </p>
        <div class="flex items-start gap-2 p-2.5 rounded-lg bg-sky-50 dark:bg-sky-950/40 text-sky-800 dark:text-sky-200 text-[11px] leading-snug">
          <Clock3 :size="13" class="shrink-0 mt-0.5" />
          <span>
            Файлы настроек (<span class="font-mono">PrivatePreferences.json</span> /
            <span class="font-mono">SharedPreferences.json</span>) SketchUp перезаписывает при выходе,
            поэтому они применяются отложенно — автоматически сразу после закрытия SketchUp
            (с опцией запуска его заново). Папки (Materials, Styles, …) восстанавливаются сразу;
            полный эффект — после перезапуска SketchUp.
          </span>
        </div>
      </section>

      <section class="space-y-1">
        <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">Импорт zip</h4>
        <p>
          Кнопка <span class="font-semibold">«Импорт zip»</span> в шапке добавляет в историю архив с диска —
          например, перенесённый с другого компьютера.
        </p>
      </section>

      <section class="space-y-1">
        <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">Папка архивов</h4>
        <p>
          Кнопка-карандаш рядом со строкой «Хранилище» выбирает, куда сохранять новые копии.
          По умолчанию архивы лежат в хранилище расширения в профиле пользователя. Не выбирайте
          папку внутри каталогов SketchUp (Materials, Plugins, …) — архив захватывал бы сам себя.
        </p>
      </section>

      <section class="space-y-1">
        <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">Сброс к заводским настройкам</h4>
        <p>
          Кнопки внизу окна: <span class="font-semibold">«Сброс интерфейса»</span> удаляет
          <span class="font-mono">PrivatePreferences.json</span> — вид SketchUp вернётся к заводскому;
          <span class="font-semibold">«Сброс плагинов»</span> очищает папку Plugins, кроме файлов
          самого Save Settings — расширение остаётся на месте.
          Применение — сразу после закрытия SketchUp; перед сбросом принудительно создаётся резервная копия.
        </p>
        <div class="flex items-start gap-2 p-2.5 rounded-lg bg-amber-50 dark:bg-amber-950/40 text-amber-800 dark:text-amber-200 text-[11px] leading-snug">
          <TriangleAlert :size="13" class="shrink-0 mt-0.5" />
          <span>
            «Сброс плагинов» удаляет все расширения, кроме самого Save Settings.
            Вернуть остальные можно восстановлением резервной копии в SketchUp
            (она включает папку Plugins) или установкой .rbz.
          </span>
        </div>
      </section>

      <section class="space-y-1">
        <h4 class="text-xs font-semibold text-slate-800 dark:text-slate-100">Где хранятся данные</h4>
        <p>
          Хранилище (история и архивы по умолчанию):
          <span class="font-mono break-all text-slate-600 dark:text-slate-300">{{ state.storePath || '—' }}</span>.
          Пункт меню «Открыть папку резервных копий» и «Открыть папку логов» открывают их в Проводнике.
        </p>
      </section>
    </div>
    <template #footer>
      <button class="ss-btn-primary" @click="$emit('close')">Понятно</button>
    </template>
  </Modal>
</template>
