# lib/recipe.sh: prepended to every recipe by ./nv (after the NV_* settings from site.json). Two modes:
#   live   (./nv run):    runs on the server as root.
#   render (./nv render): runs on your computer with an empty PATH. Nothing is run: every command is logged to
#                         <dir>/commands.log, and each file the recipe would install is written to <dir>/files/<path>
#                         (its mode and owner go to <dir>/modes). Used to review a change, and to diff against the
#                         live server, before running it for real.
set -euo pipefail

if [ -n "${NV_RENDER:-}" ]; then
  _log() { printf '+ %s\n' "$*" >> "$NV_RENDER/commands.log"; }
  command_not_found_handle() { _log "$@"; return 0; }   # PATH is empty, so every external command lands here
  run() { _log "$@"; }                                  # for commands called by absolute path
  live() { return 1; }
  put() {  # put <path> [mode] [owner[:group]] < content
    local p=$1
    /bin/mkdir -p "$NV_RENDER/files${p%/*}"
    /bin/cat > "$NV_RENDER/files$p"
    printf '%s %s %s\n' "${2:-644}" "${3:-root:root}" "$p" >> "$NV_RENDER/modes"
  }
  add_line() { _log "add_line $1 <<< $2"; }
else
  run() { "$@"; }
  live() { return 0; }
  put() {  # put <path> [mode] [owner[:group]] < content: writes the whole file (keeps the inode and SELinux label)
    local p=$1 o=${3:-root:root}
    mkdir -p "${p%/*}"
    cat > "$p"
    chmod "${2:-644}" "$p"; chown "$o" "$p"
  }
  add_line() {  # add_line <file> <line>: append the line unless the file already has it
    grep -qxF -- "$2" "$1" 2>/dev/null || printf '%s\n' "$2" >> "$1"
  }
fi
