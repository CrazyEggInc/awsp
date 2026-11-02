#!/bin/bash

# @source - https://github.com/antonbabenko/awsp

function _awsListProfile() {
    profileFileLocation=$(env | grep AWS_CONFIG_FILE | cut -d= -f2);
    if [ -z $profileFileLocation ]; then
        profileFileLocation=~/.aws/config
    fi
    while read line; do
        if [[ $line == "["* ]]; then echo "$line"; fi;
    done < $profileFileLocation;
};

# Switch profile by setting all env vars
function _awsSwitchProfile() {
   if [ -z "$1" ]; then echo "Usage: awsp profilename"; return 1; fi
   local exists region role_arn mfa_serial source_profile profile temp_profile
   local session_token mfa_token JSON aws_access_key_id aws_secret_access_key aws_session_token
   local source_mfa_serial source_role_arn profile_chain="${2:-}|"
   case "$profile_chain" in
       *"|$1|"*) echo "Circular source_profile reference: $1" >&2; return 1 ;;
   esac
   profile_chain="$profile_chain$1|"
   exists="$(aws configure get aws_access_key_id --profile "$1")"
   role_arn="$(aws configure get role_arn --profile "$1")"

   if [[ -n $exists || -n $role_arn ]]; then
       region="$(aws configure get region --profile "$1")"
       mfa_serial="$(aws configure get mfa_serial --profile "$1")"

       # profile vars
       source_profile="$(aws configure get source_profile --profile "$1")"
       if [[ -n $role_arn && -z $source_profile ]]; then
           echo "Role profile $1 requires source_profile" >&2
           return 1
       fi
       if [[ -n $source_profile ]]; then
           profile=$source_profile
       else
           profile=$1
       fi

       temp_profile="$1-temp"

       session_token="$(aws configure get aws_session_token --profile "$temp_profile")"

       if [[ -n $session_token ]]; then
           # there is an existing session, check if it has expired
           if aws sts get-caller-identity --profile "$temp_profile" >/dev/null 2>&1; then
               # credentials are still good, skip refreshing
               unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
               export AWS_DEFAULT_PROFILE="$temp_profile"
               export AWS_PROFILE="$temp_profile"
               echo "Switched to AWS Profile: $temp_profile\n";
               aws configure list --profile "$temp_profile"
               return
           fi
       fi

       # credentials need refresh
       if [[ -n $role_arn || -n $mfa_serial ]]; then
           if [[ -n $mfa_serial ]]; then
               echo "Credentials need refreshing, please enter your MFA token for $mfa_serial:"
               read -r mfa_token || return 1
           fi



           if [[ -n $role_arn ]]; then
              echo "Assuming role $role_arn using profile $profile"
              if [[ -n $mfa_serial ]]; then
                   JSON="$(aws sts assume-role --profile="$profile" --role-arn "$role_arn" --role-session-name "$source_profile" --serial-number "$mfa_serial" --token-code "$mfa_token")" || return 1
               else
                   source_mfa_serial="$(aws configure get mfa_serial --profile "$source_profile")"
                   source_role_arn="$(aws configure get role_arn --profile "$source_profile")"
                   if [[ -n $source_mfa_serial || -n $source_role_arn ]]; then
                       # Refresh the source without changing the caller's selected profile.
                       ( _awsSwitchProfile "$source_profile" "$profile_chain" ) || return 1
                       profile="$source_profile-temp"
                   fi
                   JSON="$(aws sts assume-role --profile="$profile" --role-arn "$role_arn" --role-session-name "$source_profile")" || return 1
               fi
           else
               JSON="$(aws sts get-session-token --profile="$profile" --serial-number "$mfa_serial" --token-code "$mfa_token")" || return 1
           fi

           if ! printf '%s' "$JSON" | jq -e '.Credentials | [.AccessKeyId, .SecretAccessKey, .SessionToken] | all(.[]; type == "string" and length > 0)' >/dev/null; then
               echo "AWS returned invalid credentials for $1" >&2
               return 1
           fi
           aws_access_key_id="$(printf '%s' "$JSON" | jq -r '.Credentials.AccessKeyId')"
           aws_secret_access_key="$(printf '%s' "$JSON" | jq -r '.Credentials.SecretAccessKey')"
           aws_session_token="$(printf '%s' "$JSON" | jq -r '.Credentials.SessionToken')"
       else
           aws_access_key_id="$exists"
           aws_secret_access_key="$(aws configure get aws_secret_access_key --profile "$1")"
           aws_session_token="$(aws configure get aws_session_token --profile "$1")"
           if [[ -z $aws_secret_access_key ]]; then
               echo "Profile $1 requires aws_secret_access_key" >&2
               return 1
           fi
       fi

       aws configure set region --profile "$temp_profile" "$region" || return 1
       aws configure set aws_access_key_id --profile "$temp_profile" "$aws_access_key_id" || return 1
       aws configure set aws_secret_access_key --profile "$temp_profile" "$aws_secret_access_key" || return 1
       aws configure set aws_session_token --profile "$temp_profile" "$aws_session_token" || return 1

       unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
       export AWS_DEFAULT_PROFILE="$temp_profile"
       export AWS_PROFILE="$temp_profile"

       echo "Switched to AWS Profile: $temp_profile\n";
       aws configure list --profile "$temp_profile"
   else
       echo "Profile $1 requires aws_access_key_id or role_arn" >&2
       return 1
   fi
}

function awsp() {
  if [[ -z "$1" ]]; then
    CURRENT_PROFILE="$AWS_PROFILE"

    if [ -z "$CURRENT_PROFILE" ]; then
        CURRENT_PROFILE=none
    fi

    echo "Current profile:\n[$CURRENT_PROFILE]\nAvailable profiles:\n$(_awsListProfile)"

    return
  fi

  _awsSwitchProfile "$1"
}

# localstack
function awsl() {
    AWS_ACCESS_KEY_ID=localstack AWS_SECRET_ACCESS_KEY=localstack AWS_DEFAULT_REGION=us-east-1 aws --endpoint-url=http://localhost:4566 "$@"
}
