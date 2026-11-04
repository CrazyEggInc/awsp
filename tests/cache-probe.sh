#!/usr/bin/env bash

# Run with bash or zsh. AWS is mocked; no real credentials or services are used.
set -eu
cd "$(dirname "$0")/.."
source ./awsp_functions.sh

test_dir=$(mktemp -d)
trap 'rm -f "$test_dir/calls" "$test_dir/output"; rmdir "$test_dir"' EXIT

assert_no_match() {
    if grep -q "$1" "$2"; then
        echo "Unexpected match: $1 in $2" >&2
        return 1
    fi
}

aws() {
    printf '%s\n' "$*" >> "$test_dir/calls"
    case "$1 $2" in
        'configure get')
            case "$3" in
                aws_access_key_id) echo original-key ;;
                region) echo us-east-1 ;;
                mfa_serial) echo arn:aws:iam::123456789012:mfa/test ;;
                aws_session_token) echo cached-token ;;
                awsp_cache_valid) echo true ;;
                role_arn|source_profile|awsp_role_arn|awsp_source_profile) return 1 ;;
                *) echo "Unexpected configuration lookup: $3" >&2; return 1 ;;
            esac
            ;;
        'account list-regions')
            case "$scenario" in
                valid) echo '{"Regions": []}' ;;
                denied|refresh-failed) echo 'An error occurred (AccessDeniedException) when calling the ListRegions operation: MFA required' >&2; return 254 ;;
                expired) echo 'An error occurred (ExpiredToken) when calling the ListRegions operation: Token expired' >&2; return 254 ;;
                invalid) echo 'An error occurred (InvalidClientTokenId) when calling the ListRegions operation: Invalid token' >&2; return 254 ;;
                network) echo 'Could not connect to the endpoint URL' >&2; return 255 ;;
                service) echo 'An error occurred (InternalServerException) when calling the ListRegions operation: Unavailable' >&2; return 254 ;;
            esac
            ;;
        'sts get-caller-identity') echo '{"Arn": "test-user"}' ;;
        'sts get-session-token')
            if [ "$scenario" = refresh-failed ]; then
                echo 'An error occurred (AccessDenied) when calling the GetSessionToken operation: Invalid MFA' >&2
                return 254
            fi
            echo '{"Credentials":{"AccessKeyId":"fresh-key","SecretAccessKey":"fresh-secret","SessionToken":"fresh-token"}}'
            ;;
        'configure set'|'configure list') ;;
        *) echo "Unexpected AWS command: $*" >&2; return 1 ;;
    esac
}

for scenario in denied expired invalid valid network service refresh-failed; do
    echo "Testing: $scenario"
    (
        : > "$test_dir/calls"
        export AWS_PROFILE=previous AWS_DEFAULT_PROFILE=previous
        export AWS_ACCESS_KEY_ID=previous-key AWS_SECRET_ACCESS_KEY=previous-secret AWS_SESSION_TOKEN=previous-token
        result=0
        _awsSwitchProfile example > "$test_dir/output" 2>&1 <<<'123456' || result=$?
        case "$scenario" in
            denied|expired|invalid)
                test "$result" -eq 0
                grep -q 'Credentials need refreshing' "$test_dir/output"
                grep -q '^sts get-session-token ' "$test_dir/calls"
                grep -q '^configure set awsp_cache_valid --profile example-temp false$' "$test_dir/calls"
                grep -q '^configure set aws_session_token --profile example-temp fresh-token$' "$test_dir/calls"
                test "$AWS_PROFILE" = example-temp
                ;;
            valid)
                test "$result" -eq 0
                test "$AWS_PROFILE" = example-temp
                assert_no_match '^sts get-session-token\|^configure set ' "$test_dir/calls"
                assert_no_match 'Credentials need refreshing' "$test_dir/output"
                ;;
            network|service)
                test "$result" -ne 0
                test "$AWS_PROFILE" = previous
                test "$AWS_DEFAULT_PROFILE" = previous
                test "$AWS_ACCESS_KEY_ID" = previous-key
                test "$AWS_SECRET_ACCESS_KEY" = previous-secret
                test "$AWS_SESSION_TOKEN" = previous-token
                assert_no_match '^sts get-session-token\|^configure set ' "$test_dir/calls"
                assert_no_match 'Credentials need refreshing' "$test_dir/output"
                grep -q 'Could not connect\|InternalServerException' "$test_dir/output"
                ;;
            refresh-failed)
                test "$result" -ne 0
                test "$AWS_PROFILE" = previous
                test "$AWS_ACCESS_KEY_ID" = previous-key
                grep -q '^configure set awsp_cache_valid --profile example-temp false$' "$test_dir/calls"
                assert_no_match '^configure set aws_session_token ' "$test_dir/calls"
                grep -q 'Invalid MFA' "$test_dir/output"
                ;;
        esac
        grep -q '^account list-regions --profile example-temp --no-cli-pager$' "$test_dir/calls"
    )
    echo "PASS: $scenario"
done
