import fs from 'node:fs/promises'
import path from 'node:path'
import matter from 'gray-matter'
import MarkdownIt from 'markdown-it'
import anchor from 'markdown-it-anchor'
import { createHighlighter } from 'shiki'
import { renderMermaidSVG } from 'beautiful-mermaid'

const root = process.cwd()
const plansDir = path.join(root, 'docs/plans')
const researchDir = path.join(root, 'docs/research')
const whyKeiroPath = path.join(root, 'docs/why-keiro.md')
const outDir = path.join(root, 'site-dist')
const assetsDir = path.join(root, 'site/assets')

const shikiTheme = 'github-light'
const highlighter = await createHighlighter({
  themes: [shikiTheme],
  langs: ['haskell', 'sql', 'bash', 'json', 'yaml', 'markdown', 'typescript', 'javascript', 'text'],
})

const loadedLangs = new Set(['haskell', 'sql', 'bash', 'json', 'yaml', 'markdown', 'typescript', 'javascript', 'text'])
const diagramTheme = {
  bg: '#fbfaf7',
  fg: '#202124',
  line: '#5b6472',
  accent: '#256f83',
  muted: '#777063',
  surface: '#f2efe7',
  border: '#c8c0b2',
  font: 'Inter',
  transparent: true,
  padding: 28,
  nodeSpacing: 28,
  layerSpacing: 46,
  thoroughness: 5,
}

const planDiagrams = {
  1: {
    title: 'Command Cycle Contract',
    mermaid: `flowchart LR
  A[Command] --> B[Hydrate stream]
  B --> C[Fold events through SymTransducer]
  C --> D[Decide]
  D --> E{Append succeeds?}
  E -->|yes| F[Return typed events]
  E -->|WrongExpectedVersion| B
  C --> G[RegFile + state preserved]`,
  },
  2: {
    title: 'Codec Boundary',
    mermaid: `flowchart LR
  A[Typed domain event] --> B[Codec encode]
  B --> C[Kiroku JSON payload]
  C --> D[Read RecordedEvent]
  D --> E{schemaVersion}
  E --> F[Upcaster chain]
  F --> G[Typed latest event]`,
  },
  3: {
    title: 'Read-Side Runtime',
    mermaid: `flowchart LR
  A[Kiroku global stream] --> B[Shibuya adapter]
  B --> C[Subscription handler]
  C --> D[Projection]
  C --> E[Process manager]
  E --> F[Command cycle]
  C --> G[Outbox / inbox]`,
  },
  4: {
    title: 'Snapshot Hydration',
    mermaid: `flowchart LR
  A[Command] --> B{Snapshot exists?}
  B -->|yes| C[Decode snapshot state + RegFile]
  B -->|no| D[Initial state]
  C --> E[Replay tail from streamVersion + 1]
  D --> F[Replay full stream]
  E --> G[Decide and append]
  F --> G`,
  },
  5: {
    title: 'Workflow Roadmap',
    mermaid: `flowchart TD
  A[v1 Event sourcing core] --> B[Process managers]
  A --> C[Durable timers]
  B --> D[Sagas via PMs]
  C --> D
  D --> E[v2 named-step durable execution]
  E --> F[Awakeables / child workflows / versioning]`,
  },
  6: {
    title: 'Upstream Sequencing',
    mermaid: `flowchart TD
  A[Blocking: kiroku runInTransaction] --> B[keiro v1 implementation can begin]
  B --> C[Wanted: transactional subscription handler]
  B --> D[Wanted: keiki RegFile helpers]
  B --> E[Optional: sharding, push, refinements]
  C --> F[exactly-once projection window]
  D --> G[snapshot + workflow ergonomics]`,
  },
  7: {
    title: 'Ergonomic Facade Hypothesis',
    mermaid: `flowchart LR
  A[Pure CQRS aggregate author] --> B[PureAggregate decide/evolve]
  B --> C[Internal facade]
  C --> D[EventStream phi rs s ci co]
  D --> E[runCommand]
  F[Workflow author] --> D`,
  },
}

const md = new MarkdownIt({
  html: false,
  linkify: true,
  typographer: true,
  highlight(code, lang) {
    const cleanLang = normalizeLang(lang)
    if (cleanLang === 'mermaid') {
      return `<figure class="diagram diagram-from-doc">${renderDiagram(code)}</figure>`
    }
    return highlightCode(code, cleanLang)
  },
}).use(anchor, {
  slugify,
  permalink: anchor.permalink.linkInsideHeader({
    symbol: '#',
    placement: 'after',
    class: 'anchor-link',
    ariaHidden: true,
  }),
})

md.renderer.rules.code_block = (tokens, idx) => highlightCode(tokens[idx].content, inferCodeLang(tokens[idx].content))

await fs.rm(outDir, { recursive: true, force: true })
await fs.mkdir(outDir, { recursive: true })
await fs.cp(assetsDir, path.join(outDir, 'assets'), { recursive: true })
await fs.cp(path.join(root, 'docs'), path.join(outDir, 'docs'), {
  recursive: true,
  filter: (source) => !source.endsWith('.DS_Store'),
})
await fs.copyFile(path.join(root, 'README.md'), path.join(outDir, 'README.md'))
await fs.cp(path.join(root, 'spikes'), path.join(outDir, 'spikes'), {
  recursive: true,
  filter: (source) => !source.endsWith('.DS_Store') && !source.includes(`${path.sep}dist-newstyle${path.sep}`),
})

const planFiles = (await fs.readdir(plansDir))
  .filter((file) => file.endsWith('.md'))
  .sort((a, b) => Number(a.split('-')[0]) - Number(b.split('-')[0]))

