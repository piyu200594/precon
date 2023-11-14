#!/bin/bash
echo "Collecting information from AWS..."

# 1. How many accounts are there in the AWS organization?
echo "1. Number of accounts in the AWS organization:"
aws organizations list-accounts --query 'Accounts[*].Id' --output text | wc -w

# 2. Does any account have a bill above $50,000 in the last month?
echo "2. Checking if any account has a bill above 50,000 in the last month:"
# Set the start and end dates for the last month
start_date=$(date -d "-1 month -$(($(date +%d)-1)) days" +%Y-%m-%d)
end_date=$(date -d "-$(date +%d) days" +%Y-%m-%d)

# Use AWS Cost Explorer to get costs for each account in the organization
accounts_over_50k=$(aws ce get-cost-and-usage --time-period Start=$start_date,End=$end_date \
                                              --granularity MONTHLY \
                                              --metrics "UnblendedCost" \
                                              --group-by Type=DIMENSION,Key=LINKED_ACCOUNT \
                                              --output json | jq -r '.ResultsByTime[].Groups[] | select((.Metrics.UnblendedCost.Amount | tonumber) > 50000) | .Keys[]')

if [ -z "$accounts_over_50k" ]; then
    echo "No account above 50K monthly."
else
    echo "Accounts with a bill over 50,000 in the last month: $accounts_over_50k"
fi

# 3. Does the customer have an AWS Org?
echo "3. Checking for AWS Org:"
aws organizations describe-organization --query 'Organization' &> /dev/null && echo "Yes" || echo "No"

# 4. Check for AWS Identity Center
echo "4. Checking for AWS Identity Center:"
aws sso-admin list-instances &> /dev/null && echo "Yes" || echo "No"

# 5. List all the AWS Org services that are enabled
echo "5. List of enabled AWS Org services:"
aws organizations list-aws-service-access-for-organization --query 'EnabledServicePrincipals[*].ServicePrincipal' --output table

# 6. Check for AWS SCPs
echo "6. Checking for AWS SCPs:"
aws organizations list-policies --filter "SERVICE_CONTROL_POLICY" --query 'Policies' --output table

# 7. Check for workloads in the master payer account
echo "7. Checking for workloads in the master payer account:"
if aws ec2 describe-instances --query 'Reservations[*].Instances[*].InstanceId' --output text | grep -q 'i-'; then
    echo "Yes, there are workloads running in the root account."
elif aws rds describe-db-instances --query 'DBInstances[*].DBInstanceIdentifier' --output text | grep -q 'db-'; then
    echo "Yes, there are workloads running in the root account."
elif aws eks list-clusters --query 'clusters' --output text | grep -q '.'; then
    echo "Yes, there are workloads running in the root account."
elif aws ecs list-clusters --query 'clusterArns' --output text | grep -q 'cluster'; then
    echo "Yes, there are workloads running in the root account."
elif aws apigateway get-rest-apis --query 'items[*].id' --output text | grep -q '.*'; then
    echo "Yes, there are workloads running in the root account."
else
    echo "No workloads detected in the root account."
fi

# 8. What level of AWS Support does the account have?
echo "8. AWS Support Plan for the account:"

# Check for AWS Support Plan (Basic, Developer, Business, or Enterprise)
echo "Determining the AWS Support Plan of the account:"
if aws support describe-trusted-advisor-checks --language en &> /dev/null; then
    echo "The account is likely on the Business or Enterprise support plan."
else
    error_message=$(aws support describe-trusted-advisor-checks --language en 2>&1)
    if [[ "$error_message" == *"SubscriptionRequiredException"* ]]; then
        echo "The account is likely on the Basic or Developer support plan."
    else
        echo "Unable to determine the support plan due to an unexpected error:"
        echo "$error_message"
    fi
fi

# 9. Check for AWS Marketplace listings
echo "9. Checking for AWS Marketplace listings:"
# Set the start and end dates for the billing period you want to check
start_date=$(date -d "-1 month -$(($(date +%d)-1)) days" +%Y-%m-%d)
end_date=$(date -d "-$(date +%d) days" +%Y-%m-%d)

# Create filter JSON
filter_json='{
    "Dimensions": {
        "Key": "RECORD_TYPE",
        "Values": ["Marketplace"]
    }
}'

# Save filter to a temporary file
filter_file=$(mktemp)
echo "$filter_json" > "$filter_file"

# Use AWS Cost Explorer to check for AWS Marketplace charges
result=$(aws ce get-cost-and-usage --time-period Start=$start_date,End=$end_date \
                                   --granularity MONTHLY \
                                   --metrics "UnblendedCost" \
                                   --filter file://$filter_file \
                                   --output json)

# Remove the temporary filter file
rm "$filter_file"

# Check if any marketplace listings are found
if echo "$result" | jq -e '.ResultsByTime[].Groups[] | select(.Metrics.UnblendedCost.Amount | tonumber > 0)' &> /dev/null; then
    echo "Active AWS Marketplace listing(s) found."
else
    echo "No marketplace listing found."
fi

# 10. Check for AWS credits

# 11. Check for cost allocation tags
echo "10. Checking for cost allocation tags:"
cost_allocation_tags=$(aws ce list-cost-allocation-tags --query 'CostAllocationTags[*].Key' --output json)

if [ -z "$cost_allocation_tags" ] || [ "$cost_allocation_tags" == "[]" ]; then
    echo "Cost allocation tags are not enabled or no tags are set."
else
    echo "Cost allocation tags are enabled."
fi

echo "Information gathering complete."

