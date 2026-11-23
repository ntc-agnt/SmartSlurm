#!/bin/sh
# worker <k>: scale the base value by shard factor k -> part<k>.txt  (fan-out).
k="${1:?worker needs a shard index}"
b="$(cat base.txt)"
echo "$((b * k))" > "part${k}.txt"
