# Distributed EC2 cracker
bash black magic that cracks hashes using multiple EC2 spot instances . Uses cudahashcat.

### Why
Bruteforcing/dictionary attacks can take a long time even on a GPU instance. These kind of attacks are trivial to parallelize by increasing the number of the EC2 instances (and your AWS bill). To bring the cost down this cracker is using aws [spot instances](https://aws.amazon.com/ec2/spot/). The scripts persist data using Dropbox and not S3 so that the instances can run on any region/availability zone.

###Discaimer
This is quick proof-of-concept quality code. Use it at your own risk, I hold no responsibility for inflated AWS bills ;-).


### Use
- Replace keys in the keys.sh.template and rename the file to keys.sh
- Edit launch.sh with all the necessary variables like how many workers, what hash to crack, the kind of hashcat attack etc
- ./launch.sh