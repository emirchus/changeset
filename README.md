# changeset

A tool to manage changesets in **Dart** and **Flutter** projects. It lets you record changes (major, minor, patch), group them by scope, and generate releases by updating `pubspec.yaml`, `CHANGELOG.md`, and archiving used changesets.

Works with plain Dart packages (version `X.Y.Z`) and Flutter projects (version `X.Y.Z+build`). The version format is detected from your `pubspec.yaml` and preserved on release.

## Features

- **Add changesets:** Record a change with type (major, minor, patch), summary, and optionally a scope.
- **Release:** Reads all changesets, decides the bump from the highest type present, updates the version in `pubspec.yaml` (keeps Dart `X.Y.Z` or Flutter `X.Y.Z+build` format), writes the entry to `CHANGELOG.md`, and archives changesets under `.changesets/archived/<version>`.
- **Dry-run:** The `release --dry-run` command shows the release plan without modifying any files.
- **Config:** Optional `changeset.yaml` or `changeset:` key in root `pubspec.yaml` to set paths and workspace packages.
- **Monorepo / workspace:** Use `-W <package>` (or `--workspace`) on `add` and `release` to manage changesets per package: one `.changesets/` and one `CHANGELOG.md` at the repo root, while version bumps apply to the chosen package’s `pubspec.yaml`.

## Requirements

- Dart SDK ^3.9.2
- A project with `pubspec.yaml` and a `version:` field:
  - **Dart:** `X.Y.Z` (e.g. `1.0.0`)
  - **Flutter:** `X.Y.Z+<build>` (e.g. `1.0.0+1`)

## Installation

Add `changeset` as a dev dependency in your `pubspec.yaml`:
```yaml
dev_dependencies:
  changeset: ^1.0.0
```

Or install it globally:
```bash
dart pub global activate changeset
```

## Configuration

When you run changeset, it looks for config in this order:

1. **`changeset.yaml`** — From the current directory upward (until the repo root). If found, that directory is the **root** and the file content is the config.
2. **Root `pubspec.yaml`** — If no `changeset.yaml` exists, the first parent directory that has a `pubspec.yaml` with a `workspace:` (Dart) or `melos:` (Melos) section is treated as the root. If that pubspec has a **`changeset:`** key (map), it is used as config.
3. **No config** — Root is the current directory; behavior is the same as before (single package, no workspace).

### Config schema

In `changeset.yaml` (or under `changeset:` in the root pubspec):

| Key | Default | Description |
|-----|---------|-------------|
| `changelogPath` | `CHANGELOG.md` | Path to the changelog file (relative to root). |
| `changesetsPath` | `.changesets` | Directory for pending changesets (relative to root). |
| `packages` | `{}` | Map of package name → path (relative to root). Required for `-W` / workspace mode. |

**Example `changeset.yaml` at monorepo root:**

```yaml
changelogPath: CHANGELOG.md
changesetsPath: .changesets
packages:
  my_app: apps/my_app
  core: packages/core
  ui: packages/ui
```

## Usage

### Show help

```bash
dart run changeset --help
```

### Add a changeset

```bash
dart run changeset add --type <major|minor|patch> [--scope <scope>] [--workspace <name>] --summary "<text>"
```

- **--type:** Semantic change type: `major`, `minor`, or `patch`.
- **--scope:** (optional) Area or module affected; used for grouping in the changelog.
- **--workspace / -W:** (optional) Package name in a monorepo. Requires the package to be listed in config (`changeset.yaml` or `changeset.packages`). The changeset is stored at root and tagged with `package: <name>`.
- **--summary:** Short description of the change.

**Examples:**

```bash
dart run changeset add --type patch --summary "Fix total calculation"
dart run changeset add --type minor --scope totem --summary "Add kitchen tickets"
dart run changeset add --type major --summary "Remove deprecated v1 API"
# Monorepo: changeset for a specific package
dart run changeset add -W core --type patch --summary "Fix validation"
```

Files are created under `.changesets/` (or the configured `changesetsPath`) with the date and a slug from the summary. With `--workspace`, the file also includes a `package: <name>` line.

### Run a release

```bash
dart run changeset release [--workspace <name>]
```

1. Ensures `pubspec.yaml` and the `.changesets/` folder exist (or the configured paths when using config).
2. Reads all `.md` changesets. With `--workspace <name>`, only changesets with `package: <name>` are used; without `-W`, only changesets without a `package:` line are used.
3. Computes the bump: if any change is `major` → major; else if any is `minor` → minor; else → patch.
4. Updates `version:` in the relevant `pubspec.yaml` (current dir, or the package path from config when using `-W`).
5. Prepends a new section to `CHANGELOG.md` (root when using config). With `-W`, the section header is `## <package> X.Y.Z - date`.
6. Moves used changesets to `.changesets/archived/<new-version>/` or, with `-W`, `.changesets/archived/<package>/<new-version>/`.

**Preview without writing files:**

```bash
dart run changeset release --dry-run
dart run changeset release -W core --dry-run
```

Shows current version, bump, next version, and changelog preview.

## Generated structure

- **`.changesets/`** (or `changesetsPath`) — Pending changesets (files like `YYYY-MM-DD-<slug>.md`).
- **`.changesets/archived/<version>/`** — Changesets already included in a release (single-package mode).
- **`.changesets/archived/<package>/<version>/`** — Changesets already included in a release for that package (workspace mode with `-W`).

Each changeset file contains `type:`, optional `scope:`, optional `package:` (for workspace mode), and `summary:` lines.