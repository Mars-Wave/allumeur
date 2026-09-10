#!/usr/bin/env bash
# Pure-bash test harness. No bats, no deps beyond coreutils - the server has 3.5GB of disk
# and no package budget, so the suite has to run there with exactly what bash ships with.
#
# A test file is any tests/test_*.sh. It sources this harness, defines test_* functions and
# the runner discovers them. Each test runs in its own subshell with its own sandbox HOME
# and its own PATH of stubbed executables, so tests cannot leak state into one another.

set -uo pipefail

# In the repo the scripts live in ../src; once deployed they sit in the parent directory
# itself (/root/.allumeur-scripts/*.sh with tests/ beside them). Support both, so the suite
# runs from wherever it happens to be.
if [ -z "${SRC_DIR:-}" ]; then
    _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -d "$_here/../src" ]; then SRC_DIR="$(cd "$_here/../src" && pwd)"
    else SRC_DIR="$(cd "$_here/.." && pwd)"; fi
    unset _here
fi
[ -f "$SRC_DIR/nodes.sh" ] || { echo "cannot find the scripts under $SRC_DIR" >&2; exit 1; }

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""
FAIL_LINES=()

RED=$'\e[31m'; GREEN=$'\e[32m'; DIM=$'\e[2m'; NC=$'\e[0m'

