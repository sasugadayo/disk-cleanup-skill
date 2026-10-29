#!/usr/bin/env bash
# Read-only disk survey for the disk-cleanup skill. Deletes nothing, writes nothing.
# Output: "## section" headers followed by TSV rows. Sizes are KB unless the column says otherwise.
# Runs on macOS (bash 3.2+) and Linux. On Windows, use survey.ps1.
#
#   STALE_DAYS=60      a project counts as idle after this many days without a commit
#   SCAN_ROOTS="$HOME" space-separated roots to search for project dependency dirs
set -u

STALE_DAYS="${STALE_DAYS:-60}"
SCAN_ROOTS="${SCAN_ROOTS:-$HOME}"
MIN_KB=10240
now=$(date +%s)
os=$(uname -s)

kb() { local s; s=$(du -sk "$1" 2>/dev/null) || return 1; echo "${s%%[[:space:]]*}"; }
# GNU first: on Linux, `stat -f %m FILE` succeeds and prints filesystem info, so check for digits
mtime() {
  local t
  t=$(stat -c %Y "$1" 2>/dev/null) && [[ "$t" =~ ^[0-9]+$ ]] && { echo "$t"; return; }
  t=$(stat -f %m "$1" 2>/dev/null) && [[ "$t" =~ ^[0-9]+$ ]] && { echo "$t"; return; }
  echo "$now"
}
days_since() { echo $(( (now - $1) / 86400 )); }
row_if_big() { local s; s=$(kb "$1") && [ "$s" -ge "$MIN_KB" ] && printf "%s\t%s\n" "$s" "$1"; }

echo "## system"
printf "os\t%s\nstale_days\t%s\n" "$os" "$STALE_DAYS"

echo
echo "## disk"
df -Pk "$HOME" | tail -1 | awk '{printf "total_kb\t%s\nused_kb\t%s\nfree_kb\t%s\nmount\t%s\n",$2,$3,$4,$6}'

