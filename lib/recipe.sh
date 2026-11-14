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
else
  run() { "$@"; }
  live() { return 0; }
  _NGINX_PUT=$(mktemp /tmp/nv-nginx-put.XXXXXX)   # files to restore; a file, not an array: put may run in a pipe
  trap 'rm -f "$_NGINX_PUT"' EXIT
  put() {  # put <path> [mode] [owner[:group]] < content: writes the whole file (keeps the inode and SELinux label)
    local p=$1 o=${3:-root:root}
    mkdir -p "${p%/*}"
    if [[ $p == /etc/nginx/* ]]; then   # keep the previous version until nginx_apply has tested the new one
      if [ -e "$p" ]; then cp -p "$p" "$p.nv-prev"; else : > "$p.nv-new"; fi
      echo "$p" >> "$_NGINX_PUT"
    fi
    cat > "$p"
    chmod "${2:-644}" "$p"; chown "$o" "$p"
  }
  add_line() {  # add_line <file> <line>: append the line unless the file already has it
    grep -qxF -- "$2" "$1" 2>/dev/null || printf '%s\n' "$2" >> "$1"
  }
  nginx_apply() {  # nginx_apply [reload|restart|none]: test the config; if it fails, put back every nginx file this
                   # run wrote (so a bad file never waits on disk for the next reboot) and stop the recipe
    local p
    if ! nginx -t -q 2>/tmp/nginx-test.$$; then
      cat /tmp/nginx-test.$$ >&2; rm -f /tmp/nginx-test.$$
      sort -u "$_NGINX_PUT" | while IFS= read -r p; do
        if [ -e "$p.nv-prev" ]; then mv -f "$p.nv-prev" "$p"; else rm -f "$p"; fi; rm -f "$p.nv-new"
      done
      echo "nginx config test FAILED: the previous config is back in place, nothing reloaded" >&2
      exit 1
    fi
    rm -f /tmp/nginx-test.$$
    sort -u "$_NGINX_PUT" | while IFS= read -r p; do rm -f "$p.nv-prev" "$p.nv-new"; done
    : > "$_NGINX_PUT"
    case ${1:-reload} in none) ;; *) systemctl "${1:-reload}" nginx ;; esac
  }
fi
