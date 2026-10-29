---
name: disk-cleanup
description: >-
  Find what is eating disk space on macOS, Linux, or Windows and propose what can be safely deleted:
  tool caches, Xcode/simulator data, unused Docker images and volumes, dependency folders (node_modules, .venv, target, Pods, vendor)
  of projects that have been idle for a while, and old large downloads. Every candidate is listed with its size, last use,
  what happens if it is deleted, and how to get it back. The survey is read-only; nothing is deleted until the user picks it,
  deletion uses each tool's own command where one exists, and the freed space is measured afterwards.
  Use when the user says the disk is full, wants to free up space, clean up Docker, remove old node_modules, or delete unneeded files.
---

# disk-cleanup

Survey → propose a list → let the user choose → delete only what was chosen → measure. **Nothing is deleted during the survey.**

## 1. Survey (read-only)

Run the script that matches the OS. Paths are relative to this skill's directory.

```bash
# macOS / Linux (also WSL)
bash scripts/survey.sh
STALE_DAYS=30 SCAN_ROOTS="$HOME/src $HOME/work" bash scripts/survey.sh
```
```powershell
# Windows
powershell -ExecutionPolicy Bypass -File scripts\survey.ps1
powershell -ExecutionPolicy Bypass -File scripts\survey.ps1 -StaleDays 30 -ScanRoots C:\src,D:\work
```

It takes from tens of seconds to a few minutes (it measures folder sizes). Output is `## section` headers followed by TSV; sizes are KB except in the Docker sections, which keep Docker's own units.

If a keep list exists, drop every candidate that matches one of its lines (substring match on path or image name). It lives at `~/.config/disk-cleanup/keep.txt` (Windows: `%APPDATA%\disk-cleanup\keep.txt`). When the user says to keep something, append it there so the next run does not ask again; create the file if needed.

## 2. Classify

Put every row in one of three tiers. **When unsure, use the riskier tier.**

| Tier | Meaning | Examples | How to offer |
|---|---|---|---|
| A — regenerates | Rebuilt or re-downloaded automatically | `caches` rows, Xcode Previews / DerivedData, CoreSimulator caches, dangling (untagged) Docker images | May be offered as one grouped choice |
| B — costs effort to restore | Comes back only after a command or a long download | `project_dirs` rows, `docker_unused_images`, unavailable simulators, Android AVDs, Xcode Archives | One choice per item, with last use and the restore command |
| C — may lose data | The content may exist nowhere else | `docker_unused_volumes`, `downloads_large_old`, trash | Inspect first, one item at a time, never grouped |

Rules:
- **project_dirs**: only offer rows whose `days_idle` exceeds `STALE_DAYS`; treat newer ones as in use and leave them out. The script already skips folders tracked by git and folders without their marker file (e.g. `node_modules` with no `package.json`), so do not add such paths back by hand.
- **Docker images**: only `docker_unused_images` are candidates. Never offer an image in `docker_used_images`, even if its container is stopped; removing it needs the container removed first, which is a separate question. Do not judge by age or name — an old-looking image may be backing a running container.
- **Docker volumes**: anonymous volumes (empty `compose_project`) are common. Before offering one, look inside: `docker run --rm -v <name>:/v alpine ls -la /v`. If it holds database files (`PG_VERSION`, `mysql/`, `ibdata1`, `*.rdb`, …) say plainly that the data will be lost.
- **Tool images the user runs regularly** (scanners, build images) stay in tier B with "will be re-pulled on next use".
- **Browser caches** refill immediately while the browser is open; suggest closing the browser first.
- **Trash**: on macOS it reads `unreadable` unless the terminal has Full Disk Access. Mention emptying it; do not ask for the permission.

## 3. Propose

One table, largest first. Columns: tier, item, size, last used, what happens if deleted, how to restore. End with the total and the total for tier A alone.
Then ask the user to choose (use a multi-select question tool if the agent has one). Group tier A into one option, list B and C items individually from largest down, and let the user name others in free text.

## 4. Delete — only what was chosen

**Prefer the tool's own command**; it knows what is safe (e.g. Docker refuses to remove an image a container uses).

| Target | Command |
|---|---|
| Chosen Docker images | `docker rmi <image_id>` — not `docker image prune -a`, which removes images nobody reviewed |
| Dangling images | `docker image prune -f` |
| Chosen Docker volumes | `docker volume rm <name>` |
| Homebrew | `brew cleanup -s` |
| Go | `go clean -cache` / `go clean -modcache` (module cache files are read-only; plain delete fails) |
| npm / pnpm / yarn | `npm cache clean --force` / `pnpm store prune` / `yarn cache clean` |
| pip | `pip cache purge` |
| Unavailable iOS simulators | `xcrun simctl delete unavailable` |
| Other caches, Xcode data, project_dirs | macOS/Linux: `rm -rf -- "<path>"` · Windows: `Remove-Item -LiteralPath "<path>" -Recurse -Force` |
| Downloads | Move to the trash, never delete outright: macOS `mv "<path>" ~/.Trash/` · Linux `gio trash "<path>"` (if missing, ask before deleting) · Windows `Add-Type -AssemblyName Microsoft.VisualBasic; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile("<path>", 'OnlyErrorDialogs', 'SendToRecycleBin')` |

Before every direct delete, check all four. If any fails, skip the item and report it.
1. The path appeared verbatim in the survey output (not typed from memory or guessed).
2. It is inside the user's home directory and is not the home directory itself or a top-level folder such as `~/Library`, `~/.cache`, `%LOCALAPPDATA%`.
3. It matches its section: a `project_dirs` path ends with its `kind`; a cache path is under a cache directory.
4. The variable holding it is non-empty and the path exists (`[ -n "$P" ] && [ -e "$P" ]` / `Test-Path -LiteralPath $P`).

Never use `sudo` or an elevated shell, and never propose anything outside the home directory (system folders, other users, package-manager prefixes).

## 5. Report

Compare `free_kb` from the survey with the free space now (`df -Pk "$HOME"` / `Get-PSDrive`) and report the space actually freed. Docker Desktop (macOS/Windows) may take a while to hand freed space back to the host disk; say so.
List what was not deleted — items that failed a check, and large items the user did not choose — one line each.
