RIVER-LAYOUTS(7) "github.com/ifreund/river"

# NAME
river-layouts - Details on layout generators for river

# DESCRIPTION
River can use external window management layouts. To get such a layout, river
will run an executable and parse its output. This document outlines how such
a layout generator interacts with river.

# INPUT
When running the executable, river will provide it with five parameters which
are appended to the end of the command in the following order:

. The amount of visible clients (integer)
. The amount of views dedicated as master (integer)
. The screen size multiplier for the master area (float between 0.0 and 1.0)
. The useable width of the output (integer)
. The useable height of the output (integer)

A layout generator may choose to ignore any of these values except
for the first one.

# OUTPUT
River expects four integer values for each window: The x position, the y
position, the width and the height. These must be separated by spaces. A
window configuration having fewer or more than four values is an error and will
cause river to fall back the full layout.

A layout generator needs to output position and size for every visible window.
The window configurations are separated by a newline. Too few or too many
outputted window configurations is an error and will cause river to fall back
to the full layout.

River will apply the position and dimensions in the order they are outputted to
the visible windows in the stack from top to bottom.

The output of a layout generator is not required to remain the same when called
with identical parameters. Layouts are allowed to also depend on external
factors or be completely random.

# WINDOW DIMENSIONS and POSITION
Layout generators are not supposed to include padding or leave space for window
borders. The window dimensions will be shrunk by river to make space for these.
River enforces a minimal window width and height of 50.

Layout generators operate on a special coordinate grid from 0 to the maximum
useable width or height of an output with the coordinate 0-0 being positioned at
the top-left corner of the useable area of an output. While layout generators
are free to place windows everywhere (including coordinates below zero or above
the maximum width or height of an output), beware that the relative positioning
of this grid on the screen can not be expected to remain constant. River applies
an offset to window positions, depending on outer padding and the presence of
desktop widgets like bars. Layout generators can therefore not position windows
at exact screen coordinates.

Layout generators are not required to make use of the entire available space.
Windows may overlap.

# EXAMPLE
Below is an example output of a layout generator for four visible windows. In
this example layout all four windows have a size of 500 by 500 and are arranged
in a grid.

```
0 0 500 500
500 0 500 500
0 500 500 500
500 500 500 500
```

# SEE ALSO
*river*(1), *riverctl*(1), *rivertile*(1)
