# CLAUDE.md

Guidance for working in `documentation/` — StruoDB's docs, kept separate
from the Gleam packages at the repo root (see the root `CLAUDE.md`).

## What this is

A [VitePress](https://vitepress.dev/) static site under `docs/`, built
and run with Bun. There's no server code, no frontend framework, nothing
beyond Markdown content and `docs/.vitepress/config.ts` — the generic
Bun runtime-API guidance (`Bun.serve`, `bun:sqlite`, HTML-import
frontends, etc.) doesn't apply here.

`plans/` (implementation-plan/codegen-plan docs, historical/working
notes rather than published reference) sits alongside `docs/` but is
deliberately excluded from the built site — `docs:build` only ever
builds the `docs/` directory.

## Commands

Run from this directory (`documentation/`):

```sh
bun install        # fetch deps (first run / after editing package.json)
bun run docs:dev      # local dev server with hot reload
bun run docs:build    # production build, output to docs/.vitepress/dist
bun run docs:preview  # serve the production build locally
```

## Structure

- `docs/specifications/struoql/` — the StruoQL language spec (lexical,
  DDL, DML) plus its design-decisions history.
- `docs/specifications/internals/` — specs for internal components
  (currently the hybrid logical clock) and external references.
- `docs/designs/` — design ideas / work in progress, less settled than
  `specifications/`.
- `docs/public/` — static assets served from the site root (favicon,
  grammar-railroad diagram, PDFs) — anything under here is fetched as-is,
  not processed as Markdown. The `x-specifications/`/`x-designs/`
  subfolders mirror `docs/specifications/`/`docs/designs/`'s own
  structure, holding each section's large non-Markdown assets (diagrams,
  PDFs) linked from its pages via plain `<a href="/x-.../...">` tags.
- `docs/.vitepress/config.ts` — nav, sidebar, and `<head>` (favicon
  links) configuration.
- `plans/` — see "What this is" above.

## Conventions

- Cross-references between pages use real Markdown links
  (`[text](/specifications/...)`, with `#anchor` fragments where needed)
  so `docs:build`'s dead-link check catches breakage — not bare
  backtick-quoted paths, which it can't verify.
- A page referencing a `plans/`-only file (not part of the built site)
  does so as plain repo-relative text, since there's no live page to
  link to.
