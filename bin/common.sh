#!/bin/sh

set -eu

[ ! -e /tmp/build/* ] || cd /tmp/build/*

REM () {
  /bin/echo $( date -u +"%Y-%m-%dT%H:%M:%SZ" ) "$@"
}

fatal () {
  echo "FATAL: $1" >&2
  exit 1
}

repipe () {
  exec 3>&1
  exec 1>&2
  cat > /tmp/stdin
}

load_source () {
  eval $( jq -r '{
    "source_repository": .source.repository,
    "source_access_token": .source.access_token,
    "source_branch": ( .source.branch // "master" ),
    "source_context": ( .source.context // "default" ),
    "source_endpoint": ( .source.endpoint // "https://api.github.com" ),
    "skip_ssl_verification": ( .source.skip_ssl_verification // "false" )
    } | to_entries[] | .key + "=" + @sh "\(.value)"
  ' < /tmp/stdin )

  source_endpoint=$( echo "$source_endpoint" | sed 's#/$##' )
}

buildtpl () {
  envsubst=$( which envsubst )
  env -i \
    BUILD_ID="${BUILD_ID:-}" \
    BUILD_NAME="${BUILD_NAME:-}" \
    BUILD_JOB_NAME="${BUILD_JOB_NAME:-}" \
    BUILD_PIPELINE_NAME="${BUILD_PIPELINE_NAME:-}" \
    ATC_EXTERNAL_URL="${ATC_EXTERNAL_URL:-}" \
    $envsubst
}

curlgh () {
  if $skip_ssl_verification; then
    skip_verify_arg="-k"
  else
    skip_verify_arg=""
  fi

  REMAINING_TRIES="${retry_count:-5}"

  while true; do
    # Output the response headers and body to two separate files so that we can easily work on them both
    curl $skip_verify_arg -s -D/tmp/responseheaders -H "Authorization: token $source_access_token" $@ > /tmp/rawresponse

    http_status=$(head -n1 /tmp/responseheaders | sed 's|HTTP.* \([0-9]*\) .*|\1|')
    # If HTTP status is OK (2XX), break the retry loop now to carry on (skip all error handling & retries)
    if [[ "$http_status" =~ 2[0-9]{2} ]]; then
      break;
    fi

    if [ "$http_status" -ge 400 ]; then
      if [ "$http_status" -le 499 ]; then # 400-499 range
        if [ $(grep -i 'rate-limit' /tmp/rawresponse || echo '0') -ge 1 ]; then
          now=$(date "+%s")
          ratelimit_reset=$(cat /tmp/responseheaders | sed -n 's|X-RateLimit-Reset: \([0-9]*\)|\1|p')

          sleep_duration="$((ratelimit_reset - now))"
          # If our system clock is in advance to GitHub's the result of sleep_duration might be a negative number
          if [[ "$sleep_duration" -lt 1 ]]; then
            sleep_duration="1"
          fi
          echo "Limited by the API rate limit. Script will retry at $( date -d@$((now + sleep_duration)) )" >&2
        else
          fatal "Authentication error against the GitHub API"
        fi
      else # 500+ range
        echo "Unexpected HTTP $(echo $http_status) when querying the GitHub API" >&2
        sleep_duration="${retry_delay:-3}"
      fi
    else # Other status code that's not 200 OK, nor in the 400+ range
      fatal "Unexpected HTTP status code when querying the GitHub API: $(echo $http_status)"
    fi


    # Exit if we have reach the maximum number of attemps, or sleep and retry otherwise
    if [ "$REMAINING_TRIES" -le 0 ]; then
      fatal "Maximum number of attempts reached while trying to query the GitHub API"
    fi

    echo "Will retry in $sleep_duration seconds" >&2

    REMAINING_TRIES=$(($REMAINING_TRIES - 1))

    sleep $sleep_duration

  done

  cat /tmp/rawresponse
}
