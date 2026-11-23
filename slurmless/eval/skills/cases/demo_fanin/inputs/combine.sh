#!/bin/sh
# combine: sum the two shard outputs -> total.txt  (fan-in; afterok both workers).
p1="$(cat part1.txt)"; p2="$(cat part2.txt)"
echo "$((p1 + p2))" > total.txt
