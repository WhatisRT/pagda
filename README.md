# Pagda, the package manager for Agda

Pagda is a package manager built on top of [agda.nix](https://github.com/input-output-hk/agda.nix). This means it inherits the nice features of nix, such as:
- Reproducable builds
- Caching
- Parallel builds
- etc.

Pagda is also completely compatible with the built-in package management functionality of Agda, so you can add it to existing code bases without breaking the workflow of users that don't use Pagda.

To see the list of supported commands, run `pagda help`.

## Installation

At the moment, the only supported installation method is via Nix. With flakes enabled you can run:

```
nix profile install github:WhatisRT/Pagda  # install pagda onto your PATH
```

This builds pagda from source on first use. A prebuilt binary cache may be added later.

To pull pagda into a flake / NixOS / home-manager configuration, add it as an input and use the overlay:

```nix
{
  inputs.pagda.url = "github:WhatisRT/Pagda";
  # in your nixpkgs config:
  #   overlays = [ pagda.overlays.default ];
  # then reference pkgs.pagda (e.g. in environment.systemPackages).
}
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
