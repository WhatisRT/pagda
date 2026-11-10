# Literate docs example

A minimal pagda project whose documentation is a **literate Markdown** Agda
module ([`Demo.lagda.md`](./Demo.lagda.md)) that embeds a diagram
(`architecture.svg`). The diagram is folded into the docs output via the
`docsAssets` field in [`pagda.nix`](./pagda.nix), and the module's prose +
`![](architecture.svg)` render to HTML — so the diagram is displayed in the docs.

## Build the docs

Run these commands from `examples/docs-assets`:

```
nix build .#docs
xdg-open result/Demo.html   # the literate page, with the diagram rendered
```

This pulls `pagda` from `github:WhatisRT/pagda`. To build against **this
checkout** (e.g. to test unreleased changes), starting at the repository root:

```
cd examples/docs-assets
nix build .#docs --override-input pagda ../..
```

## Other outputs

```
nix build .#default   # type-check the library
nix build .#agda      # an agda wrapped with this project's dependencies
nix develop           # the project's dev shell
```
