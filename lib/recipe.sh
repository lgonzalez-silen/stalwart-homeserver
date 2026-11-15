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
  nginx_apply() { _log "nginx_apply ${1:-reload}"; }
  nginx_track() { _log "nginx_track $1"; }
else
  run() { "$@"; }
  live() { return 0; }
  # nginx files changed this run, kept in a file (not an array: put may run in a pipe, i.e. a subshell)
  _NGINX_PUT=$(mktemp /run/nv-nginx-put.XXXXXX)
  _nginx_on_exit() {   # the recipe stopped after changing nginx files but before nginx_apply tested them: put them back
    local p
    if [ -s "$_NGINX_PUT" ]; then
      while IFS= read -r p; do
        if [ -e "$p.nv-prev" ]; then mv -f "$p.nv-prev" "$p"; elif [ -e "$p.nv-new" ]; then rm -f "$p" "$p.nv-new"; fi
      done < <(sort -u "$_NGINX_PUT")
      echo "recipe stopped before its nginx changes were tested: they were undone" >&2
    fi
    rm -f "$_NGINX_PUT"
  }
  trap _nginx_on_exit EXIT
  nginx_track() {  # nginx_track <file>: back up a file before changing it, so nginx_apply can put it back.
                   # An older backup left by an interrupted run is kept: it is the last version that passed the test.
                   # A file that doesn't exist yet gets a .nv-new marker, so the rollback knows it may remove it.
    if [ ! -e "$1.nv-prev" ] && [ ! -e "$1.nv-new" ]; then
      if [ -e "$1" ]; then cp -p "$1" "$1.nv-prev" || { echo "can't back up $1: stopping" >&2; exit 1; }
      else : > "$1.nv-new"; fi
    fi
    echo "$1" >> "$_NGINX_PUT"
  }
  put() {  # put <path> [mode] [owner[:group]] < content: writes the whole file (keeps the inode and SELinux label)
    local p=$1 o=${3:-root:root}
    mkdir -p "${p%/*}"
    [[ $p == /etc/nginx/* ]] && nginx_track "$p"   # untested until nginx_apply
    cat > "$p"
    chmod "${2:-644}" "$p"; chown "$o" "$p"
  }
  add_line() {  # add_line <file> <line>: append the line unless the file already has it
    grep -qxF -- "$2" "$1" 2>/dev/null || printf '%s\n' "$2" >> "$1"
  }
  nginx_apply() {  # nginx_apply [reload|restart|none]: test the config; if it fails, put back every nginx file this
                   # run changed (so a bad file never waits on disk for the next reboot) and stop the recipe
    local p out list=()
    [ -s "$_NGINX_PUT" ] && mapfile -t list < <(sort -u "$_NGINX_PUT")
    if ! out=$(nginx -t 2>&1); then
      printf '%s\n' "$out" >&2
      for p in "${list[@]}"; do   # no pipe/subshell: one failed restore must not stop the others
        if [ -e "$p.nv-prev" ]; then mv -f "$p.nv-prev" "$p" || echo "could not restore $p" >&2
        elif [ -e "$p.nv-new" ]; then rm -f "$p" "$p.nv-new" || echo "could not remove $p" >&2
        else echo "no backup of $p: left as it is (check it by hand)" >&2; fi
      done
      : > "$_NGINX_PUT"
      echo "nginx config test FAILED: the previous config is back in place, nothing reloaded" >&2
      exit 1
    fi
    printf '%s\n' "$out" | grep -F '[warn]' >&2 || true   # warnings (e.g. a duplicate server_name) stay visible
    for p in "${list[@]}"; do rm -f "$p.nv-prev" "$p.nv-new"; done
    : > "$_NGINX_PUT"
    # reload only signals nginx: give the new workers a moment, or a check right after can still meet the old config
    case ${1:-reload} in none) ;; reload) systemctl reload nginx; sleep 2 ;; *) systemctl "$1" nginx ;; esac
  }
fi
