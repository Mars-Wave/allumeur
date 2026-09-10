#!/bin/bash
# Meta-test: proves the harness itself reports pass/fail and records stub argv correctly.

test_sandbox_is_isolated() {
    assert_eq "$SANDBOX/home" "$HOME" "HOME points into the sandbox"
    assert_ok test -d "$HOME/.allumeur-scripts/encrypted"
}

test_stub_records_argv_and_exit_code() {
    stub ping 1
    ping -c 1 -W 1 10.0.0.9
    assert_eq "1" "$?" "stubbed ping returns scripted exit code"
    assert_eq "-c 1 -W 1 10.0.0.9" "$(stub_calls ping)" "argv recorded"
}

test_stub_out_emits_stdout() {
    stub_out curl '{"ok":true}'
    assert_eq '{"ok":true}' "$(curl -sk https://127.0.0.1/api/nodes)"
}
