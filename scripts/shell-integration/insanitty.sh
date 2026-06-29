#!/bin/bash
# insanitty shell integration. Source from your shell rc:
#   source <insanitty data dir>/shell-integration/insanitty.sh
#
# Ported from Fantastty's fantastty.sh (terminal-protocol level, cross-platform: works
# through SSH, tmux, and mosh). Emits OSC 9 `insanitty:...` sequences that the app
# intercepts as in-app notes / ticket / PR URLs on the current workspace.

# Emit an OSC 9 payload with tmux / GNU screen passthrough as needed.
__insanitty_osc9() {
    local payload="$1"
    if [[ -n "$TMUX" ]]; then
        printf '\ePtmux;\e\e]9;%s\a\e\\' "$payload"      # tmux passthrough
    elif [[ "$TERM" == screen* ]]; then
        printf '\eP\e]9;%s\a\e\\' "$payload"             # GNU screen passthrough
    else
        printf '\e]9;%s\a' "$payload"                    # direct (insanitty / SSH / mosh)
    fi
}

# insanitty-note "text" — add a timestamped note to the current workspace.
insanitty-note() {
    local content="$*"
    if [[ -z "$content" ]]; then
        echo "Usage: insanitty-note <note content>" >&2
        return 1
    fi
    __insanitty_osc9 "insanitty:note;${content}"
}

# insanitty-ticket <url> / insanitty-pr <url> — set the workspace's ticket / PR URL.
insanitty-ticket() { [[ -n "$1" ]] && __insanitty_osc9 "insanitty:ticket;$1"; }
insanitty-pr()     { [[ -n "$1" ]] && __insanitty_osc9 "insanitty:pr;$1"; }

alias in='insanitty-note'
export -f insanitty-note insanitty-ticket insanitty-pr 2>/dev/null || true
