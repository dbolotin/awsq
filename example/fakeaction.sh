#!/bin/bash

for i in $(seq 1 10)
do
    echo dd ${1}
    echo dd ${2}
    echo dd ${3}
    sleep 20
done