# ── sandbox ─────────────────────────────────────────────────────────────────
# Every test gets a throwaway HOME laid out like the real server, so the scripts'
# hardcoded "$HOME/.allumeur-scripts/..." paths resolve inside the sandbox.
setup_sandbox() {
    SANDBOX="$(mktemp -d)"
    export HOME="$SANDBOX/home"
    export STUB_DIR="$SANDBOX/stubs"
    export STUB_LOG="$SANDBOX/stub.log"
    mkdir -p "$HOME/.allumeur-scripts/encrypted" "$STUB_DIR" "$STUB_DIR/.plan"
    # The scripts source each other through "$HOME/.allumeur-scripts/...", so install them
    # into the sandbox exactly as they are deployed on the server.
    cp "$SRC_DIR"/*.sh "$HOME/.allumeur-scripts/" 2>/dev/null
    : > "$STUB_LOG"
    export PATH="$STUB_DIR:$PATH"
}

teardown_sandbox() {
    [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}

# ── stubs ───────────────────────────────────────────────────────────────────
# stub <name>            -> shim that logs argv and exits 0
# stub <name> <exit>     -> ... and exits <exit>
# stub_out <name> <text> -> shim that also prints <text> on stdout
#
# Every invocation appends "<name>\t<args...>" to $STUB_LOG, so a test asserts on what the
# code *tried to do* to the outside world rather than needing a real ssh/ping/curl.
stub() {
    local name="$1" code="${2:-0}"
    cat > "$STUB_DIR/$name" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\n' "$name" "\$*" >> "$STUB_LOG"
exit $code
EOF
    chmod +x "$STUB_DIR/$name"
}

stub_out() {
    local name="$1" out="$2" code="${3:-0}"
    cat > "$STUB_DIR/$name" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\n' "$name" "\$*" >> "$STUB_LOG"
cat <<'__STUB_EOF__'
$out
__STUB_EOF__
exit $code
EOF
    chmod +x "$STUB_DIR/$name"
}

# stub_script <name> <<'EOF' ... EOF  -> full control; body is the stub's bash source.
# The body still gets argv logging prepended.
stub_script() {
    local name="$1"
    {
        echo '#!/usr/bin/env bash'
        printf 'printf %s"\\t"%s"\\n" "%s" "$*" >> "$STUB_LOG"\n' '"%s"' '"%s"' "$name"
        cat
    } > "$STUB_DIR/$name"
    chmod +x "$STUB_DIR/$name"
}

# Calls recorded for a command, one per line, args only.
stub_calls() { grep -P "^$1\t" "$STUB_LOG" 2>/dev/null | cut -f2- || true; }
stub_count() { stub_calls "$1" | grep -c . || true; }

# ── assertions ──────────────────────────────────────────────────────────────
# A test body runs in a subshell, so a counter increment here would be lost on return.
# Failures are therefore recorded as lines in a sandbox file that the parent tallies.
_fail() {
    printf '%s: %s\n' "$CURRENT_TEST" "${1%%$'\n'*}" >> "${SANDBOX:-/tmp}/.failures"
    printf '%s  ✗ %s%s\n    %s\n' "$RED" "$CURRENT_TEST" "$NC" "$1" >&2
}

assert_eq() {
    local want="$1" got="$2" msg="${3:-}"
    if [ "$want" != "$got" ]; then
        _fail "${msg:-values differ}"$'\n'"    want: [$want]"$'\n'"     got: [$got]"
        return 1
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    case "$haystack" in
        *"$needle"*) : ;;
        *) _fail "${msg:-missing substring}"$'\n'"    want substring: [$needle]"$'\n'"    in: [$haystack]"; return 1 ;;
    esac
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    case "$haystack" in
        *"$needle"*) _fail "${msg:-unexpected substring}"$'\n'"    unwanted: [$needle]"$'\n'"    in: [$haystack]"; return 1 ;;
    esac
}

is_function() { declare -F "$1" >/dev/null; }

assert_ok()   { if ! "$@"; then _fail "expected success: $*"; return 1; fi; }
assert_fail() { if "$@"; then _fail "expected failure: $*"; return 1; fi; }

assert_file()    { [ -f "$1" ] || { _fail "${2:-expected file to exist}: $1"; return 1; }; }
assert_no_file() { [ -f "$1" ] && { _fail "${2:-expected file to be absent}: $1"; return 1; }; return 0; }

assert_le() {
    [ "$1" -le "$2" ] || { _fail "${3:-expected $1 <= $2}"$'\n'"    got: $1 > $2"; return 1; }
}

assert_lt() {
    [ "$1" -lt "$2" ] || { _fail "${3:-expected $1 < $2}"$'\n'"    got: $1 >= $2"; return 1; }
}

assert_rc() {
    local want="$1"; shift
    "$@"; local got=$?
    [ "$got" = "$want" ] || { _fail "rc mismatch for: $*"$'\n'"    want rc $want, got $got"; return 1; }
}

assert_file_contains() {
    local f="$1" needle="$2"
    [ -f "$f" ] || { _fail "file missing: $f"; return 1; }
    assert_contains "$(cat "$f")" "$needle" "file $f"
}

# ── runner ──────────────────────────────────────────────────────────────────
run_tests_in_file() {
    local file="$1"
    # shellcheck disable=SC1090
    local fns
    fns=$(grep -oP '^\s*(function\s+)?\Ktest_[A-Za-z0-9_]+(?=\s*\(\))' "$file" || true)
    [ -z "$fns" ] && return 0

    printf '%s%s%s\n' "$DIM" "$(basename "$file")" "$NC"
    local fn
    for fn in $fns; do
        CURRENT_TEST="$fn"
        TESTS_RUN=$((TESTS_RUN + 1))
        setup_sandbox
        # Each test body runs in a subshell so a `return 1` or a stray `exit` cannot abort
        # the suite; failures are counted via a file since the subshell can't mutate ours.
        (
            set +e
            declare -F setup >/dev/null && setup
            "$fn"
            declare -F teardown >/dev/null && teardown
            exit 0
        )
        local n=0
        [ -f "$SANDBOX/.failures" ] && n=$(grep -c . "$SANDBOX/.failures")
        if [ "$n" -gt 0 ]; then
            TESTS_FAILED=$((TESTS_FAILED + n))
            mapfile -t -O "${#FAIL_LINES[@]}" FAIL_LINES < "$SANDBOX/.failures"
        else
            printf '%s  ✓ %s%s\n' "$GREEN" "$fn" "$NC"
        fi
        teardown_sandbox
    done
}
