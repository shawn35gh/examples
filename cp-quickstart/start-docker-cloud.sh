#!/bin/bash

#########################################
# This script uses real Confluent Cloud resources.
# To avoid unexpected charges, carefully evaluate the cost of resources before launching the script and ensure all resources are destroyed after you are done running it.
#########################################

# Source library
source ../utils/helper.sh

NAME=`basename "$0"`

check_jq \
  && print_pass "jq found"

check_ccloud_version 1.0.0 \
  && print_pass "ccloud version ok"

check_ccloud_logged_in \
  && print_pass "logged into ccloud CLI" 

print_pass "Prerequisite check pass"

wget -q -O docker-compose.yml https://raw.githubusercontent.com/confluentinc/cp-all-in-one/${CONFLUENT_RELEASE_TAG_OR_BRANCH}/cp-all-in-one-cloud/docker-compose.yml \
  && print_pass "retrieved docker-compose.yml from https://github.com/confluentinc/cp-all-in-one" \
  || exit_with_error -c $? -n "$NAME" -m "could not obtain cp-all-in-one/docker-compose.yml" -l $(($LINENO -2))

[[ -z "$AUTO" ]] && {
  printf "\n====== Confirm\n"
  prompt_continue_cloud_demo || exit 1
  read -p "Do you acknowledge this script creates a Confluent Cloud KSQL app (hourly charges may apply)? [y/n] " -n 1 -r
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit 1; fi
} 

printf "\nFor your reference the important commands that are executed will appear in "; print_code "code format"

printf "\n\n====== Creating new Confluent Cloud stack\n"
cloud_create_demo_stack true

SERVICE_ACCOUNT_ID=$(ccloud kafka cluster list -o json | jq -r '.[0].name' | awk -F'-' '{print $4;}')
CONFIG_FILE=stack-configs/java-service-account-$SERVICE_ACCOUNT_ID.config
export CONFIG_FILE=$CONFIG_FILE
check_ccloud_config $CONFIG_FILE || exit 1
../ccloud/ccloud-generate-cp-configs.sh $CONFIG_FILE
DELTA_CONFIGS_DIR=delta_configs
source $DELTA_CONFIGS_DIR/env.delta

# Pre-flight check of Confluent Cloud credentials specified in $CONFIG_FILE
MAX_WAIT=720
print_process_start "Waiting up to $MAX_WAIT seconds for Confluent Cloud KSQL cluster to be UP"
retry $MAX_WAIT check_ccloud_ksql_endpoint_ready $KSQL_ENDPOINT || exit 1
print_pass "Confluent Cloud KSQL is UP"
ccloud_demo_preflight_check $CLOUD_KEY $CONFIG_FILE || exit 1

print_process_start "Pre-creating topics"

CMD="ccloud kafka topic create _confluent-monitoring"
$CMD \
  && print_code_pass -c "$CMD" \
  || exit_with_error -c $? -n "$NAME" -m "$CMD" -l $(($LINENO -3))

CMD="ccloud kafka topic create pageviews"
$CMD \
  && print_code_pass -c "$CMD" \
  || exit_with_error -c $? -n "$NAME" -m "$CMD" -l $(($LINENO -3)) 

CMD="ccloud kafka topic create pageviews_regions"
$CMD  \
  && print_code_pass -c "$CMD" \
  || exit_with_error -c $? -n "$NAME" -m "$CMD" -l $(($LINENO -3))

CMD="ccloud kafka topic create users"
$CMD \
  && print_code_pass -c "$CMD" \
  || exit_with_error -c $? -n "$NAME" -m "$CMD" -l $(($LINENO -3))

CMD="ccloud kafka topic create accomplished_female_readers"
$CMD \
  && print_code_pass -c "$CMD" \
  || exit_with_error -c $? -n "$NAME" -m "$CMD" -l $(($LINENO -3))

print_pass "Pre-created topics"
 
printf "\nStarting local connect cluster in Docker to generate simulated data\n"
CMD="docker-compose up -d connect"
$CMD \
  && print_code_pass -c "$CMD" \
  || exit_with_error -c $? -n "$NAME" -m "$CMD" -l $(($LINENO -2))

