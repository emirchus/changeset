# changeset

A tool to manage changesets in **Dart** and **Flutter** projects. It lets you record changes (major, minor, patch), group them by scope, and generate releases by updating `pubspec.yaml`, `CHANGELOG.md`, and archiving used changesets.

Works with plain Dart packages (version `X.Y.Z`) and Flutter projects (version `X.Y.Z+build`). The version format is detected from your `pubspec.yaml` and preserved on release.

## Features

- **Add changesets:** Record a change with type (major, minor, patch), summary, and optionally a scope.
- **Release:** Reads all changesets, decides the bump from the highest type present, updates the version in `pubspec.yaml` (keeps Dart `X.Y.Z` or Flutter `X.Y.Z+build` format), writes the entry to `CHANGELOG.md`, and archives changesets under `.changesets/archived/<version>`.
- **Dry-run:** The `release --dry-run` command shows the release plan without modifying any files.

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

## Usage

### Show help

```bash
dart run changeset --help
```

### Add a changeset

```bash
dart run changeset add --type <major|minor|patch> [--scope <scope>] --summary "<text>"
```

- **--type:** Semantic change type: `major`, `minor`, or `patch`.
- **--scope:** (optional) Area or module affected; used for grouping in the changelog.
- **--summary:** Short description of the change.

**Examples:**

```bash
dart run changeset add --type patch --summary "Fix total calculation"
dart run changeset add --type minor --scope totem --summary "Add kitchen tickets"
dart run changeset add --type major --summary "Remove deprecated v1 API"
```

Files are created under `.changesets/` with the date and a slug from the summary.

### Run a release

```bash
dart run changeset release
```

1. Ensures `pubspec.yaml` and the `.changesets/` folder exist.
2. Reads all `.md` changesets (ignores files whose name starts with `.`).
3. Computes the bump: if any change is `major` → major; else if any is `minor` → minor; else → patch.
4. Updates `version:` in `pubspec.yaml` (increments X.Y.Z; for Flutter format also increments the build number).
5. Prepends a new section to `CHANGELOG.md`, grouped by scope.
6. Moves used changesets to `.changesets/archived/<new-version>/`.

**Preview without writing files:**

```bash
dart run changeset release --dry-run
```

Shows current version, bump, next version, and changelog preview.

## Generated structure

- **`.changesets/`** — Pending changesets (files like `YYYY-MM-DD-<slug>.md`).
- **`.changesets/archived/<version>/`** — Changesets already included in a release.

Each changeset file contains `type:`, optional `scope:`, and `summary:` lines.