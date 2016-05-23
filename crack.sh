#!/bin/bash

# set my shell to bash
sudo usermod -s /bin/bash root

#########
# setup
#########
cd /root
# make screen preserve scroll history
echo defscrollback 1000000 >> ~/.screenrc
# prerequisites
apt-get update -qq; apt-get install -qq -y p7zip-full inotify-tools python-pip libmozjs-24-bin
# install awscli to interact with the spot requests
pip install awscli
# use a sane json parser
ln -s /usr/bin/js24 /usr/bin/js
curl -L http://github.com/micha/jsawk/raw/master/jsawk > jsawk
chmod 755 jsawk && mv jsawk /usr/bin/
# install cuda hashcat
curl https://hashcat.net/files/cudaHashcat-2.01.7z -O
7za x cudaHashcat-2.01.7z > /dev/null
# install cpu hashcat
curl https://hashcat.net/files/hashcat-2.00.7z -O
7za x hashcat-2.00.7z > /dev/null
# install dropbox uploader
curl "https://raw.githubusercontent.com/andreafabrizi/Dropbox-Uploader/master/dropbox_uploader.sh" -o dropbox_uploader.sh
chmod +x dropbox_uploader.sh
cat <<EOH > /root/.dropbox_uploader
APPKEY=$DROPBOX_APPKEY
APPSECRET=$DROPBOX_APPSECRET
ACCESS_LEVEL=sandbox
OAUTH_ACCESS_TOKEN=$DROPBOX_OAUTH_ACCESS_TOKEN
OAUTH_ACCESS_TOKEN_SECRET=$DROPBOX_OAUTH_ACCESS_TOKEN_SECRET
EOH
# make hashcat output directory
mkdir results
# dump hashes to file
HASHES=(${HASHESTOCRACK})
printf "%s\n" "${HASHES[@]}" > ./hashfile
# pick up where another spot instance possibly left off
./dropbox_uploader.sh download pots/worker${WORKERID}of${WORKERS}.pot.txt results/cudaHashcat.pot
./dropbox_uploader.sh download restores/worker${WORKERID}of${WORKERS}.restore results/cudaHashcat.restore

