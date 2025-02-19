#!/bin/bash
# Copyright (C) 2025 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

set -x

WORKPATH=$PWD
LOG_PATH="$WORKPATH/tests"
ip_address=$(hostname -I | awk '{print $1}')
finetuning_service_port=8015
ray_port=8265

function build_sqft_docker_images() {
    cd $WORKPATH
    echo $(pwd)
    docker build --no-cache -t opea/sqft:comps --build-arg https_proxy=$https_proxy --build-arg http_proxy=$http_proxy --build-arg HF_TOKEN=$HF_TOKEN -f comps/sqft/Dockerfile .
    if [ $? -ne 0 ]; then
        echo "opea/sqft built fail"
        exit 1
    else
        echo "opea/sqft built successful"
    fi
}

function start_service() {
    export no_proxy="localhost,127.0.0.1,"${ip_address}
    docker run -d --name="test-comps-sqft-server" -p $finetuning_service_port:$finetuning_service_port -p $ray_port:$ray_port --runtime=runc --ipc=host -e http_proxy=$http_proxy -e https_proxy=$https_proxy -e no_proxy=$no_proxy opea/sqft:comps
    sleep 1m
}

function validate_upload() {
    local URL="$1"
    local SERVICE_NAME="$2"
    local DOCKER_NAME="$3"
    local EXPECTED_PURPOSE="$4"
    local EXPECTED_FILENAME="$5"

    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -F "file=@./$EXPECTED_FILENAME" -F purpose="$EXPECTED_PURPOSE" -H 'Content-Type: multipart/form-data' "$URL")
    HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')

    # Parse the JSON response
    purpose=$(echo "$RESPONSE_BODY" | jq -r '.purpose')
    filename=$(echo "$RESPONSE_BODY" | jq -r '.filename')

    if [ "$HTTP_STATUS" -ne "200" ]; then
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs $DOCKER_NAME >> ${LOG_PATH}/finetuning-server_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."
    fi

    # Check if the parsed values match the expected values
    if [[ "$purpose" != "$EXPECTED_PURPOSE" || "$filename" != "$EXPECTED_FILENAME" ]]; then
        echo "[ $SERVICE_NAME ] Content does not match the expected result: $RESPONSE_BODY"
        docker logs $DOCKER_NAME >> ${LOG_PATH}/finetuning-server_upload_file.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] Content is as expected."
    fi

    sleep 10s
}

function validate_finetune() {
    local URL="$1"
    local SERVICE_NAME="$2"
    local DOCKER_NAME="$3"
    local EXPECTED_DATA="$4"
    local INPUT_DATA="$5"

    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H 'Content-Type: application/json' -d "$INPUT_DATA" "$URL")
    HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
    FINTUNING_ID=$(echo "$RESPONSE_BODY" | jq -r '.id')

    # Parse the JSON response
    purpose=$(echo "$RESPONSE_BODY" | jq -r '.purpose')
    filename=$(echo "$RESPONSE_BODY" | jq -r '.filename')

    if [ "$HTTP_STATUS" -ne "200" ]; then
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs $DOCKER_NAME >> ${LOG_PATH}/finetuning-server_create.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."
    fi

    # Check if the parsed values match the expected values
    if [[ "$RESPONSE_BODY" != *"$EXPECTED_DATA"* ]]; then
        echo "[ $SERVICE_NAME ] Content does not match the expected result: $RESPONSE_BODY"
        docker logs $DOCKER_NAME >> ${LOG_PATH}/finetuning-server_create.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] Content is as expected."
    fi

    sleep 10s

    # check finetuning job status
    URL="http://${ip_address}:$finetuning_service_port/v1/fine_tuning/jobs/retrieve"
    for((i=1;i<=10;i++));
    do
        HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H "Content-Type: application/json" -d '{"fine_tuning_job_id": "'$FINTUNING_ID'"}' "$URL")
        echo $HTTP_RESPONSE
        RESPONSE_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')
        STATUS=$(echo "$RESPONSE_BODY" | jq -r '.status')
        if [[ "$STATUS" == "succeeded" ]]; then
            echo "training: succeeded."
            break
        elif [[ "$STATUS" == "failed" ]]; then
            echo "training: failed."
            exit 1
        else
            echo "training: '$STATUS'"
        fi
        sleep 1m
    done
}

function validate_merge_or_extract_adapter() {
    local URL="$1"
    local SERVICE_NAME="$2"
    local DOCKER_NAME="$3"
    local EXPECTED_DATA="$4"
    local INPUT_DATA="$5"

    HTTP_RESPONSE=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X POST -H 'Content-Type: application/json' -d "$INPUT_DATA" "$URL")
    HTTP_STATUS=$(echo $HTTP_RESPONSE | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    RESPONSE_BODY=$(echo $HTTP_RESPONSE | sed -e 's/HTTPSTATUS\:.*//g')

    if [ "$HTTP_STATUS" -ne "200" ]; then
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs $DOCKER_NAME >> ${LOG_PATH}/finetuning-server_merge_or_extract_adapter.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."
    fi

    # Check if the parsed values match the expected values
    if [[ "$RESPONSE_BODY" != *"$EXPECTED_DATA"* ]]; then
        echo "[ $SERVICE_NAME ] Content does not match the expected result: $RESPONSE_BODY"
        docker logs $DOCKER_NAME >> ${LOG_PATH}/finetuning-server_merge_or_extract_adapter.log
        exit 1
    else
        echo "[ $SERVICE_NAME ] Content is as expected."
    fi
}


