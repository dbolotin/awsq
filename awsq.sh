#!/bin/bash

scriptDir=""

os=`uname`

# OS specific part
case $os in
    Darwin)
        scriptDir=$(cd "$(dirname "$0")"; pwd)
    ;;
    Linux)
        scriptDir="$(dirname "$(readlink -f "$0")")"
    ;;
    *)
       echo "Unknown OS."
       exit 1
    ;;
esac

q=${scriptDir}/$(basename $0)

type jq >/dev/null 2>&1 || { echo >&2 "Please install \"jq\". Try \"brew install jq\" or \"apt-get install jq\"." ; exit 1; }
type aws >/dev/null 2>&1 || { echo >&2 "Please install \"aws cli\". Try \"pip install awscli\"." ; exit 1; }

queue=''
shutdown=false
completeOnError=false
region='us-east-1'
emptyQueueTimeout=10

cmd=""

# Additional parameters
aargs=()

while [[ $# > 0 ]]
do
    key="$1"
    shift
    case $key in
        --queue)
            queue="${1}"
            shift
        ;;
        --region)
            region='${1}'
            shift
        ;;
        --shutdown-after-work)
            shutdown=true
        ;;
        --complete-on-error)
            shutdown=true
        ;;
        --emptyTimeout)
            emptyQueueTimeout=${1}
            shift
        ;;
        *)
            if [ -z "$cmd" ]
            then
                cmd="$key"
            else
                aargs+=($key)
            fi
        ;;
esac
done

# In 30-second ticks
emptyQueueTimeout=$((emptyQueueTimeout * 2))

case $cmd in
    worker|push|worker-screen|spawn-workers)
        if [ -z "${queue}" ]
        then
            echo "Queue name not specified."
            exit 1
        fi
        ;;
esac

if [ -z "${cmd}" ]
then
    echo "Action not specified."
    exit 1
fi


queueURL=""
function ensure_queue() {
    resp=$(aws sqs create-queue --queue-name ${queue} --region ${region})
    if [[ "$?" != "0" ]]
    then
        echo "Error creating queue."
        exit 1
    fi
    queueURL=$(echo ${resp} | jq -r '.QueueUrl')
}

function push {
    msg="${1}"

    msgArray=( $msg )

    if ( [[ "${msgArray[0]}" != "s3://"* ]] && [[ "${msgArray[0]}" != "http://"* ]] && [[ "${msgArray[0]}" != "https://"* ]] )
    then 
        echo "Error in task: ${msg}"
        echo "First field of the message must be correct s3 address of task zip file. Found: ${msgArray[0]}"
        echo "Like this: ./q.sh push --queue my-queue-name s3://mybucket/path/to/task.zip ./go.sh agr1 arg2 ..."
        exit 1
    fi

    resp=$(aws sqs send-message --queue-url ${queueURL} --region ${region} --message-body "Q $msg")

    if [[ "$?" != "0" ]]
    then
        echo "Error pushing task."
        exit 1
    fi

    msgId=$(echo ${resp} | jq -r '.MessageId')

    echo "Task successfully submitted. Id=${msgId}"
}

qworkerScreenPrefix="qworker_"

