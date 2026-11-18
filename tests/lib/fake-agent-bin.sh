#!/usr/bin/env bash
# fake_agent_bin <path> -- write an executable stand-in for a named process
# (an agent CLI such as codex, pi or copilot-runtime, or a lookalike such as
# pip). Run it as "<path> <seconds>": both its comm and its exe basename are
# the file's name, which is what live-peer detection reads (comm for the cwd
# scan, the exe for the Copilot lock rule), and it lives until killed or the
# seconds pass. TERM, INT and HUP also end its sleep, so no child outlives it.
#
# Copying sleep to the name does not work everywhere: where coreutils is one
# multicall binary (ubuntu-26.04 runners) it dispatches on its own name and
# exits at once with "unknown program", so the "live" peer is never live and
# a not-flagged check passes on nothing (wv-087083). bash does not dispatch
# on its name, so the stand-in is a script whose interpreter is a copy of
# bash under the same name: the script name sets comm, the interpreter the
# exe.
fake_agent_bin() {
    local dir name interp
    dir=$(mkdir -p "$(dirname "$1")" && cd "$(dirname "$1")" && pwd) || return 1
    name=$(basename "$1")
    interp="$dir/.fake-agent-interp/$name"
    mkdir -p "${interp%/*}"
    cp "$(command -v bash)" "$interp"
    printf '#!%s\n' "$interp" > "$dir/$name"
    cat >> "$dir/$name" <<'EOF'
trap 'kill "$c" 2>/dev/null; exit 0' TERM INT HUP
sleep "${1:-300}" & c=$!
wait "$c"
EOF
    chmod +x "$dir/$name"
}
