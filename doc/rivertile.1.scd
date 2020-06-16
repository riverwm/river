RIVERTILE(1) "github.com/ifreund/river" "General Commands Manual"

# NAME

rivertile - tiled layout generator for river

# SYNOPSIS

*rivertile* *left*|*right*|*top*|*bottom* [args passed by river]

# DESCRIPTION

*rivertile* is a layout generator for river. It produces tiled layouts with
split master/secondary stacks in four configurable orientations.

# OPTIONS

*left*
	Place the master stack on the left side of the output.

*right*
	Place the master stack on the right side of the output.

*top*
	Place the master stack at the top of the output.

*bottom*
	Place the master stack at the bottom of the output.

# EXAMPLE

Set river's layout to *rivertile*'s *left* layout using riverctl

	riverctl layout rivertile left

# SEE ALSO

*river-layouts*(7), *river*(1), *riverctl*(1)
