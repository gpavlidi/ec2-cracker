#!/bin/bash

# load up AWS and Dropbox api keys
source ./keys.sh

###############
# Configuration
###############
REGION=us-east-1 #us-east-1 us-west-1 us-west-2
SPOTPRICE=0.91 #0.25 for g2.2xlarge, 0.80 for g2.8xlarge
AMI=ami-1117a87a
INSTANCETYPE=g2.8xlarge #g2.2xlarge g2.8xlarge
KEYNAME=gpu-cracker
PERSISTENCE=one-time #one-time persistent
WORKERS=10
HASHESTOCRACK='21232f297a57a5a743894a0e4a801fc3' #'21232f297a57a5a743894a0e4a801fc3' #space separated
HC_OPTIONS='-a 3 -m 0 -1 ?d?l?u?s' # ?d?l?u?s BruteForce attack, md5 hash, -i for incremental needs 1 worker only
HC_MASK='?1?1?1?1?1?1?1?1' # https://hashcat.net/wiki/doku.php?id=oclhashcat#dw__toc
SCRIPT_URL="https://www.dropbox.com/sh/9txlq9efdqgx1es/AABCQVSxHJg7sIj5tYnJuNTEa/crack.sh\?dl\=1"
ALLOCATION_STRATEGY=lowestPrice #diversified lowestPrice
TERMINATE_WITH_EXPIRATION=true
IAM_INSTANCE_ROLE="gpu-cracker-worker" #default spot fleet role
IAM_FLEET_ROLE="arn:aws:iam::705842015716:role/aws-ec2-spot-fleet-role" #default spot fleet role
VALID_FROM=$(date +%s) #date +%FT%T%Z date +%s acceptable timestamp formats: http://docs.aws.amazon.com/cli/latest/userguide/cli-using-param.html
VALID_UNTIL=$VALID_FROM


###############
# /Configuration
###############

# create instance IAM profiles so the instance can interact with the spot request
aws iam create-role --role-name $IAM_INSTANCE_ROLE --assume-role-policy-document file://./spot-worker-trust-role.json
aws iam put-role-policy --role-name $IAM_INSTANCE_ROLE --policy-name SpotAccessPolicy --policy-document file://./spot-worker-policy.json
aws iam create-instance-profile --instance-profile-name $IAM_INSTANCE_ROLE
aws iam add-role-to-instance-profile --instance-profile-name $IAM_INSTANCE_ROLE --role-name $IAM_INSTANCE_ROLE

WORKERID=0
while [  $WORKERID -lt $WORKERS ]; do
    USERDATAB64=$( cat <<EOH | base64
#!/bin/bash
# how many ec2 instances
export WORKERS=$WORKERS
export WORKERID=$WORKERID
export HASHESTOCRACK='$HASHESTOCRACK'
export HASHES=(${HASHESTOCRACK})
export HC_OPTIONS='$HC_OPTIONS' 
export HC_MASK='$HC_MASK'
# dropbox access
export DROPBOX_APPKEY=$DROPBOX_APPKEY
export DROPBOX_APPSECRET=$DROPBOX_APPSECRET
export DROPBOX_OAUTH_ACCESS_TOKEN=$DROPBOX_OAUTH_ACCESS_TOKEN
export DROPBOX_OAUTH_ACCESS_TOKEN_SECRET=$DROPBOX_OAUTH_ACCESS_TOKEN_SECRET
curl -L $SCRIPT_URL | bash -x
EOH)

    # dont use request-spot-instances anymore. request-spot-fleet gets better prices

    #requestid=$(aws ec2 request-spot-instances --type "$PERSISTENCE" --region $REGION --spot-price $SPOTPRICE --launch-specification "{
    #	\"ImageId\":\"$AMI\",
    #	\"InstanceType\":\"$INSTANCETYPE\",
    #	\"KeyName\":\"$KEYNAME\",
    #	\"UserData\":\"$USERDATAB64\",
    #	\"BlockDeviceMappings\":[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"DeleteOnTermination\":true}}]
    #	}" | grep "SpotInstanceRequestId" | tr -d '", ' | cut -f2 -d:)

    #aws ec2 create-tags --region $REGION --resources $requestid --tags \
    #    Key=Hash,Value="$HASHESTOCRACK" \
    #    Key=Workers,Value="$WORKERS" \
    #    Key=WorkerId,Value="$WORKERID" \
    #    Key=Mask,Value="$HC_MASK" \
    #    Key=Flags,Value="$HC_OPTIONS"

    #cant get the below 2 to work
    #\"ValidFrom\": \"$VALID_FROM\",
    # \"ValidUntil\": \"$VALID_UNTIL\",

    requestid=$(aws ec2 request-spot-fleet --region $REGION --spot-fleet-request-config "{
        \"IamFleetRole\": \"$IAM_FLEET_ROLE\",
        \"AllocationStrategy\": \"$ALLOCATION_STRATEGY\",
        \"TargetCapacity\": 1,
        \"ValidFrom\": \"$VALID_FROM\",
        \"SpotPrice\": \"$SPOTPRICE\",
        \"TerminateInstancesWithExpiration\": $TERMINATE_WITH_EXPIRATION,
        \"LaunchSpecifications\":[{
        \"ImageId\":\"$AMI\",
        \"InstanceType\":\"$INSTANCETYPE\",
        \"KeyName\":\"$KEYNAME\",
        \"UserData\":\"$USERDATAB64\",
        \"BlockDeviceMappings\":[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"DeleteOnTermination\":true}}],
        \"IamInstanceProfile\":{\"Name\":\"$IAM_INSTANCE_ROLE\"}
        }]
        }" | grep "SpotFleetRequestId" | tr -d '", ' | cut -f2 -d: | sed 's/}//g')

    let WORKERID=WORKERID+1 
done