const researchFiles = (await fs.readdir(researchDir))
  .filter((file) => file.endsWith('.md'))
  .sort((a, b) => Number(a.split('-')[0]) - Number(b.split('-')[0]))

const plans = []
for (const file of planFiles) {
  const sourcePath = path.join(plansDir, file)
  const raw = await fs.readFile(sourcePath, 'utf8')
  const parsed = matter(raw)
  const id = Number(parsed.data.id ?? file.split('-')[0])
  const slug = parsed.data.slug ?? file.replace(/^\d+-/, '').replace(/\.md$/, '')
  const title = parsed.data.title ?? titleFromSlug(slug)
  const content = parsed.content
  const stats = planStats(content)
  const headings = extractHeadings(content)
  const summary = extractSectionLead(content, 'Purpose / Big Picture')
  const html = md.render(content)
  const diagram = planDiagrams[id]
  plans.push({
    id,
    slug,
    title,
    file,
    sourcePath: `docs/plans/${file}`,
    createdAt: parsed.data.created_at,
    summary,
    stats,
    headings,
    html,
    diagram,
  })
}

const researchDocs = []
for (const file of researchFiles) {
  const sourcePath = path.join(researchDir, file)
  const raw = await fs.readFile(sourcePath, 'utf8')
  const parsed = matter(raw)
  const id = Number(file.split('-')[0])
  const slug = file.replace(/\.md$/, '')
  const content = parsed.content
  const title = extractTitle(content) ?? titleFromSlug(slug.replace(/^\d+-/, ''))
  const headings = extractHeadings(content)
  const summary = extractFirstParagraph(content)
  researchDocs.push({
    id,
    slug,
    title,
    file,
    sourcePath: `docs/research/${file}`,
    summary,
    stats: planStats(content),
    headings,
    html: md.render(content).replaceAll('href="docs/', 'href="../docs/').replaceAll('href="spikes/', 'href="../spikes/'),
  })
}

const whyKeiro = await loadWhyKeiro()

for (const plan of plans) {
  await fs.writeFile(path.join(outDir, `${plan.slug}.html`), planPage(plan, plans), 'utf8')
}

await fs.mkdir(path.join(outDir, 'research'), { recursive: true })
for (const doc of researchDocs) {
  await fs.writeFile(path.join(outDir, 'research', `${doc.slug}.html`), researchPage(doc, researchDocs, plans), 'utf8')
}

await fs.writeFile(path.join(outDir, 'index.html'), indexPage(plans, researchDocs), 'utf8')
await fs.writeFile(path.join(outDir, 'why-keiro.html'), whyKeiroPage(whyKeiro, plans, researchDocs), 'utf8')
await fs.writeFile(path.join(outDir, 'research', 'index.html'), researchIndexPage(researchDocs, plans), 'utf8')
await fs.writeFile(path.join(outDir, 'docs/plans/index.html'), sourceIndex(plans), 'utf8')
await fs.writeFile(path.join(outDir, 'docs/research/index.html'), researchSourceIndex(researchDocs), 'utf8')
await fs.writeFile(path.join(outDir, 'styles.css'), stylesheet(), 'utf8')
await fs.writeFile(path.join(outDir, 'app.js'), clientScript(), 'utf8')

console.log(`Built ${plans.length + researchDocs.length + 3} site pages plus the source-doc index into site-dist/`)

