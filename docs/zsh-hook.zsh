# DockWings: show a check or cross beside the Dock when a terminal command
# that ran for 20 seconds or more finishes. Load it from ~/.zshrc (Settings >
# Extras copies the line):
#   source "/Applications/DockWings.app/Contents/Resources/zsh-hook.zsh"
autoload -Uz add-zsh-hook
_dockwings_bin=${${(%):-%x}:A:h}/../MacOS/DockWings

_dockwings_start() { _dockwings_cmd=$1; _dockwings_t=$SECONDS }
_dockwings_end() {
  local exit_status=$? elapsed=$(( SECONDS - ${_dockwings_t:-$SECONDS} ))
  if [[ -n $_dockwings_cmd && $elapsed -ge 20 && -x $_dockwings_bin ]]; then
    "$_dockwings_bin" --notify $exit_status $elapsed "${_dockwings_cmd[1,80]}" &!
  fi
  _dockwings_cmd=
}
add-zsh-hook preexec _dockwings_start
add-zsh-hook precmd _dockwings_end
