#!/bin/sh
# square: transform each number -> its square. Reads nums.txt, writes sq.txt.
awk '{ print $1*$1 }' nums.txt > sq.txt