case $cmd in
    spawn-workers)
        workingDirectoryPrefix=${aargs[0]}
        count=${aargs[1]}
        for i in $(seq 1 ${count})
        do
            ${q} worker-screen --queue ${queue} "${workingDirectoryPrefix}${i}"
        done

        if [[ $shutdown == true ]]; then
            ${q} wait-shutdown-screen
        fi

        ;;
        
    wait-shutdown-screen)
        screen -d -m -S toShutdown ${q} wait-shutdown
        ;;

    wait-shutdown)
        while true
        do
            if screen -list | grep ${qworkerScreenPrefix} > /dev/null
            then
                echo "running"
            else
                break;
            fi
            sleep 100
        done

        sudo shutdown -h now
        ;;

    worker-screen)
        workingDirectory=${aargs[0]}
        if [ -z "${workingDirectory}" ]
        then
            echo "Please specify working directory."
            exit 1
        fi
        workingDirectoryName=$(basename ${workingDirectory})
        screenName="${qworkerScreenPrefix}${workingDirectoryName}"
        screen -d -m -S ${screenName} ${q} worker --queue ${queue} ${workingDirectory}
        ;;

    # Arguments: ./q.sh working_folder
    worker)
        ensure_queue

        # To stop underlying process with current if Ctrl-C is pressed
        trap "trap - SIGTERM && kill -- -$$ && echo ''" SIGINT SIGTERM EXIT

        workingDirectory=${aargs[0]}
        if [ -z "${workingDirectory}" ]
        then
            echo "Please specify working directory."
            exit 1
        fi

        # Timeout counter
        attempt=0
        while true;
        do 
            content="$(aws sqs receive-message --region ${region} --queue-url ${queueURL} | tr '\n' ' ')"
            if [ -z "$content" ]
            then
                attempt=$((attempt + 1))
                if [ $attempt -gt $emptyQueueTimeout ]
                then
                    exit 0
                fi
                echo "Nothing in queue. (#${attempt})"
                sleep 30
                continue
            fi
            attempt=0
            body="$(echo ${content} | jq -r '.Messages[0].Body')"

            body=$(echo ${body} | sed 's/^Q //')

            echo ${body}

            # Converting input message to array
            bodyArray=( $body )
            receiptHandle="$(echo ${content} | jq -r '.Messages[0].ReceiptHandle')"

            execLine="$q worker-task ${workingDirectory} ${body}"

            ${execLine[@]} &

            pid="$!"
            while true
            do
                if kill -s 0 $pid > /dev/null 2>&1
                then
                    aws sqs change-message-visibility --region ${region} --queue-url ${queueURL} --receipt-handle "${receiptHandle}" --visibility-timeout 120
                    echo "Prolonging visibility-timeout."
                    sleep 60
                else
                    if wait $pid
                    then
                        echo "Process complete successfully. Deleting item from queue."
                        aws sqs delete-message --region ${region} --queue-url ${queueURL} --receipt-handle "${receiptHandle}"
                    else
                        echo "Process complete with error."
                        if [[ ${completeOnError} == true ]]
                        then
                            aws sqs delete-message --region ${region} --queue-url ${queueURL} --receipt-handle "${receiptHandle}"
                        fi
                    fi
                    
                    break
                fi
            done
        done
        ;;

    # Don't invoke this action. Internally used in worker action.
    # Arguments: working_folder s3://mybucket/mytask.zip cmd [arg0 [arg1 ...]]
    worker-task)
        workingDirectory=${aargs[0]}
        taskFile=${aargs[1]}
        cmd=${aargs[2]}
        args="${aargs[@]:3}"

        rm -rf ${workingDirectory}
        mkdir -p ${workingDirectory}

        fileName=$(basename ${taskFile})

        cd ${workingDirectory}
        if [[ "${taskFile}" == "s3://"* ]]; then
            aws s3 cp ${taskFile} ${fileName}
        elif [[ "${taskFile}" == "http://"* ]] || [[ "${taskFile}" == "https://"* ]]; then
            curl ${taskFile} > ${fileName}
        fi

        if [[ ${fileName} == *".zip" ]]; then
            unzip ${fileName}
            rm ${fileName}
        fi

        if [[ "${cmd}" == "./"* ]];
        then
            chmod +x ${cmd}
        fi

        $cmd ${args[@]}

        ;;
    push)
        if [ -z "${aargs[0]}" ]
        then
            echo "Message not specified."
            exit 1
        fi

        ensure_queue

        if [ "${aargs[0]}" == "-" ]
        then
            while read line;
            do
                push "$line"
            done
        else
            push "$(echo "${aargs[@]}")"
        fi
        ;;
    *)
        echo "Unknown command ${cmd}."
        exit 1
        ;;
esac

