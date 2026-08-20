import { defineConfig } from 'vite'

export default defineConfig({
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    rollupOptions: {
      input: 'src/background/serviceWorker.ts',
      output: {
        entryFileNames: 'background.js',
        format: 'iife'
      }
    }
  }
})
