#!/bin/bash
# Randomized Layout for debug purposes.

CLIENTS="$1"
OUTPUT_WIDTH="$4"
OUTPUT_HEIGHT="$5"

for _ in $(seq 1 "$CLIENTS")
do
	WIDTH="$(( ( OUTPUT_WIDTH  / 5 ) ))"
	HEIGHT="$(( ( OUTPUT_HEIGHT  / 5 ) ))"
	X="$(( ( RANDOM % ( OUTPUT_WIDTH  - WIDTH  ) )  + 1 ))"
	Y="$(( ( RANDOM % ( OUTPUT_HEIGHT - HEIGHT ) )  + 1 ))"
	echo "$X $Y $WIDTH $HEIGHT"
done

