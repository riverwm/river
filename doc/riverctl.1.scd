RIVERCTL(1) "github.com/ifreund/river" "General Commands Manual"

# NAME

riverctl - command-line interface for controlling river

# SYNOPSIS

*riverctl* _command_ [_command specific arguments_]

# DESCRIPTION

*riverctl* is a command-line utility used to control and configure river
over the Wayland protocol.

# COMMANDS

## ACTIONS

*close*
	Close the focused view.

*csd-filter-add* _app-id_
	Add _app-id_ to the CSD filter list. Views with this _app-id_ are
	told to use client side decoration instead of the default server
	side decoration.

*exit*
	Exit the compositor, terminating the Wayland session.

*float-filter-add* _app-id_
	Add _app-id_ to the float filter list. Views with this _app-id_
	will start floating.

*focus-output* *next*|*previous*
	Focus the next or previous output.

*focus-view* *next*|*previous*
	Focus the next or previous view in the stack.

*layout* *full*|_command_
	Provide a command which river will use for generating the layout
	of non-floating windows on the currently focused output. See
	*river-layouts*(7) for details on the expected formatting of the
	output of layout commands. Alternatively, “full” can be given
	instead of a command to cause river to use its single internal layout,
	in which windows span the entire width and height of the output.

*mod-main-count* _integer_
	Increase or decrease the number of "main" views which is relayed to the
	layout generator. _integer_ can be positive or negative. Exactly how
	"main" views are display, or if they are even displayed differently
	from other views, is left to the layout generator.

*mod-main-factor* _float_
	Increase or decrease the "main factor" relayed to layout
	generators. _float_ is a positive or negative floating point number
	(such as 0.05). This value is added to the current main factor which
	is then clamped to the range [0.0, 1.0]. The layout generator is
	free to interpret this value as it sees fit, or ignore it entirely.
	*rivertile*(1) uses this to determine what percentage of the screen
	the "main" area will occupy.

*move* *up*|*down*|*left*|*right* _delta_
	Move the focused view in the specified direction by _delta_ logical
	pixels. The view will be set to floating.

*resize* *horizontal*|*vertical* _delta_
	Resize the focused view along the given axis by _delta_ logical
	pixels. The view will be set to floating.

*snap* *up*|*down*|*left*|*right*
	Snap the focused view to the specified screen edge. The view will
	be set to floating.

*send-to-output* *next*|*previous*
	Send the focused view to the next or the previous output.

*spawn* _shell_command_
	Run _shell_command_ using _/bin/sh -c_. Put single quotes around
	_shell_command_ if you do not want special characters to get
	interpreted by your shell before the command gets passed to _/bin/sh_.

*swap* *next*|*previous*
	Swap the focused view with the next/previous visible non-floating
	view. If the first/last view in the stack is focused, wrap.

*toggle-float*
	Toggle the floating state of the focused view.

*toggle-fullscreen*
	Toggle the fullscreen state of the focused view.

*zoom*
	Bump the focused view to the top of the layout stack. If the top
	view in the stack is already focused, bump the second view.

## TAG MANAGEMENT

Tags are similar to workspaces but more flexible. You can assign views multiple
tags and focus multiple tags simultaneously. Bitfields are used to describe
sets of tags when interfacing with river. As such, the following commands
take a normal base 10 number as their argument but the semantics are best
understood in binary. The binary number 000000001 represents a set containing
only tag 1 while 100001101 represents a set containing tags 1, 3, 4, and 9.

At least one tag must always be focused and each view must be assigned at
least one tag. Operations that would violate either of these requirements
are ignored by river.

*set-focused-tags* _tags_
	Show views with tags corresponding to the set bits of _tags_ on the
	currently focused output.

*set-view-tags* _tags_
	Assign the currently focused view the tags corresponding to the set
	bits of _tags_.

*toggle-focused-tags* _tags_
	Toggle visibility of views with tags corresponding to the set bits
	of _tags_ on the currently focused output.

*toggle-view-tags* _tags_
	Toggle the tags of the currently focused view corresponding to the
	set bits of _tags_.

## MAPPINGS

Mappings are modal in river. Each mapping is associated with a mode and is
only active while in that mode. There are two special modes: "default" and
"locked". The default mode is the initial mode for every seat. The locked
mode is automatically entered while an input inhibitor (such as a lockscreen)
is active. It cannot be left or entered manually.

The following modifiers are available for use in mappings:

	- Shift
	- Lock (Caps lock)
	- Control (Ctrl)
	- Mod1 (Alt)
	- Mod2
	- Mod3
	- Mod4 (Super, Logo, Windows)
	- Mod5
	- None (Create a mapping without modifiers)

Keys are specified by their XKB keysym name. See
_/usr/include/xkbcommon/xkbcommon-keysyms.h_ for the complete list.

