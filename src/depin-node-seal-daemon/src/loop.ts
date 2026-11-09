export type Schedule = (cb: () => void, ms: number) => ReturnType<typeof setTimeout>

/**
 * Non-overlapping cadence. The next delay starts only after the current pass finishes.
 * Uses a single delayed callback. A repeating timer API is not used.
 */
export function startSealLoop(input: {
  intervalMs: number
  run: () => Promise<void>
  schedule?: Schedule
}): () => void {
  const schedule = input.schedule ?? setTimeout
  let timer: ReturnType<typeof setTimeout> | undefined
  let stopped = false
  const kick = (): void => {
    if (stopped) return
    timer = schedule(() => {
      void input.run().finally(() => kick())
    }, input.intervalMs)
  }
  void input.run().finally(() => kick())
  return () => {
    stopped = true
    if (timer) clearTimeout(timer)
  }
}
