import { cp, mkdir, rm } from 'node:fs/promises'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

const exec = promisify(execFile)
const root = new URL('..', import.meta.url)
const rootPath = root.pathname
const targets = ['chrome', 'firefox', 'safari']

await rm(new URL('../dist', import.meta.url), { recursive: true, force: true })
await exec('npx', ['vite', 'build'], { cwd: rootPath })
await mkdir(new URL('../dist', import.meta.url), { recursive: true })
for (const target of targets) {
  await cp(new URL(`../manifest.${target}.json`, import.meta.url), new URL(`../dist/manifest.${target}.json`, import.meta.url))
}
