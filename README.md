# disk-cleanup

An agent skill that frees disk space without surprises. It surveys your machine read-only, lists what can be deleted with the size, last use, consequence, and restore command for each item, and deletes only what you pick.

Works on macOS, Linux, and Windows.

## What it looks at

- Tool caches (npm, pnpm, yarn, pip, Go, Gradle, Maven, Cargo, NuGet, Homebrew, browsers, …)
- Xcode DerivedData / Previews / Archives, iOS simulators, Android AVDs
- Docker images and volumes that no container uses
- `node_modules`, `.venv`, `target`, `Pods`, `vendor` of projects with no commit for a while (60 days by default)
- Large old files in Downloads, and the trash

## Safety

- The survey only reads. Nothing is deleted until you choose it.
- Items are sorted into three tiers — regenerates by itself / costs effort to restore / may lose data — and the last tier is inspected and asked about one item at a time.
- Folders tracked by git are never offered, and dependency folders are only offered next to the file that proves what they are (`node_modules` next to `package.json`, …).
- Images used by any container, even a stopped one, are never offered.
- Deletion uses the tool's own command where one exists (`docker rmi`, `brew cleanup`, `go clean`, …). Downloads go to the trash, not `rm`.
- No `sudo`, nothing outside your home directory.

## Install

```bash
npx skills add OWNER/disk-cleanup-skill
```

Then ask your agent: "my disk is full" / "free up some space" / "clean up Docker".

## Run the survey by hand

```bash
bash skills/disk-cleanup/scripts/survey.sh                         # macOS / Linux
powershell -ExecutionPolicy Bypass -File skills\disk-cleanup\scripts\survey.ps1   # Windows
```