echo
echo "## caches	size_kb	path"
{
  [ "$os" = Darwin ] && ls -d "$HOME"/Library/Caches/* 2>/dev/null
  ls -d "${XDG_CACHE_HOME:-$HOME/.cache}"/* 2>/dev/null
  for d in .npm .yarn/berry/cache .pnpm-store .gradle/caches .m2/repository .cargo/registry .cocoapods/repos .nuget/packages; do
    echo "$HOME/$d"
  done
  command -v go >/dev/null 2>&1 && { go env GOCACHE; go env GOMODCACHE; }
  command -v pnpm >/dev/null 2>&1 && pnpm store path 2>/dev/null
} | sort -u | while IFS= read -r d; do [ -e "$d" ] && row_if_big "$d"; done | sort -rn

echo
echo "## dev_data	size_kb	path"
for d in "$HOME/.android/avd" \
         "$HOME/Library/Developer/Xcode/DerivedData" "$HOME/Library/Developer/Xcode/UserData/Previews" \
         "$HOME/Library/Developer/Xcode/Archives" "$HOME/Library/Developer/Xcode/iOS DeviceSupport" \
         "$HOME/Library/Developer/CoreSimulator/Caches"; do
  [ -e "$d" ] && row_if_big "$d"
done
if command -v xcrun >/dev/null 2>&1; then
  echo "### unavailable_simulators"
  xcrun simctl list devices unavailable 2>/dev/null | grep -E '\(' || true
fi

echo
echo "## project_dirs	kind	size_kb	days_idle	path"
# Each kind is only reported next to the file that proves what it is, and never when git tracks it
# (a committed vendor/ is source code, not a cache). Hidden dirs and ~/Library are tool internals: skipped.
for root in $SCAN_ROOTS; do
  find "$root" -mindepth 1 -maxdepth 6 \
    \( -type d \( -name node_modules -o -name .venv -o -name venv -o -name target -o -name Pods -o -name vendor \) -prune -print \) \
    -o \( \( -path "$HOME/Library" -o -name '.*' \) -prune \) 2>/dev/null
done | while IFS= read -r p; do
  proj=$(dirname "$p"); name=$(basename "$p")
  case "$name" in
    node_modules) [ -f "$proj/package.json" ] || continue ;;
    .venv|venv)   [ -f "$p/pyvenv.cfg" ] || continue ;;
    target)       [ -f "$proj/Cargo.toml" ] || [ -f "$proj/pom.xml" ] || continue ;;
    Pods)         [ -f "$proj/Podfile" ] || continue ;;
    vendor)       [ -f "$proj/composer.json" ] || continue ;;
  esac
  [ -n "$(git -C "$proj" ls-files -- "$name" 2>/dev/null | head -1)" ] && continue
  s=$(kb "$p") && [ "$s" -ge "$MIN_KB" ] || continue
  t=$(git -C "$proj" log -1 --format=%ct 2>/dev/null || true)
  [[ "$t" =~ ^[0-9]+$ ]] || t=$(mtime "$proj")
  printf "%s\t%s\t%s\t%s\n" "$name" "$s" "$(days_since "$t")" "$p"
done | sort -t$'\t' -k2,2rn

echo
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  echo "## docker_summary"
  docker system df

  used=$(docker ps -aq | xargs docker inspect --format '{{.Image}}' 2>/dev/null | sort -u)
  echo
  echo "## docker_unused_images	size	repo:tag	created	image_id"
  docker images --no-trunc --format '{{.ID}}	{{.Size}}	{{.Repository}}:{{.Tag}}	{{.CreatedSince}}' |
  while IFS=$'\t' read -r id size name created; do
    echo "$used" | grep -q "$id" && continue
    printf "%s\t%s\t%s\t%s\n" "$size" "$name" "$created" "${id#sha256:}"
  done

  echo
  echo "## docker_used_images	repo:tag	containers"
  for id in $used; do
    printf "%s\t%s\n" "$(docker image inspect --format '{{index .RepoTags 0}}' "$id" 2>/dev/null || echo "$id")" \
      "$(docker ps -a --filter "ancestor=$id" --format '{{.Names}}({{.State}})' | paste -sd, -)"
  done

  echo
  echo "## docker_unused_volumes	size	name	compose_project	created"
  sizes=$(docker system df -v 2>/dev/null | awk '/^VOLUME NAME/{f=1;next} /^$/{f=0} f{print $1"\t"$NF}')
  for v in $(docker volume ls -qf dangling=true); do
    printf "%s\t%s\t%s\t%s\n" \
      "$(echo "$sizes" | awk -F'\t' -v n="$v" '$1==n{print $2}')" "$v" \
      "$(docker volume inspect --format '{{index .Labels "com.docker.compose.project"}}' "$v" 2>/dev/null)" \
      "$(docker volume inspect --format '{{.CreatedAt}}' "$v" 2>/dev/null | cut -c1-10)"
  done
else
  echo "## docker	unavailable (not installed, not running, or no permission)"
fi

echo
echo "## downloads_large_old	size_kb	days_old	path"
dl="${XDG_DOWNLOAD_DIR:-$HOME/Downloads}"
find "$dl" -maxdepth 2 -type f -size +102400k -mtime +"$STALE_DAYS" 2>/dev/null |
while IFS= read -r f; do printf "%s\t%s\t%s\n" "$(kb "$f")" "$(days_since "$(mtime "$f")")" "$f"; done | sort -rn

echo
echo "## trash	size_kb	path"
if [ "$os" = Darwin ]; then trash="$HOME/.Trash"; else trash="${XDG_DATA_HOME:-$HOME/.local/share}/Trash"; fi
if [ -e "$trash" ]; then
  s=$(kb "$trash") && printf "%s\t%s\n" "$s" "$trash" || printf "unreadable\t%s\n" "$trash"
fi
