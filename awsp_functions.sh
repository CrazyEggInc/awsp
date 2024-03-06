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
   if [ -z $1 ]; then  echo "Usage: awsp profilename"; return; fi
   exists="$(aws configure get aws_access_key_id --profile $1)"

   if [[ -n $exists ]]; then
       region="$(aws configure get region --profile $1)"
       role_arn="$(aws configure get role_arn --profile $1)"
       mfa_serial="$(aws configure get mfa_serial --profile $1)"

       if [[ -n $role_arn || -n $mfa_serial ]]; then
           if [[ -n $mfa_serial ]]; then
               echo "Please enter your MFA token for $mfa_serial:"
               read mfa_token
           fi

           source_profile="$(aws configure get source_profile --profile $1)"
           if [[ -n $source_profile ]]; then
               profile=$source_profile
           else
               profile=$1
           fi

           if [[ -n $role_arn ]]; then
              echo "Assuming role $role_arn using profile $profile"
              if [[ -n $mfa_serial ]]; then
                  JSON="$(aws sts assume-role --profile=$profile --role-arn $role_arn --role-session-name "$profile" --serial-number $mfa_serial --token-code $mfa_token)"
              else
                  JSON="$(aws sts assume-role --profile=$profile --role-arn $role_arn --role-session-name "$profile")"
              fi
           else
              JSON="$(aws sts get-session-token --profile=$profile --serial-number $mfa_serial --token-code $mfa_token)"
           fi

           aws_access_key_id="$(echo $JSON | jq -r '.Credentials.AccessKeyId')"
           aws_secret_access_key="$(echo $JSON | jq -r '.Credentials.SecretAccessKey')"
           aws_session_token="$(echo $JSON | jq -r '.Credentials.SessionToken')"
       else
           aws_access_key_id="$(aws configure get aws_access_key_id --profile $1)"
           aws_secret_access_key="$(aws configure get aws_secret_access_key --profile $1)"
           aws_session_token=""
       fi

       aws configure set region --profile "$1-temp" "$region"
       aws configure set aws_access_key_id --profile "$1-temp" "$aws_access_key_id"
       aws configure set aws_secret_access_key --profile "$1-temp" "$aws_secret_access_key"
       aws configure set aws_session_token --profile "$1-temp" "$aws_session_token"

       export AWS_DEFAULT_PROFILE="$1-temp"
	   export AWS_PROFILE="$1-temp"

       echo "Switched to AWS Profile: $1_temp";
       aws configure list
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

  _awsSwitchProfile $1
}
