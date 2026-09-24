#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <linux-binary> [expected-version]" >&2
    exit 2
fi

binary="$(realpath "$1")"
expected_version="${2:-}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

for command in curl env file realpath sed seq setsid timeout; do
    command -v "$command" >/dev/null || {
        echo "Required smoke-test command is missing: $command" >&2
        exit 1
    }
done

temporary_paths=()
cleanup() {
    for temporary_path in "${temporary_paths[@]}"; do
        if [[ -d "$temporary_path" ]]; then
            rm -rf -- "$temporary_path"
        else
            rm -f -- "$temporary_path"
        fi
    done
}
trap cleanup EXIT

[[ -x "$binary" ]] || { echo "Not executable: $binary" >&2; exit 1; }
file "$binary" | grep -q 'ELF 64-bit'

version_output="$($binary --version)"
if [[ -n "$expected_version" ]]; then
    grep -Fq "version $expected_version" <<<"$version_output"
fi

help_output="$($binary --help)"
for command in login search menu store-details item-details \
    restaurant-item-details find-items find-nearby-stores \
    build-grocery-list cart promo order address payment-method; do
    grep -Eq "^[[:space:]]+$command([[:space:]]|$)" <<<"$help_output" || {
        echo "Missing root command in --help: $command" >&2
        exit 1
    }
done

# Exercise browser launch and the localhost OAuth callback server without
# exchanging a real authorization code or persisting credentials.
oauth_stdout="$(mktemp)"
oauth_stderr="$(mktemp)"
callback_body="$(mktemp)"
temporary_paths+=("$oauth_stdout" "$oauth_stderr" "$callback_body")
env -u DD_CLI_CREDENTIAL_BACKEND \
    -u DD_CLI_1PASSWORD_VAULT \
    -u DD_CLI_1PASSWORD_ACCOUNT \
    -u DD_CLI_1PASSWORD_ITEM \
    BROWSER=true timeout --signal=INT --kill-after=1 15 \
    "$binary" login >"$oauth_stdout" 2>"$oauth_stderr" &
oauth_pid=$!
callback_received=0
for _attempt in $(seq 1 100); do
    if curl --silent --fail --output "$callback_body" \
        'http://localhost:4180/oauth2/callback?error=access_denied&error_description=linux-smoke'; then
        callback_received=1
        break
    fi
    sleep 0.1
done
if [[ "$callback_received" -ne 1 ]]; then
    kill "$oauth_pid" 2>/dev/null || true
    wait "$oauth_pid" 2>/dev/null || true
    echo "OAuth callback listener did not become ready." >&2
    exit 1
fi
set +e
wait "$oauth_pid"
oauth_status=$?
set -e
[[ "$oauth_status" -eq 1 ]] || {
    echo "OAuth denial returned unexpected status: $oauth_status" >&2
    exit 1
}
grep -Fq 'You can close this tab' "$callback_body"
grep -Fq 'identity.doordash.com/authorize' "$oauth_stderr"
grep -Fq 'Authentication/Authorization failed' "$oauth_stderr"

# Exercise the no-tunnel path. It reads the browser's final localhost URL from
# a hidden prompt and relays it to the same loopback callback server, so the
# registered redirect URI and OAuth state validation remain unchanged.
manual_dir="$(mktemp -d)"
temporary_paths+=("$manual_dir")
manual_input="$manual_dir/input"
manual_stdout="$manual_dir/stdout"
manual_stderr="$manual_dir/stderr"
mkfifo "$manual_input"
exec {manual_fd}<>"$manual_input"
# Detach the controlling TTY so getpass reads the synthetic URL from the FIFO.
env -u DD_CLI_CREDENTIAL_BACKEND \
    -u DD_CLI_1PASSWORD_VAULT \
    -u DD_CLI_1PASSWORD_ACCOUNT \
    -u DD_CLI_1PASSWORD_ITEM \
    BROWSER=true timeout --signal=INT --kill-after=1 15 \
    setsid --wait "$binary" login --manual \
    <&$manual_fd >"$manual_stdout" 2>"$manual_stderr" &
