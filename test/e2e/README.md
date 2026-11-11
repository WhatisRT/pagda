# End-to-end tests

Reproducible end-to-end tests for the `pagda` executable, built on
[tasty-golden](https://hackage.haskell.org/package/tasty-golden) and HUnit.
Each golden test case starts from an initial file tree, runs one `pagda` command in a fresh
sandbox (with an isolated `$HOME`), and compares the outcome — exit code,
stdout, stderr and the complete resulting file tree — against a golden
manifest.

`InitTests.hs` and `UpdateTests.hs` also exercise real Nix with local source
fixtures and a private writable store per test. They check persisted lockfile
contents without network access or access to the user's Nix store.

## Running

Via Nix (`nix build` builds the executable without running tests):

```
nix flake check
```

Locally, inside the dev shell (`nix develop`):

```
cabal test e2e
```

To see per-case output: `cabal test e2e --test-show-details=direct`.

## Anatomy of a test case

Each directory under `cases/` is one test case:

| Entry           | Meaning                                                                  |
|-----------------|--------------------------------------------------------------------------|
| `cmd`           | (required) arguments passed to `pagda`, whitespace-separated             |
| `initial/`      | file tree the work directory starts from                                 |
| `home/`         | file tree for the isolated `$HOME` (e.g. a global `pagda.conf`)          |
| `bin/`          | stub executables prepended to `$PATH` (e.g. a fake `nix`)                |
| `setup.sh`      | shell script run in the work directory before `pagda` (e.g. `git init`)  |
| `stdin`         | text piped to `pagda`'s stdin (for interactive prompts)                  |
| `output.golden` | golden manifest: exit code, stdout, stderr, and every file in the work directory with its contents |

Notes:

- Golden cases use `bin/nix` stubs to record command arguments or produce
  deterministic lockfile fixtures. The HUnit scenarios cover actual Nix
  lockfile creation, pin preservation, input resolution, and fork overrides.
- Occurrences of the sandbox work directory and home directory are replaced
  by `$TESTDIR` and `$TESTHOME`, so goldens are machine-independent.
- `.git` directories are excluded from the manifest.
- GHC `HasCallStack` backtraces are stripped from stderr, so goldens do
  not depend on the GHC version.

## Adding a case and updating goldens

Create a new directory under `cases/` with at least a `cmd` file, then run
the suite once: the golden manifest is created automatically. After an
intentional behaviour change, regenerate the goldens and review the diff:

```
cabal test e2e --test-options=--accept
git diff test/e2e/cases
```

Other useful options: `--test-options='-p init'` runs matching cases only,
`--test-options=-l` lists all cases.

Without cabal, the runner can be pointed at any pagda binary:

```
PAGDA_BIN=/path/to/pagda ./e2e [--accept] [-p PATTERN]
```

