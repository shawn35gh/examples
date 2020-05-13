#!/bin/bash

#########################################
# This script uses real Confluent Cloud resources.
# To avoid unexpected charges, carefully evaluate the cost of resources before launching the script and ensure all resources are destroyed after you are done running it.
#########################################


# Source library
source ../utils/helper.sh

check_jq \
  && print_pass "jq found"

check_ccloud_version 1.0.0 \
  && print_pass "ccloud version ok"

check_ccloud_logged_in \
  && print_pass "logged into ccloud CLI" 

print_pass "Prerequisite check pass"

wget -q -O docker-compose.yml https://raw.githubusercontent.com/confluentinc/cp-all-in-one/${CONFLUENT_RELEASE_TAG_OR_BRANCH}/cp-all-in-one-cloud/docker-compose.yml \
  && print_pass "retrieved docker-compose.yml from https://github.com/confluentinc/cp-all-in-one" \
  || exit_with_error -c $? -n "start-docker-cloud.sh" -m "could not obtain cp-all-in-one/docker-compose.yml" -l $(($LINENO -2))

printf "\n====== Confirm\n"
prompt_continue_cloud_demo || exit 1
read -p "Do you acknowledge this script creates a Confluent Cloud KSQL app (hourly charges may apply)? [y/n] " -n 1 -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit 1; fi
 
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
echo "Waiting up to $MAX_WAIT seconds for Confluent Cloud KSQL cluster to be UP"
retry $MAX_WAIT check_ccloud_ksql_endpoint_ready $KSQL_ENDPOINT || exit 1
print_pass "Confluent Cloud KSQL is UP"
ccloud_demo_preflight_check $CLOUD_KEY $CONFIG_FILE || exit 1
 
ccloud kafka topic create _confluent-monitoring \
  || exit_with_error -c $? -n "start-docker-cloud.sh" -m "could not create _confluent-monitoring topic" -l $(($LINENO -1))
ccloud kafka topic create pageviews \
  || exit_with_error -c $? -n "start-docker-cloud.sh" -m "could not create pageviews topic" -l $(($LINENO -1))
ccloud kafka topic create users \
  || exit_with_error -c $? -n "start-docker-cloud.sh" -m "could not create users topic" -l $(($LINENO -1))
print_pass "Pre-created topics\n"
 
printf "\nStarting local connect cluster to generate simulated data\n"
docker-compose up -d connect

# Verify Kafka Connect worker has started
MAX_WAIT=120
printf "\nWaiting up to $MAX_WAIT seconds for Kafka Connect to start\n"
retry $MAX_WAIT check_connect_up connect || exit 1
sleep 2 # give connect an exta moment to fully mature
print_pass "Kafka Connect has started\n"
 
# Configure datagen connectors
source ./connectors/submit_datagen_pageviews_config_cloud.sh
source ./connectors/submit_datagen_users_config_cloud.sh

printf "\nSleeping 30 seconds to give kafka-connect-datagen a chance to start producing messages\n"
sleep 30

# Run the KSQL queries
printf "\nSubmit KSQL queries\n"
ksqlAppId=$(ccloud ksql app list -o json | jq -r '.[].id')
ccloud ksql app configure-acls $ksqlAppId pageviews users PAGEVIEWS_FEMALE pageviews_female_like_89 PAGEVIEWS_REGIONS

properties='"ksql.streams.auto.offset.reset":"earliest","ksql.streams.cache.max.bytes.buffering":"0"'
while read ksqlCmd; do # from statements.sql
  response=$(curl -s -w "\n%{http_code}" -X POST $KSQL_ENDPOINT/ksql \
       -H "Content-Type: application/vnd.ksql.v1+json; charset=utf-8" \
       -u $KSQL_BASIC_AUTH_USER_INFO \
       -d @<(cat <<EOF
         {
           "ksql": "$ksqlCmd",
           "streamsProperties": {$properties}
         }
EOF
        )) || exit_with_error -n "start-docker-cloud.sh" -m "curl command failure, reference libcurl errors" -c $? -l $((LINENO -9));
  echo "$response" | {
    read body
    read code
    if [[ "$code" -gt 299 ]];
      then print_error "$(echo $body | jq .message)"
      else print_pass "$ksqlCmd"
    fi
  }
done < statements.sql
echo "-----------------------------------------------------------"

echo
echo "Local client configuration file written to $CONFIG_FILE"
echo
echo "Confluent Cloud KSQL is running and accruing charges. To destroy this demo run and verify ->"
echo "    ./stop-docker-cloud.sh $CONFIG_FILE"
echo
