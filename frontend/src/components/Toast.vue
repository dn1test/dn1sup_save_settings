<script setup>
import { CheckCircle2, AlertTriangle } from 'lucide-vue-next'
import { state } from '../composables/useSketchupBridge'
</script>

<template>
  <transition
    enter-active-class="transition duration-200 ease-out"
    enter-from-class="opacity-0 translate-y-2"
    leave-active-class="transition duration-150 ease-in"
    leave-to-class="opacity-0 translate-y-2"
  >
    <div
      v-if="state.toast"
      class="fixed bottom-4 left-1/2 -translate-x-1/2 z-[60] flex items-center gap-2 px-4 py-2.5 rounded-xl shadow-lg border text-sm max-w-[90%]"
      :class="state.toast.kind === 'ok'
        ? 'bg-emerald-50 dark:bg-emerald-950/80 border-emerald-300 dark:border-emerald-800 text-emerald-800 dark:text-emerald-200'
        : 'bg-red-50 dark:bg-red-950/80 border-red-300 dark:border-red-800 text-red-800 dark:text-red-200'"
    >
      <CheckCircle2 v-if="state.toast.kind === 'ok'" :size="16" class="shrink-0 text-emerald-500" />
      <AlertTriangle v-else :size="16" class="shrink-0 text-red-500" />
      <span class="whitespace-pre-line">{{ state.toast.text }}</span>
    </div>
  </transition>
</template>