Mouse buttons are specified by linux input event code names. The most commonly
used values are:

	- BTN_LEFT - left mouse button
	- BTN_RIGHT - right mouse button
	- BTN_MIDDLE - middle mouse button

A complete list may be found in _/usr/include/linux/input-event-codes.h_

*declare-mode* _name_
	Create a new mode called _name_.

*enter-mode* _name_
	Switch to given mode if it exits.

*map* [_-release_] _mode_ _modifiers_ _key_ _command_
	Run _command_ when _key_ is pressed while _modifiers_ are held down
	and in the specified _mode_.

	- _-release_: if passed activate on key release instead of key press
	- _mode_: name of the mode for which to create the mapping
	- _modifiers_: one or more of the modifiers listed above, separated
	  by a plus sign (+).
	- _key_: an XKB keysym name as described above
	- _command_: any command that may be run with riverctl

*map-pointer* _mode_ _modifiers_ _button_ _action_
	Move or resize views when _button_ and _modifiers_ are held down
	while in the specified _mode_.

	- _mode_: name of the mode for which to create the mapping
	- _modifiers_: one or more of the modifiers listed above, separated
	  by a plus sign (+).
	- _button_: the name of a linux input event code as described above
	- _action_: one of the following values:
		- move-view
		- resize-view

*unmap* [_-release_] _mode_ _modifiers_ _key_
	Remove the mapping defined by the arguments:

	- _-release_: if passed unmap the key release instead of the key press
	- _mode_: name of the mode for which to remove the mapping
	- _modifiers_: one or more of the modifiers listed above, separated
	  by a plus sign (+).
	- _key_: an XKB keysym name as described above

*unmap-pointer* _mode_ _modifiers_ _button_
	Remove the pointer mapping defined by the arguments:

	- _mode_: name of the mode for which to remove the mapping
	- _modifiers_: one or more of the modifiers listed above, separated
	  by a plus sign (+).
	- _button_: the name of a linux input event code as described above

## CONFIGURATION

*attach-mode* *top*|*bottom*
	Configure where new views should attach to the view stack for the
	currently focused output.

*background-color* _#RRGGBB_|_#RRGGBBAA_
	Set the background color.

*border-color-focused* _#RRGGBB_|_#RRGGBBAA_
	Set the border color of focused views.

*border-color-unfocused* _#RRGGBB_|_#RRGGBBAA_
	Set the border color of unfocused views.

*border-width* _pixels_
	Set the border width to _pixels_.

*focus-follows-cursor* *disabled*|*normal*|*strict*
	There are three available modes:

	- _disabled_: Moving the cursor does not affect focus. This is
	  the default
	- _normal_: Moving the cursor over a view will focus that view.
	  Moving the cursor within a view will not re-focus that view if
	  focus has moved elsewhere.
	- _strict_: Moving the cursor over a view or within a view will
	  focus that view.

	If the view to be focused is on an output that does not have focus,
	focus is switched to that output.

*opacity* _focused_ _unfocused_ _initial_ _step_size_ _delta-t_
	Configure server-side opacity of views, including transition
	animations. A value of 0.0 is fully transparent while 1.0 is fully
	opaque. By default all views are fully opaque and there are no
	animations.

	- _focused_: opacity of focused views [0.0, 1.0]
	- _unfocused_: opacity of unfocused views [0.0, 1.0]
	- _initial_: opacity of views when they are created before immediately
	  transitioning to either _focused_ or _unfocused_ [0.0, 1.0]
	- _step_size_: opacity change per step [0.05, 1.0]
	- _delta-t_: step time in milliseconds

	A transition animation may occur when changing between states with
	different opacity values configured. Instead of setting the view's
	opacity to the value for the new state immediately, it is changed
	incrementally in steps of _step_size_ every _delta-t_ milliseconds.
	Setting _step_size_ to 1.0 disables transitions fully regardless of
	the value of _delta-t_.

*outer-padding* _pixels_
	Set the padding around the edge of the screen to _pixels_.

*set-repeat* _rate_ _delay_
	Set the keyboard repeat rate to _rate_ key repeats per second and
	repeat delay to _delay_ milliseconds.

*view-padding* _pixels_
	Set the padding around the edge of each view to _pixels_.

*xcursor-theme* _theme_name_ [_size_]
	Set the xcursor theme to _theme_name_ and optionally set the _size_.
	The theme of the default seat determines the default for Xwayland
	and is made available through the _XCURSOR_THEME_ and _XCURSOR_SIZE_
	environment variables.

# EXAMPLES

Bind bemenu-run to Super+P in normal mode:

	riverctl map normal Mod4 P spawn bemenu-run

See also the example init script at /etc/river/init.

# AUTHORS

Maintained by Isaac Freund <ifreund@ifreund.xyz> who is assisted by open
source contributors. For more information about river's development, see
<https://github.com/ifreund/river>.

# SEE ALSO

*river*(1), *river-layouts*(7), *rivertile*(1)
