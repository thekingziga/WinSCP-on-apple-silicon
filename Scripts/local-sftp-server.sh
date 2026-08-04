#!/bin/bash
# Starts a throwaway SFTP server on 127.0.0.1:2222 for testing MacSCP.
#
# Runs as your own user with no sudo: sshd only needs root for privilege
# separation when serving *other* users. Everything lives in one temp directory
# — host key, client key, authorized_keys — so your real ~/.ssh is untouched.
#
#   ./Scripts/local-sftp-server.sh start
#   ./Scripts/local-sftp-server.sh test     # run MacSCPLiveTest against it
#   ./Scripts/local-sftp-server.sh stop

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${TMPDIR:-/tmp}/macscp-sftp-test"
PORT=2222

start() {
    if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
        echo "something is already listening on $PORT" >&2
        exit 1
    fi

    mkdir -p "$DIR"
    [[ -f "$DIR/host_ed25519"   ]] || ssh-keygen -q -t ed25519 -f "$DIR/host_ed25519" -N '' -C macscp-testhost
    [[ -f "$DIR/client_ed25519" ]] || ssh-keygen -q -t ed25519 -f "$DIR/client_ed25519" -N '' -C macscp-testclient
    cp "$DIR/client_ed25519.pub" "$DIR/authorized_keys"
    chmod 600 "$DIR/host_ed25519" "$DIR/client_ed25519" "$DIR/authorized_keys"

    cat > "$DIR/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $DIR/host_ed25519
AuthorizedKeysFile $DIR/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PidFile $DIR/sshd.pid
Subsystem sftp /usr/libexec/sftp-server
LogLevel VERBOSE
EOF

    /usr/sbin/sshd -f "$DIR/sshd_config" -t
    (/usr/sbin/sshd -f "$DIR/sshd_config" -D -e > "$DIR/sshd.log" 2>&1 &)
    sleep 2

    if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
        echo "listening on 127.0.0.1:$PORT (state in $DIR)"
        echo "stop with: $0 stop"
    else
        echo "failed to start; see $DIR/sshd.log" >&2
        exit 1
    fi
}

client_args() {
    echo "$(whoami)@127.0.0.1 $PORT -o IdentitiesOnly=yes -i $DIR/client_ed25519 -o UserKnownHostsFile=$DIR/known_hosts"
}

case "${1:-start}" in
    start)
        start
        echo
        echo "point the live test at it with:"
        echo "  swift run MacSCPLiveTest $(client_args)"
        ;;
    test)
        # shellcheck disable=SC2046
        swift run --package-path "$ROOT" MacSCPLiveTest $(client_args)
        ;;
    stop)
        if [[ -f "$DIR/sshd.pid" ]]; then
            kill "$(cat "$DIR/sshd.pid")" 2>/dev/null || true
        fi
        pkill -f "sshd -f $DIR/sshd_config" 2>/dev/null || true
        rm -rf "$DIR"
        echo "stopped and removed $DIR"
        ;;
    *)
        echo "usage: $0 {start|test|stop}" >&2
        exit 2
        ;;
esac
