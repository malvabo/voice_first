import { cp, mkdir } from 'node:fs/promises'
import { join } from 'node:path'

const root = process.cwd()
const extensionDir = join(root, 'extension')
const outputDir = join(root, 'dist', 'extension')

await mkdir(outputDir, { recursive: true })

for (const file of [
  'manifest.json',
  'popup.html',
  'popup.css',
  'popup.js',
  'content.css',
  'content.js',
]) {
  await cp(join(extensionDir, file), join(outputDir, file))
}