manual_pid=$!
manual_auth_url=""
for _attempt in $(seq 1 100); do
    manual_auth_url="$(sed -n 's/^Open in browser: //p' "$manual_stderr" | tail -n 1)"
    [[ -n "$manual_auth_url" ]] && break
    sleep 0.1
done
manual_state="$(sed -n 's/.*[?&]state=\([^&]*\).*/\1/p' <<<"$manual_auth_url")"
manual_port="$(sed -n 's/.*redirect_uri=http%3A%2F%2Flocalhost%3A\([0-9][0-9]*\)%2Foauth2%2Fcallback.*/\1/p' <<<"$manual_auth_url")"
if [[ -z "$manual_state" || -z "$manual_port" ]]; then
    kill "$manual_pid" 2>/dev/null || true
    wait "$manual_pid" 2>/dev/null || true
    echo "Manual OAuth flow did not print parseable callback metadata." >&2
    exit 1
fi
printf '%s\n' \
    "http://localhost:$manual_port/oauth2/callback?error=access_denied&error_description=manual-smoke&state=$manual_state" \
    >&$manual_fd
exec {manual_fd}>&-
set +e
wait "$manual_pid"
manual_status=$?
set -e
[[ "$manual_status" -eq 1 ]] || {
    echo "Manual OAuth denial returned unexpected status: $manual_status" >&2
    exit 1
}
grep -Fq 'Manual callback mode' "$manual_stderr"
grep -Fq 'Authentication/Authorization failed' "$manual_stderr"

# Confirm the compiled runner can replace Secret Service with the optional
# 1Password backend and pass the normal credential gate. The fixture exposes
# only a synthetic token and implements read operations; backend writes are
# covered by the Python unit tests.
if [[ -x "$repo_root/tests/fake-op" ]]; then
    fake_op_dir="$(mktemp -d)"
    temporary_paths+=("$fake_op_dir")
    ln -s "$repo_root/tests/fake-op" "$fake_op_dir/op"
    env -u DD_CLI_1PASSWORD_ACCOUNT \
        -u DD_CLI_1PASSWORD_ITEM \
        PATH="$fake_op_dir:$PATH" \
        DD_CLI_CREDENTIAL_BACKEND=1password \
        DD_CLI_1PASSWORD_VAULT='Smoke Test' \
        "$binary" order --help | grep -Fq 'checkout-url'
fi

# When a build-time Python containing keyring is supplied, exercise the actual
# Linux Secret Service path as well as authenticated command-group loading.
if [[ -n "${KEYRING_PYTHON:-}" ]] && command -v dbus-run-session >/dev/null \
    && command -v gnome-keyring-daemon >/dev/null; then
    smoke_home="$(mktemp -d)"
    temporary_paths+=("$smoke_home")
    export smoke_home binary
    dbus-run-session -- bash -c '
        set -euo pipefail
        unset DD_CLI_CREDENTIAL_BACKEND DD_CLI_1PASSWORD_VAULT \
            DD_CLI_1PASSWORD_ACCOUNT DD_CLI_1PASSWORD_ITEM
        export HOME="$smoke_home"
        eval "$(printf linux-smoke-keyring | gnome-keyring-daemon --unlock --components=secrets)"
        "$KEYRING_PYTHON" -c '\''import keyring; keyring.set_password("dd-cli", "oauth-tokens", "{\"access_token\":\"smoke\",\"refresh_token\":\"smoke\",\"expires_at\":4102444800}")'\''
        root_commands=(login search menu store-details item-details
            restaurant-item-details find-items find-nearby-stores
            build-grocery-list cart promo order address payment-method)
        for command in "${root_commands[@]}"; do
            "$binary" "$command" --help >/dev/null
        done

        nested_commands=(
            "cart list" "cart add-items" "cart show" "cart remove-item" "cart delete"
            "promo list" "promo apply" "promo remove"
            "order history" "order reorder" "order receipt" "order status"
            "order preview" "order submit" "order checkout-url"
            "address list" "address set" "payment-method list"
        )
        for command in "${nested_commands[@]}"; do
            read -r -a args <<<"$command"
            "$binary" "${args[@]}" --help >/dev/null
        done
    '
fi

echo "Linux smoke tests passed: $version_output"
