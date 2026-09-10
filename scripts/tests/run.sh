#!/bin/bash
# Suite entry point. Runs every tests/test_*.sh (or only those matching $1) and exits
# non-zero if anything failed, so it works as a pre-deploy gate.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./harness.sh

pattern="${1:-}"
files=()
for f in test_*.sh; do
    [ -e "$f" ] || continue
    [ -n "$pattern" ] && [[ "$f" != *"$pattern"* ]] && continue
    files+=("$f")
done

if [ ${#files[@]} -eq 0 ]; then
    echo "no test files matched${pattern:+ '$pattern'}" >&2
    exit 1
fi

# Each FILE runs in its own subshell, not just each test. Sourcing them all into one shell
# put every file's helpers in one namespace, so two files defining `node_fs` or `set_blob`
# silently shared the last definition and a file could pass alone and fail in the suite - the
# result depended on readdir order, which is the one thing a pre-deploy gate must not do.
# (A file was already named test_zzaudit.sh to force itself last; that is the symptom.)
# The subshell cannot raise the parent's counters, so each file reports its tally through a
# file, the same trick the harness already uses for per-test failures.
results=$(mktemp -d)
trap 'rm -rf "$results"' EXIT

for f in "${files[@]}"; do
    (
        # shellcheck disable=SC1090
        source "./$f"
        run_tests_in_file "$f"
        printf '%s %s\n' "$TESTS_RUN" "$TESTS_FAILED" > "$results/$f.count"
        [ "${#FAIL_LINES[@]}" -gt 0 ] && printf '%s\n' "${FAIL_LINES[@]}" > "$results/$f.fails"
    )
done

for c in "$results"/*.count; do
    [ -e "$c" ] || continue
    read -r run failed < "$c"
    TESTS_RUN=$((TESTS_RUN + run))
    TESTS_FAILED=$((TESTS_FAILED + failed))
done

echo ""
if [ "$TESTS_FAILED" -eq 0 ]; then
    printf '%s%d passed, 0 failed%s\n' "$GREEN" "$TESTS_RUN" "$NC"
    exit 0
fi
printf '%s%d/%d FAILED%s\n' "$RED" "$TESTS_FAILED" "$TESTS_RUN" "$NC"
cat "$results"/*.fails 2>/dev/null | sed 's/^/  /'
exit 1
