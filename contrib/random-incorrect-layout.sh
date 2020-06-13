#!/bin/bash
# Randomized Layout for debug purposes. This version randomly makes some errors
# see how river handles incorrect output of layout executables.

CLIENTS="$1"
OUTPUT_WIDTH="$4"
OUTPUT_HEIGHT="$5"

for _ in $(seq 1 "$CLIENTS")
do
	WIDTH="$(( ( OUTPUT_WIDTH  / 5 ) ))"
	HEIGHT="$(( ( OUTPUT_HEIGHT  / 5 ) ))"
	X="$(( ( RANDOM % ( OUTPUT_WIDTH  - WIDTH  ) )  + 1 ))"
	Y="$(( ( RANDOM % ( OUTPUT_HEIGHT - HEIGHT ) )  + 1 ))"

	# Mix in some errors
	case "$(( ( RANDOM % 10 ) ))" in
		0) # Too few layout rows
			;;

		1) # Too many layout rows
			echo "$X $Y $WIDTH $HEIGHT"
			echo "$X $Y $WIDTH $HEIGHT"
			;;

		2) # Too few layout columns
			echo "$X $Y $WIDTH"
			;;

		3) # Too many layout columns
			echo "$X $Y $WIDTH $HEIGHT $X"
			;;


		4) # Negative view size
			echo "$X $Y -$WIDTH $HEIGHT $X"
			;;

		*) # Expected behaviour
			echo "$X $Y $WIDTH $HEIGHT"
			;;
	esac
done

