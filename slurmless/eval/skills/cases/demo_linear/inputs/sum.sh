#!/bin/sh
# sum: reduce the squares to a single total. Reads sq.txt, writes total.txt.
awk '{ s += $1 } END { print s }' sq.txt > total.txt
