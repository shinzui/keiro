---
type: Term
title: workspace manifest
description: "The authored `.keiro-workspace` file that declares one service split across several complete `.keiro` sources, with its stable service identity, runtime package, module, layout, and member specs."
generated:
  by: anthropic-claude-code/claude-opus-5
  at: "2026-09-19T03:09:21Z"
termId: TERM-27
status: current
scope: keiro-dsl
related:
  - TERM-26
anchors:
  - kind: module
    resource: Keiro.Dsl.Workspace
  - kind: doc
    resource: docs/user/typed-spec-toolchain.md
    note: The Service workspaces section.
---

# workspace manifest

The workspace manifest is input a person writes, not a [sidecar](sidecar.md). It is the only
keiro-dsl file that "manifest" names.