# Verify Kafka Connect worker has started
MAX_WAIT=120
printf "\n"
print_process_start "Waiting up to $MAX_WAIT seconds for Kafka Connect to start"
retry $MAX_WAIT check_connect_up connect || exit 1
sleep 2 # give connect an exta moment to fully mature
print_pass "Kafka Connect has started"
 
# Configure datagen connectors
source ./connectors/submit_datagen_pageviews_config_cloud.sh >/dev/null 2>&1
source ./connectors/submit_datagen_users_config_cloud.sh >/dev/null 2>&1

printf "\nSleeping 30 seconds to give kafka-connect-datagen a chance to start producing messages\n"
sleep 30

printf "\nSetting up ksqlDB\n"

printf "Obtaining the ksqlDB App Id\n"
CMD="ccloud ksql app list -o json | jq -r '.[].id'"
ksqlAppId=$(eval $CMD) \
  && print_code_pass -c "$CMD" -m "$ksqlAppId" \
  || exit_with_error -c $? -n "$NAME" -m "$CMD" -l $(($LINENO -3))

printf "\nConfiguring ksqlDB ACLs\n"
CMD="ccloud ksql app configure-acls $ksqlAppId pageviews users pageviews_regions accomplished_female_readers PAGEVIEWS_FEMALE pageviews_female_like_89"
$CMD \
  && print_code_pass -c "$CMD" \
  || exit_with_error -c $? -n "$NAME" -m "$CMD" -l $(($LINENO -3))

sleep 60
printf "\nSubmitting KSQL queries\n\n"

while read ksqlCmd; do # from docker-cloud-statements.sql

echo -e "\n$ksqlCmd\n"
  response=$(curl -X POST $KSQL_ENDPOINT/ksql \
       -H "Content-Type: application/vnd.ksql.v1+json; charset=utf-8" \
       -u $KSQL_BASIC_AUTH_USER_INFO \
       --silent \
       -d @<(cat <<EOF
{
  "ksql": "$ksqlCmd",
  "streamsProperties": {$properties}
}
EOF
))
  echo $response
  if [[ ! "$response" =~ "SUCCESS" ]]; then
    echo -e "\nWARN: KSQL command '$ksqlCmd' did not include \"SUCCESS\" in the response. Please troubleshoot."
  fi

#CMD="curl -s -w \"\n%{http_code}\" -X POST $KSQL_ENDPOINT/ksql -H \"Content-Type: application/vnd.ksql.v1+json; charset=utf-8\" -u $KSQL_BASIC_AUTH_USER_INFO -d @"<
#   response=$(eval $CMD) \
#     && print_code_pass -c "$CMD" \
#     || exit_with_error -c $? -n "$NAME" -m "curl command failure, reference libcurl errors" -l $((LINENO -2));
# 
#   BODY="{\\\"ksql\\\":\\\"$ksqlCmd\\\",\\\"streamsProperties\\\":{\\\"ksql.streams.auto.offset.reset\\\":\\\"earliest\\\",\\\"ksql.streams.cache.max.bytes.buffering\\\":\\\"0\\\"}}"
#   printf "\ncurl command succeeed\nhere is the submitted KSQL command and REST API response:\n\n"
#   echo "$response" | {
#     read body
#     read code
#     if [[ "$code" -gt 299 ]];
#       then print_code_error -c "$ksqlCmd" -m "$(echo "$body" | jq .message)"
#       else print_code_pass  -c "$ksqlCmd" -m "$(echo "$body" | jq -r .[].commandStatus.message)"
#     fi
#   }
#   printf "\n"
#   sleep 5
done < docker-cloud-statements.sql
echo "-----------------------------------------------------------"

echo
echo "Local client configuration file written to $CONFIG_FILE"
echo
echo "Confluent Cloud KSQL is running and accruing charges. To destroy this demo run and verify ->"
echo "    ./stop-docker-cloud.sh $CONFIG_FILE"
echo