function validate_sqft_microservice() {
    cd $LOG_PATH
    export no_proxy="localhost,127.0.0.1,"${ip_address}

    ##########################
    #      general test      #
    ##########################
    # test /v1/dataprep upload file
    echo '[{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."},{"instruction": "Give three tips for staying healthy.", "input": "", "output": "1.Eat a balanced diet and make sure to include plenty of fruits and vegetables. \n2. Exercise regularly to keep your body active and strong. \n3. Get enough sleep and maintain a consistent sleep schedule."}]' > $LOG_PATH/test_data.json
    validate_upload \
        "http://${ip_address}:$finetuning_service_port/v1/files" \
        "general - upload" \
        "test-comps-sqft-server" \
        "fine-tune" \
        "test_data.json"

    # test /v1/sqft/jobs (LoRA)
    validate_finetune \
        "http://${ip_address}:$finetuning_service_port/v1/sqft/jobs" \
        "general - finetuning" \
        "test-comps-sqft-server" \
        '{"id":"ft-job' \
        '{"training_file": "test_data.json","model": "meta-llama/Llama-3.2-1B", "Training": {"max_train_steps": 5}, "General": {"lora_config": {"r": 16, "target_modules": ["q_proj"]}}}'

    # test merging the LoRA adapter into the base model
    validate_merge_or_extract_adapter \
        "http://${ip_address}:$finetuning_service_port/v1/sqft/merge_adapter" \
        "adapter merge" \
        "test-comps-sqft-server" \
        "${FINTUNING_ID}" \
        "{\"fine_tuning_job_id\": \"${FINTUNING_ID}\"}"


    ##########################
    #     sqft (nls) test    #
    ##########################
    # test /v1/sqft/jobs (NLS)
    validate_finetune \
        "http://${ip_address}:$finetuning_service_port/v1/sqft/jobs" \
        "sqft (nls) - finetuning" \
        "test-comps-sqft-server" \
        '{"id":"ft-job' \
        '{"training_file": "test_data.json","model": "meta-llama/Llama-3.2-1B", "Training": {"max_train_steps": 5}, "General": {"lora_config": {"r": 16, "target_modules": ["q_proj"], "neural_lora_search": true, "nls_target_modules": ["q_proj"], "search_space": [8,6,4]}}}'

    # test extracting heuristic sub-adapter
    validate_merge_or_extract_adapter \
        "http://${ip_address}:$finetuning_service_port/v1/sqft/extract_sub_adapter" \
        "extract heuristic sub-adapter" \
        "test-comps-sqft-server" \
        "${FINTUNING_ID}" \
        "{\"fine_tuning_job_id\": \"${FINTUNING_ID}\", \"adapter_version\": \"heuristic\"}"

    # test merging the heuristic sub-adapter into the base model
    validate_merge_or_extract_adapter \
        "http://${ip_address}:$finetuning_service_port/v1/sqft/merge_adapter" \
        "merge heuristic sub-adapter" \
        "test-comps-sqft-server" \
        "${FINTUNING_ID}" \
        "{\"fine_tuning_job_id\": \"${FINTUNING_ID}\", \"adapter_version\": \"heuristic\"}"

    # test extracting sub-adapter with custom configuration
    validate_merge_or_extract_adapter \
        "http://${ip_address}:$finetuning_service_port/v1/sqft/extract_sub_adapter" \
        "extract custom sub-adapter" \
        "test-comps-sqft-server" \
        "${FINTUNING_ID}" \
        "{\"fine_tuning_job_id\": \"${FINTUNING_ID}\", \"adapter_version\": \"custom\", \"custom_config\": [8, 16, 8, 12, 16, 12, 12, 12, 12, 12, 8, 12, 12, 12, 12, 12]}"

    # test merging the custom sub-adapter into the base model
    validate_merge_or_extract_adapter \
        "http://${ip_address}:$finetuning_service_port/v1/sqft/merge_adapter" \
        "merge custom sub-adapter" \
        "test-comps-sqft-server" \
        "${FINTUNING_ID}" \
        "{\"fine_tuning_job_id\": \"${FINTUNING_ID}\", \"adapter_version\": \"custom\"}"
    

    ##########################
    # sqft (sparsepeft) test #
    ##########################
    # test /v1/sqft/jobs (SparsePEFT)
    # The model here should be a sparse model. For testing purposes, we are using meta-llama/Llama-3.2-1B.
    validate_finetune \
        "http://${ip_address}:$finetuning_service_port/v1/sqft/jobs" \
        "sqft (sparsepeft) - finetuning" \
        "test-comps-sqft-server" \
        '{"id":"ft-job' \
        '{"training_file": "test_data.json","model": "meta-llama/Llama-3.2-1B", "Training": {"max_train_steps": 5}, "General": {"lora_config": {"r": 16, "target_modules": ["q_proj"], "sparse_adapter": true}}}'

    validate_merge_or_extract_adapter \
        "http://${ip_address}:$finetuning_service_port/v1/sqft/merge_adapter" \
        "sparse adapter merge" \
        "test-comps-sqft-server" \
        "${FINTUNING_ID}" \
        "{\"fine_tuning_job_id\": \"${FINTUNING_ID}\"}"

}

function stop_docker() {
    cid=$(docker ps -aq --filter "name=test-comps-sqft-server*")
    if [[ ! -z "$cid" ]]; then docker stop $cid && docker rm $cid && sleep 1s; fi
}

function main() {

    stop_docker
    build_sqft_docker_images
    start_service
    validate_sqft_microservice

    stop_docker
    echo y | docker system prune

}

main
