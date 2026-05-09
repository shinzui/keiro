import fs from 'node:fs/promises'
import path from 'node:path'

const site = path.resolve(process.argv[2] ?? 'site-dist')

async function walk(dir) {
  const out = []
  for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
    const file = path.join(dir, entry.name)
    if (entry.isDirectory()) out.push(...await walk(file))
    else if (entry.name.endsWith('.html')) out.push(file)
  }
  return out
}

const files = await walk(site)
const broken = []

for (const file of files) {
  const html = await fs.readFile(file, 'utf8')
  const base = path.dirname(file)
  for (const [, href] of html.matchAll(/href="([^"]+)"/g)) {
    if (/^(https?:|mailto:|#)/.test(href)) continue
    const [target] = href.split('#')
    if (!target) continue

    let resolved = path.resolve(base, target)
    try {
      const stat = await fs.stat(resolved)
      if (stat.isDirectory()) resolved = path.join(resolved, 'index.html')
      await fs.stat(resolved)
    } catch {
      broken.push(`${path.relative(site, file)} -> ${href}`)
    }
  }
}

if (broken.length > 0) {
  console.error(broken.join('\n'))
  process.exit(1)
}

console.log(`No broken file links across ${files.length} HTML pages`)
