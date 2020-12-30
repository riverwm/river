#!/bin/env python

from sys import argv

# This is an implementation of the  default "tiled" layout of dwm
#
# With 4 views and one main view, the layout looks something like this:
#
# +-----------------------+------------+
# |                       |            |
# |                       |            |
# |                       |            |
# |                       +------------+
# |                       |            |
# |                       |            |
# |                       |            |
# |                       +------------+
# |                       |            |
# |                       |            |
# |                       |            |
# +-----------------------+------------+

# Assign the arguments to variables. The order and meaning of the arguments
# is explained in the river-layouts(7) man page
num_views = int(argv[1])
main_count = int(argv[2])
main_factor = float(argv[3])
output_width = int(argv[4])
output_height = int(argv[5])

secondary_count = num_views - main_count

# handle the cases where there are no main or no secondary views
main_width = 0
secondary_width = 0
if main_count > 0 and secondary_count > 0:
    main_width = int(main_factor * output_width)
    secondary_width = output_width - main_width
elif main_count > 0:
    main_width = output_width
elif secondary_count > 0:
    secondary_width = output_width


# for each view, output the location/dimensions separated by spaces on a new line
for i in range(num_views):
    if i < main_count:
        # to make things pixel-perfect, we make the first main and first secondary
        # view slightly larger if the height is not evenly divisible
        main_height = output_height // main_count
        main_height_rem = output_height % main_count

        x = 0
        y = i * main_height + (main_height_rem if i > 0 else 0)
        width = main_width
        height = main_height + (main_height_rem if i == 0 else 0)

        print(x, y, width, height)
    else:
        secondary_height = output_height // secondary_count
        secondary_height_rem = output_height % secondary_count

        x = main_width
        y = (i - main_count) * secondary_height + (secondary_height_rem if i > main_count else 0)
        width = secondary_width
        height = secondary_height + (secondary_height_rem if i == main_count else 0)

        print(x, y, width, height)
