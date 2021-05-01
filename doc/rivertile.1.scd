RIVERTILE(1) "github.com/ifreund/river" "General Commands Manual"

# NAME

rivertile - Tiled layout generator for river

# SYNOPSIS

*rivertile* [_options_]

# DESCRIPTION

*rivertile* is a layout client for river. It provides a simple tiled layout
split main/secondary stacks.

# OPTIONS

*-view-padding* _pixels_
	Set the padding around views in pixels.

*-outer-padding* _pixels_
	Set the padding around the edge of the layout area in pixels.

*-main-location* [*top*|*bottom*|*left*|*right*]
	Set the default location of the main area in the layout.

*-main-count* _count_
	Set the default number of views in the main area of the layout.

*-main-factor* _ratio_
	Set the default ratio of main area to total layout area.

Note that _padding_ options needs to be set at *rivertile* launch.

Example:

```
rivertile -view-padding 4 -outer-padding 3
```

_main_ options can be set after *rivertile* launch with the help of *riverctl*.

Example:

```
riverctl set-layout-value rivertile string main_location top
```

# VALUES

_main_location_ (string: top, bottom, left, or right)
	The location of the main area in the layout.

_main_count_ (int)
	The number of views in the main area of the layout.

_main_factor_ (fixed: [0.1, 0.9])
	The ratio of main area to total layout area.

# AUTHORS

Maintained by Isaac Freund <ifreund@ifreund.xyz> who is assisted by open
source contributors. For more information about river's development, see
<https://github.com/ifreund/river>.

# SEE ALSO

*river*(1), *riverctl*(1)
