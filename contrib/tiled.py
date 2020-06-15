#!/bin/env python

from sys import argv

# This is an implementation of the  default "tiled" layout of dwm
#
# With 4 views and one master, the layout looks something like this:
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
master_count = int(argv[2])
master_factor = float(argv[3])
output_width = int(argv[4])
output_height = int(argv[5])

secondary_count = num_views - master_count

# handle the cases where there are no master or no secondary views
master_width = 0
secondary_width = 0
if master_count > 0 and secondary_count > 0:
    master_width = int(master_factor * output_width)
    secondary_width = output_width - master_width
elif master_count > 0:
    master_width = output_width
elif secondary_count > 0:
    secondary_width = output_width


# for each view, output the location/dimensions separated by spaces on a new line
for i in range(num_views):
    if i < master_count:
        # to make things pixel-perfect, we make the first master and first secondary
        # view slightly larger if the height is not evenly divisible
        master_height = output_height // master_count
        master_height_rem = output_height % master_count

        x = 0
        y = i * master_height + (master_height_rem if i > 0 else 0)
        width = master_width
        height = master_height + (master_height_rem if i == 0 else 0)

        print(x, y, width, height)
    else:
        secondary_height = output_height // secondary_count
        secondary_height_rem = output_height % secondary_count

        x = master_width
        y = (i - master_count) * secondary_height + (secondary_height_rem if i > master_count else 0)
        width = secondary_width
        height = secondary_height + (secondary_height_rem if i == master_count else 0)

        print(x, y, width, height)