# figure out who am i
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
export REGION=$(echo $AZ | sed -e 's:\([0-9][0-9]*\)[a-z]*:\1:')
SIRID=$(aws ec2 describe-instances --region $REGION --instance-id $INSTANCE_ID | grep SpotInstanceRequestId | tr -d '", ' | cut -f2 -d:)
#ACTIVE_REQUESTS=$(echo '{"SpotFleetRequestConfigs": [{"SpotFleetRequestId": "id1", "SpotFleetRequestState": "active"},{"SpotFleetRequestId": "sfr-4de98186-519b-42af-808d-4ae509baeab3", "SpotFleetRequestState": "active"}]}' | jsawk 'return this.SpotFleetRequestConfigs' | jsawk 'return (this.SpotFleetRequestState!="active") ?  null :this.SpotFleetRequestId' | jsawk -n 'out(this)')
ACTIVE_REQUESTS=$(aws ec2 describe-spot-fleet-requests --region $REGION | jsawk 'return this.SpotFleetRequestConfigs' | jsawk 'return (this.SpotFleetRequestState!="active") ?  null :this.SpotFleetRequestId' | jsawk -n 'out(this)')
ACTIVE_REQUESTS_AR=(${ACTIVE_REQUESTS})
for i in "${!ACTIVE_REQUESTS_AR[@]}"
do
    #ACTIVE_INSTANCES=$(echo '{"ActiveInstances":[{"InstanceId":"wefewfe"},{"InstanceId":"i-9970be04"}]}'| jsawk 'return this.ActiveInstances' | jsawk 'return this.InstanceId' | jsawk -n 'out(this)')
    ACTIVE_INSTANCES=$(aws ec2 describe-spot-fleet-instances --region $REGION --spot-fleet-request-id ${ACTIVE_REQUESTS_AR[i]//\"/}   | jsawk 'return this.ActiveInstances' | jsawk 'return this.InstanceId' | jsawk -n 'out(this)')
    ACTIVE_INSTANCES_AR=(${ACTIVE_INSTANCES})

    if [[ "${ACTIVE_INSTANCES_AR[@]}" =~ "${INSTANCE_ID}" ]]; then
        export SPOT_FLEET_REQUEST=${ACTIVE_REQUESTS_AR[i]//\"/}
        echo "Found our Spot Fleet Request ${ACTIVE_REQUESTS_AR[i]}.."
    fi
done
##################
# run Run RUN!
##################
# run it in screen so i can ssh and review it
screen -S gpucrack -dm bash -c '
    cd /root/results
    # need to let hashcat calculate the keyspace since its using some weird optimizations
    KEYSPACE=$(../cudaHashcat-2.01/cudaHashcat64.bin $HC_OPTIONS $HC_MASK --keyspace)
    WORDCOUNT=$(echo $KEYSPACE | sed -e "s/.*\s\([0-9]\+\)/\1/")
    # adding $WORKERS to $WORDCOUNT to effectively round it up
    WORKER_LOAD=$(($WORDCOUNT/$WORKERS))
    WORKER_LOAD_ROUNDED_UP=$((($WORDCOUNT+$WORKERS)/$WORKERS))
    WORKER_START_OFFSET=$(($WORKERID*$WORKER_LOAD))
    if [ $WORKERS -eq 1 ]
    then
      export WORKER_LOAD_FLAGS=
    else
      export WORKER_LOAD_FLAGS="-s $WORKER_START_OFFSET -l $WORKER_LOAD_ROUNDED_UP"
    fi

    # set file monitoring and upload in bg
    (inotifywait -m /root/results --format "%f %e" -e close_write -e moved_to -e modify |
        while read file event; do
            if [[ "$event" == "MODIFY" && "$file" == "cudaHashcat.pot" ]];
            then
                echo "Potfile modified. Checking if there s content."
                if [[ $(cat /root/results/cudaHashcat.pot) == "" ]];
                then
                    echo "Pot is empty, skip uploading"
                else
                    echo "Pot has content. Uploading it to pots/worker${WORKERID}of${WORKERS}.pot.txt"
                    /root/dropbox_uploader.sh upload /root/results/cudaHashcat.pot pots/worker${WORKERID}of${WORKERS}.pot.txt
                fi
            fi
            if [[ "$event" == "CLOSE_WRITE,CLOSE" && "$file" == "cudaHashcat.pot" ]];
            then
                echo "Potfile written. Uploading it to pots/worker${WORKERID}of${WORKERS}.pot.txt"
                /root/dropbox_uploader.sh upload /root/results/cudaHashcat.pot pots/worker${WORKERID}of${WORKERS}.pot.txt
            fi
            if [[ "$event" == "MOVED_TO" && "$file" == "cudaHashcat.restore" ]];
            then
                echo "Restore file written. Uploading it to restores/worker${WORKERID}of${WORKERS}.restore"
                /root/dropbox_uploader.sh upload /root/results/cudaHashcat.restore restores/worker${WORKERID}of${WORKERS}.restore
            fi
        done)&

    # restore or launch a hash cracker. when finished shutdown after a minute
    if [ ! -f ./cudaHashcat.restore ];
    then
        echo "Didnt find restore file. Starting from scratch.."
        echo "../cudaHashcat-2.01/cudaHashcat64.bin $HC_OPTIONS $WORKER_LOAD_FLAGS ../hashfile $HC_MASK"
        ../cudaHashcat-2.01/cudaHashcat64.bin $HC_OPTIONS $WORKER_LOAD_FLAGS ../hashfile $HC_MASK
        sleep 30
        echo "aws ec2 cancel-spot-fleet-requests --terminate-instances --region $REGION --spot-fleet-request-ids $SPOT_FLEET_REQUEST"
        aws ec2 cancel-spot-fleet-requests --terminate-instances --region $REGION --spot-fleet-request-ids $SPOT_FLEET_REQUEST
        sleep 30
    else
        echo "Found restore file. Resuming.."
        echo "../cudaHashcat-2.01/cudaHashcat64.bin --restore"
        ../cudaHashcat-2.01/cudaHashcat64.bin --restore
        sleep 30
        echo "aws ec2 cancel-spot-fleet-requests --terminate-instances --region $REGION --spot-fleet-request-ids $SPOT_FLEET_REQUEST"
        aws ec2 cancel-spot-fleet-requests --terminate-instances --region $REGION --spot-fleet-request-ids $SPOT_FLEET_REQUEST
        sleep 30
    fi
'