function planStats(markdown) {
  const checked = count(markdown, /^\s*-\s+\[x\]/gim)
  const unchecked = count(markdown, /^\s*-\s+\[ \]/gim)
  return {
    checked,
    unchecked,
    decisions: count(markdown, /^-\s+Decision:/gim),
    discoveries: count(markdown, /^-\s+\d{4}-\d{2}-\d{2}:/gim),
    sections: count(markdown, /^##\s+/gim),
    words: markdown.split(/\s+/).filter(Boolean).length,
  }
}

function extractHeadings(markdown) {
  return markdown
    .split('\n')
    .map((line) => /^(#{2,3})\s+(.+)$/.exec(line))
    .filter(Boolean)
    .map((match) => ({
      level: match[1].length,
      text: stripMarkdown(match[2]),
      id: slugify(stripMarkdown(match[2])),
    }))
}

function extractSectionLead(markdown, heading) {
  const lines = markdown.split('\n')
  const start = lines.findIndex((line) => line.trim() === `## ${heading}`)
  if (start === -1) return ''
  const collected = []
  for (let i = start + 1; i < lines.length; i += 1) {
    const line = lines[i]
    if (/^#{1,6}\s+/.test(line)) break
    if (!line.trim()) {
      if (collected.length > 0) break
      continue
    }
    if (/^\d+\.\s|^-\s/.test(line.trim())) {
      if (collected.length > 0) break
      continue
    }
    collected.push(line.trim())
  }
  return stripMarkdown(collected.join(' ')).slice(0, 420)
}

function extractTitle(markdown) {
  const match = /^#\s+(.+)$/m.exec(markdown)
  return match ? stripMarkdown(match[1]) : null
}

function extractFirstParagraph(markdown) {
  const lines = markdown.split('\n')
  const collected = []
  for (const line of lines) {
    if (/^#{1,6}\s+/.test(line) || /^---\s*$/.test(line)) continue
    if (!line.trim()) {
      if (collected.length > 0) break
      continue
    }
    if (/^[-*]\s+|^\d+\.\s+/.test(line.trim())) {
      if (collected.length > 0) break
      continue
    }
    collected.push(line.trim())
  }
  return stripMarkdown(collected.join(' ')).slice(0, 420)
}

async function loadWhyKeiro() {
  const raw = await fs.readFile(whyKeiroPath, 'utf8')
  const parsed = matter(raw)
  const content = parsed.content
  return {
    id: 'why',
    slug: 'why-keiro',
    title: extractTitle(content) ?? 'Why keiro',
    file: 'why-keiro.md',
    sourcePath: 'docs/why-keiro.md',
    summary: extractFirstParagraph(content),
    stats: planStats(content),
    headings: extractHeadings(content),
    html: md.render(content)
      .replaceAll('href="../README.md"', 'href="README.md"')
      .replaceAll('href="masterplans/', 'href="docs/masterplans/')
      .replaceAll('href="plans/', 'href="docs/plans/')
      .replaceAll('href="research/', 'href="research/')
      .replaceAll('href="docs/', 'href="docs/'),
  }
}

function indexPage(plans, researchDocs) {
  const completed = plans.reduce((n, plan) => n + plan.stats.checked, 0)
  const open = plans.reduce((n, plan) => n + plan.stats.unchecked, 0)
  const decisions = plans.reduce((n, plan) => n + plan.stats.decisions, 0)
  const discoveries = plans.reduce((n, plan) => n + plan.stats.discoveries, 0)
  const architecture = renderDiagram(`flowchart LR
  A[keiki SymTransducer] --> B[keiro command cycle]
  C[kiroku event store] <--> B
  B --> D[typed events + codecs]
  C --> E[shibuya subscriptions]
  E --> F[projections]
  E --> G[process managers]
  G --> B
  B --> H[snapshots]
  G --> I[durable timers]
  I --> J[v2 workflows]`)
  const reading = renderDiagram(`flowchart TD
  A[1 Command cycle] --> B[2 Codec strategy]
  A --> C[3 Subscriptions + PMs]
  B --> C
  A --> D[4 Snapshots]
  B --> D
  C --> E[5 Workflow roadmap]
  D --> E
  A --> F[6 Upstream roadmap]
  B --> F
  C --> F
  D --> F
  E --> F
  F --> G[7 Ergonomic facade exploration]`)

  return shell({
    title: 'Keiro Technical Plans',
    active: 'overview',
    plans,
    researchDocs,
    body: `
      <section class="hero">
        <p class="eyebrow">経路 / keiro</p>
        <h1>Technical analysis site for the implementation team</h1>
        <p class="hero-copy">A navigable, deployable reading environment generated from <code>docs/plans</code> and <code>docs/research</code>. The source Markdown remains untouched; this site adds summaries, diagrams, status signals, and syntax-highlighted technical material for planning the keiro implementation.</p>
        <div class="hero-actions">
          <a class="button primary" href="#plans">Read the plans</a>
          <a class="button" href="why-keiro.html">Why keiro</a>
          <a class="button" href="research/">Browse research</a>
          <a class="button" href="docs/plans/">Source docs</a>
        </div>
      </section>

      <section class="metric-grid" aria-label="Plan metrics">
        ${metric('Plan documents', plans.length)}
        ${metric('Research docs', researchDocs.length)}
        ${metric('Completed checklist items', completed)}
        ${metric('Open checklist items', open)}
        ${metric('Logged decisions', decisions)}
      </section>

      <section class="split">
        <article>
          <p class="eyebrow">System shape</p>
          <h2>How the pieces fit</h2>
          <p>keiro is being designed as a library-shaped runtime over kiroku, keiki, shibuya, effectful, hasql, Streamly, and Postgres. The plans converge on one core path: hydrate from the event store, fold typed events through keiki's transducer, decide, append with optimistic concurrency, then feed read-side and workflow machinery from the same substrate.</p>
        </article>
        <figure class="diagram">${architecture}</figure>
      </section>

      <section class="split reverse">
        <article>
          <p class="eyebrow">Reading order</p>
          <h2>Discussion path</h2>
          <p>The first four plans establish the v1 substrate. The workflow roadmap explains the v1/v2 boundary. The upstream roadmap consolidates what must land in sibling projects. The seventh plan is exploratory and should be discussed after the core contract is understood.</p>
        </article>
        <figure class="diagram">${reading}</figure>
      </section>

      <section id="plans" class="plans-section">
        <div class="section-heading">
          <p class="eyebrow">Source material</p>
          <h2>Plans</h2>
        </div>
        <div class="toolbar">
          <label class="search-label" for="plan-search">Filter</label>
          <input id="plan-search" type="search" placeholder="Search titles, summaries, paths..." autocomplete="off">
        </div>
        <div class="plan-grid" data-plan-list>
          ${plans.map(planCard).join('')}
        </div>
      </section>

      <section id="research" class="plans-section related-section">
        <div class="section-heading">
          <p class="eyebrow">Analysis library</p>
          <h2>Research docs</h2>
          <p class="section-copy">The research collection contains the current-state surveys, prior-art survey, and finalized design documents that the ExecPlans produced.</p>
        </div>
        <div class="plan-grid">
          ${researchDocs.slice(0, 6).map((doc) => researchCard(doc)).join('')}
        </div>
        <div class="section-actions">
          <a class="button primary" href="research/">Open all research docs</a>
          <a class="button" href="docs/research/">Original research Markdown</a>
        </div>
      </section>

      <section class="split related-section">
        <article>
          <p class="eyebrow">Motivation</p>
          <h2>Why keiro exists</h2>
          <p>The motivation document explains why keiro chooses a single transducer formalism and one Postgres-backed substrate instead of stitching together an event-sourcing framework, workflow engine, and durable-execution runtime.</p>
          <div class="section-actions">
            <a class="button primary" href="why-keiro.html">Read Why keiro</a>
            <a class="button" href="docs/why-keiro.md">Original Markdown</a>
          </div>
        </article>
        <figure class="diagram">${renderDiagram(`flowchart LR
  A[Event sourcing] --> D[keiro]
  B[Process managers] --> D
  C[Durable execution] --> D
  D --> E[One SymTransducer contract]
  D --> F[One Postgres substrate]
  D --> G[One operational story]`)}</figure>
      </section>
    `,
  })
}

function sourceIndex(plans) {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Plan Source Markdown</title>
    <link rel="stylesheet" href="../../styles.css">
  </head>
  <body>
    <main class="hero">
      <p class="eyebrow">Original Markdown</p>
      <h1>Plan sources</h1>
      <p class="hero-copy">These are copied into the build output for deployment convenience. The canonical editable files remain in <code>docs/plans</code>.</p>
      <div class="plan-grid" style="margin-top:32px">
        ${plans.map((plan) => `<article class="plan-card"><div class="card-kicker">Plan ${plan.id}</div><h3><a href="${plan.file}">${escapeHtml(plan.title)}</a></h3><p>${escapeHtml(plan.sourcePath)}</p></article>`).join('')}
      </div>
    </main>
  </body>
</html>`
}

function researchSourceIndex(researchDocs) {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Research Source Markdown</title>
    <link rel="stylesheet" href="../../styles.css">
  </head>
  <body>
    <main class="hero">
      <p class="eyebrow">Original Markdown</p>
      <h1>Research sources</h1>
      <p class="hero-copy">These are copied into the build output for deployment convenience. The canonical editable files remain in <code>docs/research</code>.</p>
      <div class="plan-grid" style="margin-top:32px">
        ${researchDocs.map((doc) => `<article class="plan-card"><div class="card-kicker">Research ${String(doc.id).padStart(2, '0')}</div><h3><a href="${doc.file}">${escapeHtml(doc.title)}</a></h3><p>${escapeHtml(doc.sourcePath)}</p></article>`).join('')}
      </div>
    </main>
  </body>
</html>`
}

function researchIndexPage(researchDocs, plans) {
  const surveyCount = researchDocs.filter((doc) => doc.id <= 5).length
  const designCount = researchDocs.filter((doc) => doc.id >= 6).length
  const words = researchDocs.reduce((n, doc) => n + doc.stats.words, 0)
  const map = renderDiagram(`flowchart TD
  A[00 Overview] --> B[01 Kiroku survey]
  A --> C[02 Keiki survey]
  A --> D[03 Shibuya survey]
  B --> E[04 Command-cycle integration]
  C --> E
  E --> F[06 Command-cycle design]
  F --> G[07 Codec strategy]
  F --> H[08 Subscriptions + PMs]
  G --> I[09 Snapshots]
  H --> J[10 Workflow roadmap]
  I --> J
  J --> K[11 Upstream roadmap]`)

  return shell({
    title: 'Research Docs / Keiro',
    active: 'research',
    plans,
    researchDocs,
    basePath: '../',
    body: `
      <section class="hero">
        <p class="eyebrow">Research library</p>
        <h1>Current-state surveys and design notes</h1>
        <p class="hero-copy">Generated from <code>docs/research</code>. These pages preserve the source document structure while adding table-of-contents navigation, code highlighting, and a reading map for team review.</p>
        <div class="hero-actions">
          <a class="button primary" href="#research-docs">Read research</a>
          <a class="button" href="../docs/research/">Original Markdown</a>
        </div>
      </section>

      <section class="metric-grid" aria-label="Research metrics">
        ${metric('Research documents', researchDocs.length)}
        ${metric('Current-state surveys', surveyCount)}
        ${metric('Design notes', designCount)}
        ${metric('Sections', researchDocs.reduce((n, doc) => n + doc.stats.sections, 0))}
        ${metric('Words', words.toLocaleString())}
      </section>

      <section class="split">
        <article>
          <p class="eyebrow">Reading map</p>
          <h2>From surveys to implementation constraints</h2>
          <p>The early documents survey the dependency stack and prior art. The later documents convert those findings into keiro-specific design contracts, then consolidate upstream work for kiroku, keiki, and shibuya.</p>
        </article>
        <figure class="diagram">${map}</figure>
      </section>

      <section id="research-docs" class="plans-section">
        <div class="section-heading">
          <p class="eyebrow">Documents</p>
          <h2>Research</h2>
        </div>
        <div class="toolbar">
          <label class="search-label" for="plan-search">Filter</label>
          <input id="plan-search" type="search" placeholder="Search titles, summaries, paths..." autocomplete="off">
        </div>
        <div class="plan-grid" data-plan-list>
          ${researchDocs.map((doc) => researchCard(doc, '')).join('')}
        </div>
      </section>
    `,
  })
}

function planPage(plan, plans) {
  const diagram = plan.diagram ? renderDiagram(plan.diagram.mermaid) : ''
  const next = plans.find((candidate) => candidate.id === plan.id + 1)
  const previous = plans.find((candidate) => candidate.id === plan.id - 1)
  return shell({
    title: `${plan.title} / Keiro`,
    active: plan.slug,
    plans,
    body: `
      <article class="doc-shell">
        <header class="doc-header">
          <p class="eyebrow">Plan ${plan.id}</p>
          <h1>${escapeHtml(plan.title)}</h1>
          <p>${escapeHtml(plan.summary)}</p>
          <div class="doc-actions">
            <a class="button primary" href="#source">Read enhanced doc</a>
            <a class="button" href="${escapeHtml(plan.sourcePath)}">Original Markdown</a>
          </div>
        </header>

        <section class="metric-grid compact">
          ${metric('Done', plan.stats.checked)}
          ${metric('Open', plan.stats.unchecked)}
          ${metric('Decisions', plan.stats.decisions)}
          ${metric('Discoveries', plan.stats.discoveries)}
          ${metric('Words', plan.stats.words.toLocaleString())}
        </section>

        <section class="split">
          <article>
            <p class="eyebrow">Reading aid</p>
            <h2>${escapeHtml(plan.diagram?.title ?? 'Plan map')}</h2>
            <p>This diagram is generated from the plan's implementation pressure, not copied from the Markdown. Use it as an orientation layer before reviewing the source-derived document below.</p>
          </article>
          <figure class="diagram">${diagram}</figure>
        </section>

        <div class="doc-layout">
          <aside class="toc">
            <p class="toc-title">On this page</p>
            <nav>${toc(plan.headings)}</nav>
          </aside>
          <main id="source" class="markdown-body">
            ${plan.html}
          </main>
        </div>

        <footer class="pager">
          ${previous ? `<a class="button" href="${previous.slug}.html">Previous: ${escapeHtml(previous.title)}</a>` : '<span></span>'}
          ${next ? `<a class="button primary" href="${next.slug}.html">Next: ${escapeHtml(next.title)}</a>` : '<a class="button primary" href="index.html">Back to overview</a>'}
        </footer>
      </article>
    `,
  })
}

function researchPage(doc, researchDocs, plans) {
  const next = researchDocs.find((candidate) => candidate.id === doc.id + 1)
  const previous = researchDocs.find((candidate) => candidate.id === doc.id - 1)
  return shell({
    title: `${doc.title} / Keiro Research`,
    active: 'research',
    plans,
    researchDocs,
    basePath: '../',
    body: `
      <article class="doc-shell">
        <header class="doc-header">
          <p class="eyebrow">Research ${String(doc.id).padStart(2, '0')}</p>
          <h1>${escapeHtml(doc.title)}</h1>
          <p>${escapeHtml(doc.summary)}</p>
          <div class="doc-actions">
            <a class="button primary" href="#source">Read enhanced doc</a>
            <a class="button" href="../${escapeHtml(doc.sourcePath)}">Original Markdown</a>
            <a class="button" href="index.html">Research index</a>
          </div>
        </header>

        <section class="metric-grid compact">
          ${metric('Sections', doc.stats.sections)}
          ${metric('Words', doc.stats.words.toLocaleString())}
          ${metric('Decisions', doc.stats.decisions)}
          ${metric('Discoveries', doc.stats.discoveries)}
          ${metric('Checklist items', doc.stats.checked + doc.stats.unchecked)}
        </section>

        <div class="doc-layout">
          <aside class="toc">
            <p class="toc-title">On this page</p>
            <nav>${toc(doc.headings)}</nav>
          </aside>
          <main id="source" class="markdown-body">
            ${doc.html}
          </main>
        </div>

        <footer class="pager">
          ${previous ? `<a class="button" href="${previous.slug}.html">Previous: ${escapeHtml(previous.title)}</a>` : '<span></span>'}
          ${next ? `<a class="button primary" href="${next.slug}.html">Next: ${escapeHtml(next.title)}</a>` : '<a class="button primary" href="index.html">Back to research</a>'}
        </footer>
      </article>
    `,
  })
}

function whyKeiroPage(doc, plans, researchDocs) {
  return shell({
    title: `${doc.title} / Keiro`,
    active: 'why',
    plans,
    researchDocs,
    body: `
      <article class="doc-shell">
        <header class="doc-header">
          <p class="eyebrow">Motivation</p>
          <h1>${escapeHtml(doc.title)}</h1>
          <p>${escapeHtml(doc.summary)}</p>
          <div class="doc-actions">
            <a class="button primary" href="#source">Read enhanced doc</a>
            <a class="button" href="${escapeHtml(doc.sourcePath)}">Original Markdown</a>
            <a class="button" href="research/">Research index</a>
          </div>
        </header>

        <section class="metric-grid compact">
          ${metric('Sections', doc.stats.sections)}
          ${metric('Words', doc.stats.words.toLocaleString())}
          ${metric('Decisions', doc.stats.decisions)}
          ${metric('Discoveries', doc.stats.discoveries)}
          ${metric('Research docs', researchDocs.length)}
        </section>

        <section class="split">
          <article>
            <p class="eyebrow">Positioning</p>
            <h2>Three categories, one contract</h2>
            <p>This document is the team-facing argument for why keiro should exist beside traditional event-sourcing frameworks, generic workflow engines, and durable-execution engines.</p>
          </article>
          <figure class="diagram">${renderDiagram(`flowchart TD
  A[Traditional event sourcing] --> D[keiro]
  B[Generic workflow engines] --> D
  C[Durable execution engines] --> D
  D --> E[SymTransducer phi rs s ci co]
  E --> F[Aggregates]
  E --> G[Process managers]
  E --> H[v2 durable workflows]`)}</figure>
        </section>

        <div class="doc-layout">
          <aside class="toc">
            <p class="toc-title">On this page</p>
            <nav>${toc(doc.headings)}</nav>
          </aside>
          <main id="source" class="markdown-body">
            ${doc.html}
          </main>
        </div>
      </article>
    `,
  })
}

function shell({ title, body, plans, active, basePath = '' }) {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>${escapeHtml(title)}</title>
    <link rel="stylesheet" href="${basePath}styles.css">
  </head>
  <body>
    <a class="skip-link" href="#content">Skip to content</a>
    <header class="topbar">
      <a class="brand" href="${basePath}index.html" aria-label="Keiro overview">
        <span class="brand-mark">経路</span>
        <span>keiro docs</span>
      </a>
      <nav class="topnav" aria-label="Primary">
        <a class="${active === 'overview' ? 'active' : ''}" href="${basePath}index.html">Overview</a>
        <a class="${active === 'why' ? 'active' : ''}" href="${basePath}why-keiro.html">Why</a>
        <a class="${active === 'research' ? 'active' : ''}" href="${basePath}research/">Research</a>
        ${plans.map((plan) => `<a class="${active === plan.slug ? 'active' : ''}" href="${basePath}${plan.slug}.html">${plan.id}</a>`).join('')}
      </nav>
    </header>
    <main id="content">
      ${body}
    </main>
    <script type="module" src="${basePath}app.js"></script>
  </body>
</html>`
}

function planCard(plan) {
  const percent = plan.stats.checked + plan.stats.unchecked === 0
    ? 0
    : Math.round((plan.stats.checked / (plan.stats.checked + plan.stats.unchecked)) * 100)
  return `<article class="plan-card" data-plan-card data-search="${escapeHtml(`${plan.title} ${plan.summary} ${plan.sourcePath}`.toLowerCase())}">
    <div class="card-kicker">Plan ${plan.id}</div>
    <h3><a href="${plan.slug}.html">${escapeHtml(plan.title)}</a></h3>
    <p>${escapeHtml(plan.summary)}</p>
    <div class="progress-line" aria-label="${percent}% complete"><span style="width:${percent}%"></span></div>
    <dl class="card-stats">
      <div><dt>done</dt><dd>${plan.stats.checked}</dd></div>
      <div><dt>open</dt><dd>${plan.stats.unchecked}</dd></div>
      <div><dt>decisions</dt><dd>${plan.stats.decisions}</dd></div>
    </dl>
  </article>`
}

function researchCard(doc, prefix = 'research/') {
  const kind = doc.id <= 5 ? 'Survey' : doc.id === 0 ? 'Overview' : 'Design'
  return `<article class="plan-card" data-plan-card data-search="${escapeHtml(`${doc.title} ${doc.summary} ${doc.sourcePath}`.toLowerCase())}">
    <div class="card-kicker">${kind} ${String(doc.id).padStart(2, '0')}</div>
    <h3><a href="${prefix}${doc.slug}.html">${escapeHtml(doc.title)}</a></h3>
    <p>${escapeHtml(doc.summary)}</p>
    <dl class="card-stats">
      <div><dt>sections</dt><dd>${doc.stats.sections}</dd></div>
      <div><dt>words</dt><dd>${doc.stats.words.toLocaleString()}</dd></div>
      <div><dt>source</dt><dd>MD</dd></div>
    </dl>
  </article>`
}

function metric(label, value) {
  return `<div class="metric"><span>${escapeHtml(String(value))}</span><p>${escapeHtml(label)}</p></div>`
}

function toc(headings) {
  return headings
    .filter((heading) => heading.level <= 3)
    .map((heading) => `<a class="toc-level-${heading.level}" href="#${heading.id}">${escapeHtml(heading.text)}</a>`)
    .join('')
}

function renderDiagram(source) {
  return renderMermaidSVG(source, diagramTheme)
    .replace(/\s*@import url\('https:\/\/fonts\.googleapis\.com\/css2\?family=Inter:[^']+'\);\n?/g, '')
}

function highlightCode(code, lang) {
  const language = loadedLangs.has(lang) ? lang : 'text'
  return highlighter.codeToHtml(code, { lang: language, theme: shikiTheme })
}

function inferCodeLang(code) {
  const trimmed = code.trim()
  if (/^(data|newtype|type|run[A-Z]|appendToStream|[a-zA-Z0-9_']+\s*::|\{-#|module\s)/m.test(trimmed)) return 'haskell'
  if (/^(mkdir|cd|cabal|nix|npm|#\s)/m.test(trimmed)) return 'bash'
  if (/^(SELECT|CREATE|ALTER|INSERT|UPDATE|DELETE)\b/im.test(trimmed)) return 'sql'
  if (/^[\[{]/.test(trimmed)) return 'json'
  return 'text'
}

function normalizeLang(lang = '') {
  const clean = String(lang).trim().split(/\s+/)[0].toLowerCase()
  if (clean === 'hs') return 'haskell'
  if (clean === 'yml') return 'yaml'
  if (clean === 'sh' || clean === 'shell') return 'bash'
  if (!clean) return 'text'
  return clean
}

function titleFromSlug(slug) {
  return slug.split('-').map((word) => word[0].toUpperCase() + word.slice(1)).join(' ')
}

function slugify(value) {
  return String(value)
    .toLowerCase()
    .replace(/`([^`]+)`/g, '$1')
    .replace(/[^\p{Letter}\p{Number}\s-]/gu, '')
    .trim()
    .replace(/\s+/g, '-')
}

function stripMarkdown(value) {
  return String(value)
    .replace(/`([^`]+)`/g, '$1')
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/\*([^*]+)\*/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/#+\s*/g, '')
    .trim()
}

function count(value, regex) {
  return [...value.matchAll(regex)].length
}

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}

function stylesheet() {
  return `@font-face {
  font-family: "Inter";
  src: url("assets/fonts/Inter-Regular.woff2") format("woff2");
  font-weight: 400;
  font-style: normal;
  font-display: swap;
}
@font-face {
  font-family: "Inter";
  src: url("assets/fonts/Inter-Medium.woff2") format("woff2");
  font-weight: 500;
  font-style: normal;
  font-display: swap;
}
@font-face {
  font-family: "Inter";
  src: url("assets/fonts/Inter-SemiBold.woff2") format("woff2");
  font-weight: 600;
  font-style: normal;
  font-display: swap;
}
@font-face {
  font-family: "Inter";
  src: url("assets/fonts/Inter-Bold.woff2") format("woff2");
  font-weight: 700;
  font-style: normal;
  font-display: swap;
}
@font-face {
  font-family: "Pragmata Pro";
  src: url("assets/pragmata/PragmataPro-Mono-Regular-Liga.ttf") format("truetype");
  font-weight: 400;
  font-style: normal;
  font-display: swap;
}
@font-face {
  font-family: "Pragmata Pro";
  src: url("assets/pragmata/PragmataPro-Mono-Bold-Liga.ttf") format("truetype");
  font-weight: 700;
  font-style: normal;
  font-display: swap;
}
:root {
  color-scheme: light;
  --bg: #fbfaf7;
  --paper: #ffffff;
  --ink: #202124;
  --muted: #68645f;
  --line: #ded7ca;
  --soft: #f2efe7;
  --soft-2: #ece7dc;
  --accent: #256f83;
  --accent-2: #8a4b2f;
  --ok: #2d6a4f;
  --warn: #936f23;
  --shadow: 0 14px 40px rgba(43, 37, 28, 0.08);
  font-family: Inter, system-ui, sans-serif;
}
* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--ink);
  font-size: 16px;
  line-height: 1.6;
}
a { color: var(--accent); text-decoration-thickness: 0.08em; text-underline-offset: 0.18em; }
code, pre, kbd, samp {
  font-family: "Pragmata Pro", ui-monospace, SFMono-Regular, Menlo, monospace;
  font-feature-settings: "liga" 1, "calt" 1;
}
.skip-link {
  position: absolute;
  left: 16px;
  top: -40px;
  background: var(--ink);
  color: white;
  padding: 8px 12px;
  z-index: 10;
}
.skip-link:focus { top: 12px; }
.topbar {
  position: sticky;
  top: 0;
  z-index: 5;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 24px;
  padding: 12px clamp(18px, 4vw, 56px);
  border-bottom: 1px solid rgba(222, 215, 202, 0.9);
  background: rgba(251, 250, 247, 0.92);
  backdrop-filter: blur(14px);
}
.brand {
  display: inline-flex;
  align-items: center;
  gap: 10px;
  color: var(--ink);
  font-weight: 700;
  text-decoration: none;
}
.brand-mark {
  display: inline-grid;
  place-items: center;
  width: 34px;
  height: 34px;
  border-radius: 7px;
  background: var(--ink);
  color: var(--bg);
  font-weight: 600;
}
.topnav { display: flex; align-items: center; gap: 4px; overflow-x: auto; }
.topnav a {
  min-width: 34px;
  padding: 7px 10px;
  border-radius: 7px;
  color: var(--muted);
  text-align: center;
  text-decoration: none;
  font-weight: 600;
}
.topnav a.active, .topnav a:hover { background: var(--soft-2); color: var(--ink); }
main { padding-bottom: 72px; }
.hero, .doc-header {
  max-width: 1040px;
  margin: 0 auto;
  padding: clamp(54px, 9vw, 98px) clamp(20px, 4vw, 56px) 42px;
}
.eyebrow, .card-kicker {
  margin: 0 0 12px;
  color: var(--accent-2);
  font-size: 0.76rem;
  font-weight: 700;
  letter-spacing: 0;
  text-transform: uppercase;
}
h1, h2, h3 { margin: 0; line-height: 1.12; letter-spacing: 0; }
h1 { max-width: 900px; font-size: clamp(2.4rem, 6vw, 5.6rem); }
h2 { font-size: clamp(1.7rem, 3vw, 2.6rem); }
h3 { font-size: 1.12rem; }
.hero-copy, .doc-header p {
  max-width: 780px;
  margin: 22px 0 0;
  color: var(--muted);
  font-size: clamp(1rem, 2vw, 1.22rem);
}
.hero-actions, .doc-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  margin-top: 28px;
}
.button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-height: 40px;
  padding: 8px 14px;
  border: 1px solid var(--line);
  border-radius: 7px;
  background: var(--paper);
  color: var(--ink);
  text-decoration: none;
  font-weight: 700;
  box-shadow: 0 1px 0 rgba(0, 0, 0, 0.03);
}
.button.primary { background: var(--ink); border-color: var(--ink); color: var(--bg); }
.metric-grid {
  display: grid;
  grid-template-columns: repeat(5, minmax(0, 1fr));
  gap: 1px;
  max-width: 1180px;
  margin: 0 auto;
  padding: 0 clamp(20px, 4vw, 56px) 56px;
}
.metric {
  min-height: 108px;
  padding: 20px;
  background: var(--paper);
  border: 1px solid var(--line);
}
.metric:first-child { border-radius: 8px 0 0 8px; }
.metric:last-child { border-radius: 0 8px 8px 0; }
.metric span { display: block; font-size: 2rem; line-height: 1; font-weight: 700; }
.metric p { margin: 10px 0 0; color: var(--muted); font-size: 0.9rem; }
.metric-grid.compact { padding-bottom: 42px; }
.split {
  display: grid;
  grid-template-columns: minmax(0, 0.78fr) minmax(0, 1.22fr);
  gap: 34px;
  align-items: center;
  max-width: 1180px;
  margin: 0 auto 64px;
  padding: 0 clamp(20px, 4vw, 56px);
}
.split.reverse { grid-template-columns: minmax(0, 0.92fr) minmax(0, 1.08fr); }
.split article p:not(.eyebrow) { color: var(--muted); }
.diagram {
  margin: 0;
  overflow: auto;
  padding: 16px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: rgba(255, 255, 255, 0.66);
  box-shadow: var(--shadow);
}
.diagram svg { width: 100%; height: auto; display: block; min-width: 520px; }
.plans-section {
  max-width: 1180px;
  margin: 0 auto;
  padding: 0 clamp(20px, 4vw, 56px);
}
.related-section { margin-top: 72px; }
.section-heading { margin-bottom: 18px; }
.section-copy {
  max-width: 720px;
  margin: 10px 0 0;
  color: var(--muted);
}
.section-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
  margin-top: 20px;
}
.toolbar {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 16px;
}
.search-label { color: var(--muted); font-weight: 700; }
input[type="search"] {
  width: min(520px, 100%);
  min-height: 42px;
  padding: 8px 12px;
  border: 1px solid var(--line);
  border-radius: 7px;
  background: var(--paper);
  color: var(--ink);
  font: inherit;
}
.plan-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 14px;
}
.plan-card {
  display: flex;
  flex-direction: column;
  min-height: 292px;
  padding: 22px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--paper);
}
.plan-card h3 a { color: var(--ink); text-decoration: none; }
.plan-card h3 a:hover { color: var(--accent); }
.plan-card p { color: var(--muted); margin: 12px 0 auto; }
.progress-line {
  height: 8px;
  margin: 20px 0 14px;
  overflow: hidden;
  border-radius: 999px;
  background: var(--soft);
}
.progress-line span { display: block; height: 100%; background: var(--ok); }
.card-stats {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 8px;
  margin: 0;
}
.card-stats div {
  padding: 10px;
  border-radius: 7px;
  background: var(--soft);
}
.card-stats dt { color: var(--muted); font-size: 0.72rem; font-weight: 700; text-transform: uppercase; }
.card-stats dd { margin: 2px 0 0; font-weight: 700; }
.doc-shell { max-width: none; }
.doc-layout {
  display: grid;
  grid-template-columns: 250px minmax(0, 820px);
  gap: 44px;
  justify-content: center;
  align-items: start;
  padding: 0 clamp(20px, 4vw, 56px);
}
.toc {
  position: sticky;
  top: 76px;
  max-height: calc(100vh - 100px);
  overflow: auto;
  padding: 18px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: rgba(255, 255, 255, 0.72);
}
.toc-title { margin: 0 0 10px; color: var(--muted); font-size: 0.78rem; font-weight: 700; text-transform: uppercase; }
.toc nav { display: grid; gap: 7px; }
.toc a { color: var(--muted); text-decoration: none; font-size: 0.88rem; line-height: 1.3; }
.toc a:hover { color: var(--ink); }
.toc-level-3 { padding-left: 13px; }
.markdown-body {
  min-width: 0;
  padding: 36px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--paper);
  box-shadow: var(--shadow);
}
.markdown-body h1 { font-size: clamp(2rem, 4vw, 3.6rem); }
.markdown-body h2 {
  margin-top: 2.2em;
  padding-top: 0.7em;
  border-top: 1px solid var(--line);
  font-size: 1.8rem;
}
.markdown-body h3 { margin-top: 1.8em; font-size: 1.25rem; }
.markdown-body p, .markdown-body li { color: #36332f; }
.markdown-body blockquote {
  margin: 24px 0;
  padding: 12px 18px;
  border-left: 4px solid var(--accent);
  background: var(--soft);
}
.markdown-body table {
  width: 100%;
  border-collapse: collapse;
  margin: 24px 0;
  font-size: 0.95rem;
}
.markdown-body th, .markdown-body td {
  padding: 10px 12px;
  border: 1px solid var(--line);
  text-align: left;
  vertical-align: top;
}
.markdown-body th { background: var(--soft); }
.markdown-body code:not(pre code) {
  padding: 0.08em 0.28em;
  border-radius: 5px;
  background: var(--soft);
  font-size: 0.9em;
}
.markdown-body pre {
  overflow: auto;
  margin: 24px 0;
  border: 1px solid var(--line);
  border-radius: 8px;
}
.markdown-body .shiki {
  padding: 18px;
  background: #f7f5ef !important;
}
.markdown-body .anchor-link {
  margin-left: 8px;
  color: var(--line);
  text-decoration: none;
  opacity: 0;
}
.markdown-body h1:hover .anchor-link,
.markdown-body h2:hover .anchor-link,
.markdown-body h3:hover .anchor-link { opacity: 1; }
.pager {
  display: flex;
  justify-content: space-between;
  gap: 16px;
  max-width: 1180px;
  margin: 34px auto 0;
  padding: 0 clamp(20px, 4vw, 56px);
}
@media (max-width: 900px) {
  .topbar { align-items: flex-start; flex-direction: column; gap: 10px; }
  .metric-grid, .plan-grid, .split, .split.reverse, .doc-layout {
    grid-template-columns: 1fr;
  }
  .metric:first-child, .metric:last-child, .metric { border-radius: 8px; }
  .toc { position: static; max-height: none; }
  .diagram svg { min-width: 430px; }
  .markdown-body { padding: 24px; }
}
@media (max-width: 560px) {
  h1 { font-size: 2.35rem; }
  .hero, .doc-header { padding-top: 40px; }
  .metric-grid { gap: 10px; }
  .doc-actions, .hero-actions, .pager { flex-direction: column; align-items: stretch; }
  .markdown-body { padding: 18px; }
}`
}

function clientScript() {
  return `const input = document.querySelector('#plan-search')
const cards = [...document.querySelectorAll('[data-plan-card]')]
if (input) {
  input.addEventListener('input', () => {
    const query = input.value.trim().toLowerCase()
    for (const card of cards) {
      card.hidden = query && !card.dataset.search.includes(query)
    }
  })
}`
}
