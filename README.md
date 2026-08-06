# Pagda, a package manager for Agda

Pagda is a package manager built on top of [agda.nix](https://github.com/input-output-hk/agda.nix). This means it inherits the nice features of nix, such as:
- Reproducable builds
- Caching
- Parallel builds
- etc.

Pagda is also completely compatible with the built-in package management functionality of Agda, so you can add it to existing code bases without breaking the workflow of users that don't use Pagda.

To see the list of supported commands, run `pagda --help`.

## Installation

At the moment, the only supported installation method is via Nix. With flakes enabled you can run:

```
nix profile add github:WhatisRT/pagda  # install pagda onto your PATH
```

This builds pagda from source on first use. A prebuilt binary cache may be added later.

If you already have installed pagda and want to update, run:

```
nix profile upgrade --refresh pagda
```

To pull pagda into a flake / NixOS / home-manager configuration, add it as an input and use the overlay:

```nix
{
  inputs.pagda.url = "github:WhatisRT/pagda";
  # in your nixpkgs config:
  #   overlays = [ pagda.overlays.default ];
  # then reference pkgs.pagda (e.g. in environment.systemPackages).
}
```

## Getting started

To scaffold a fresh project:

```
pagda init myproject         # in ./myproject
pagda init myproject --here  # in the current directory
```

This refuses to run if the target directory already contains a `flake.nix`,
a `.agda-lib`, or a `Test.agda`, so it never clobbers existing work.

To add pagda to an **existing** Agda project, run this in its directory:

```
pagda init --existing
```

This writes `flake.nix` and reuses the project's existing `.agda-lib`.
It never overwrites existing files, so it is safe to run in a populated
repository.

## Customizing the build via `pagda.nix`

The `.agda-lib` file governs the library name and its dependencies, and
those dependencies resolve by name against whatever `agdaPackages`
provides (pinned, along with the rest of nixpkgs and agda.nix, by your
`flake.lock`). For anything beyond that, add an optional `pagda.nix`
next to it. It is a function of `{ pkgs, pagda }` returning an attribute
set with these optional fields (`pagda` is pagda's per-system lib, also
carrying this project's `default` and `agda` packages):

- `overlay` — an overlay applied to `agdaPackages`, to **pin** a
  dependency to a particular version/source or to **add** one that
  `agdaPackages` does not provide.
- `overrideAttrs` — an
  [`overrideAttrs`](https://nixos.org/manual/nixpkgs/stable/#sec-pkg-overrideAttrs)
  function applied to the generated package (`gen` below) for build tweaks.
- `meta` — package [`meta`](https://nixos.org/manual/nixpkgs/stable/#chap-meta)
  attributes (description, license, homepage, …) merged into the library
  package.
- `nixpkgs` — `{ config, overlays }` for the nixpkgs import itself, to set
  options like `config.allowUnfree = true` or to pin/patch **non-Agda**
  tooling. These configure how `pkgs` is built, so they must not reference
  `pkgs` (the agda dependency overlay above belongs in `overlay`).
- `devShells` — an attribute set of dev shells, surfaced as the flake's
  `devShells` (so `nix develop` and `pagda shell [name]` pick them up). A
  `default` shell with agda and the project's dependencies is always
  provided.
- `docsAssets` — `{ "dest/in/output" = source; }` of extra static files to
  fold into the docs output (`pagda doc` / `.#docs`), e.g. a rendered
  diagram. `source` may be a path or a nix derivation.

```nix
# pagda.nix
{ pkgs, pagda }:
{
  # Pin standard-library to a tag; anything not mentioned keeps the
  # version agdaPackages provides.
  overlay = final: prev: {
    standard-library = prev.standard-library.overrideAttrs (_: {
      version = "2.3";
      src = pkgs.fetchFromGitHub {
        owner = "agda";
        repo = "agda-stdlib";
        rev = "v2.3";
        hash = "sha256-…";
      };
    });
  };

  # Library metadata.
  meta = {
    description = "My Agda library";
    homepage = "https://example.com/my-lib";
  };

  # Configure the nixpkgs import (must not reference pkgs).
  nixpkgs.config.allowUnfree = true;

  # Other build tweaks on the generated package.
  overrideAttrs = gen: {
    buildInputs = (gen.buildInputs or [ ]) ++ [ pkgs.cowsay ];
  };

  # Docs are offline by default; override e.g. to serve over HTTP with smaller footprint.
  docs = pagda.docBackends.enhancedHtml { offline = false; };

  # Fold extra static files into the docs output.
  docsAssets."diagram.svg" = ./diagram.svg;

  # Dev shells. `default` is used by `nix develop` / `pagda shell`.
  devShells.default = pkgs.mkShell {
    inputsFrom = [ pagda.default ];     # agda + the project's dependencies
    packages = [ pkgs.cabal-install ];  # plus extra tools
  };
}
```

## Editor integration

Pagda has a companion `agda-check` executable that can be used as the
`agda` program for editor integrations like Emacs `agda2-mode`:

```elisp
(setq agda2-program-name "agda-check")
```

## Documentation

`pagda doc` builds documentation for the project. It is exposed as the
`docs` flake package, so `nix build .#docs` works too.

By default it builds **enhanced** docs (via
[agda-web-docs-lib](https://github.com/will-break-it/agda-web-docs-lib)):
hyperlinked Agda HTML plus a sidebar, full-text search, dark/light theme and
hover type previews.

Both backends generate an `index.html` landing page. By default it lists the
module pages; pass `entryModule` to redirect it to a specific module instead
(its name as written in Agda, e.g. `Foo.Bar`).

The backend is pluggable via `pagda.nix`'s `docs` field:

```nix
docs = pagda.docBackends.enhancedHtml { entryModule = "Foo.Bar"; }; # land on a chosen module
docs = pagda.docBackends.enhancedHtml { offline = false; };         # optimized for serving over HTTP (e.g. CI)
docs = pagda.docBackends.html { };                                  # plain agda --html
```

## Continuous integration

`pagda gen-ci` writes a small `.github/workflows/ci.yml` that calls pagda's
[reusable workflow](.github/workflows/agda-ci.yml) to type-check the
library (`nix build .#default`) on every push and pull request.

Pass `--pages` to also build the docs and deploy them to GitHub Pages on the
default branch (set the repository's Pages source to "GitHub Actions").

Pass `--cache` to cache the Nix store via the GitHub Actions cache, so
reruns don't rebuild pagda/Agda from source.

### Reusable workflow inputs

The workflow supports a couple of options:

| Input | Default | Purpose |
|-------|---------|---------|
| `pages` | `false` | Build the docs. |
| `deploy` | `true` | Deploy docs to GitHub Pages. Set `false` to instead upload them as a plain `docs` artifact for your own workflow to compose into an existing site. |
| `docs-on-pr` | `true` | Also build (but not deploy) the docs on pull requests. Only applies when `pages` is set. |
| `cache` | `false` | Cache the Nix store via the GitHub Actions cache. |
| `working-directory` | `.` | Directory of the flake. |
| `gc-max-store-size` | `1G` | Trim the Nix store to this size before caching. |

To fold the docs into an **existing** Pages site instead of deploying them
standalone, use `deploy: false` and consume the `docs` artifact yourself:

```yaml
jobs:
  pagda:
    uses: WhatisRT/pagda/.github/workflows/agda-ci.yml@main
    with: { pages: true, deploy: false }
  publish:
    needs: pagda
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with: { name: docs, path: agda-docs }  # where the docs live in your site
      # ... build the rest of your site and deploy it ...
```

## Configuration options

There are three ways to set options for Pagda: a global configuration file, a configuration file local to the project and command line options. The syntax for command line options is `--<name> <value>` and the syntax for configuration files is `name=value;`, each on a separate line.

| Name             | Possible values  | Default | Description                                             |
|------------------|------------------|---------|---------------------------------------------------------|
| useUntracked     | true, false, ask | ask     | What to do with files that are untracked by git         |
| useWarnUntracked | true, false      | true    | Print a warning if certain files are not tracked by git |

## Development

Build pagda and run its test suites with nix:

```
nix build          # build the executable (no tests, matches the install)
nix flake check    # build and run the test suites
nix develop        # dev shell with ghc, cabal, git
```

### Testing

End-to-end tests live in `test/e2e`: each case starts from an initial file
tree, runs a `pagda` command in a sandbox, and compares the exit code,
output and resulting file tree against a golden manifest. Calls to `nix`
are intercepted by a stub that records the arguments, so the tests are
fast, reproducible and need no network. See
[test/e2e/README.md](test/e2e/README.md) for how to add cases and
regenerate goldens (`cabal test e2e --test-options=--accept`).
