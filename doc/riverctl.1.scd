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
	side decoration. Note that this affects both new views, as well as already
	existing ones.

*csd-filter-remove* _app-id_
	Remove an _app-id_ from the CSD filter list. Note that this affects both new
	views, as well as already existing ones.

*exit*
	Exit the compositor, terminating the Wayland session.

*float-filter-add* _app-id_
	Add _app-id_ to the float filter list. Views with this _app-id_
	will start floating. Note that this affects only new views, not already
	existing ones.

*float-filter-remove* _app-id_
	Remove an _app-id_ from the float filter list. Note that this affects only
	new views, not already existing ones.

*focus-output* *next*|*previous*|*up*|*right*|*down*|*left*
	Focus the next or previous output or the closest output in any direction.

*focus-view* *next*|*previous*
	Focus the next or previous view in the stack.

*move* *up*|*down*|*left*|*right* _delta_
	Move the focused view in the specified direction by _delta_ logical
	pixels. The view will be set to floating.

*resize* *horizontal*|*vertical* _delta_
	Resize the focused view along the given axis by _delta_ logical
	pixels. The view will be set to floating.

*snap* *up*|*down*|*left*|*right*
	Snap the focused view to the specified screen edge. The view will
	be set to floating.

*send-to-output* *next*|*previous*|*up*|*right*|*down*|*left*
	Send the focused view to the next or previous output or the closest
	output in any direction.

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

*default-layout* _namespace_
	Set the layout namespace to be used by all outputs by default.

*output-layout* _namespace_
	Set the layout namespace of currently focused output, overriding
	the value set with *default-layout* if any.

*set-layout-value* _namespace_ _type_ _name_ _value_
	Set the value with name _name_ of the layout on the focused output
	with matching namespace. If there is no matching layout, this command
	does nothing.

*mod-layout-value* _namespace_ _type_ _name_ _value_
	Modify the value with name _name_ of the layout on the focused
	output with matching namespace. If there is no matching layout,
	this command does nothing.

## TAG MANAGEMENT

Tags are similar to workspaces but more flexible. You can assign views multiple
tags and focus multiple tags simultaneously. Bitfields are used to describe
sets of tags when interfacing with river. As such, the following commands
take a normal base 10 number as their argument but the semantics are best
understood in binary. The binary number 000000001 represents a set containing
only tag 1 while 100001101 represents a set containing tags 1, 3, 4, and 9.

When a view spawns it is assigned the currently focused tags of the output.

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

*spawn-tagmask* _tagmask_
	Set a _tagmask_ to filter the tags assigned to newly spawned views
	on the focused output. This mask will be applied to the tags of
	new views with a bitwise and. If, for example, the tags 000011111
	are focused on an output with a _tagmask_ of 111110001, a new view
	will be assigned the tags 000010001. If no tags would remain after
	filtering, the _tagmask_ is ignored.

*focus-previous-tags*
	Sets tags to their previous value on the currently focused output,
	allowing jumping back and forth between 2 tag setups.

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
	Switch to given mode if it exists.

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
	Configure where new views should attach to the view stack.

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
	  the default.
	- _normal_: Moving the cursor over a view will focus that view.
	  Moving the cursor within a view will not re-focus that view if
	  focus has moved elsewhere.
	- _strict_: Moving the cursor over a view or within a view will
	  focus that view.

	If the view to be focused is on an output that does not have focus,
	focus is switched to that output.

*set-cursor-warp* *disabled*|*on-output-change*
	Set the cursor warp mode. There are two available modes:

	- _disabled_: Cursor will not be warped. This is the default.
	- _on-output-change_: When a different output is focused, the cursor will be
	  warped to its center.

*opacity* _focused_ _unfocused_ _initial_ _step-size_ _delta-t_
	Configure server-side opacity of views, including transition
	animations. A value of 0.0 is fully transparent while 1.0 is fully
	opaque. By default all views are fully opaque and there are no
	animations.

	- _focused_: opacity of focused views [0.0, 1.0]
	- _unfocused_: opacity of unfocused views [0.0, 1.0]
	- _initial_: opacity of views when they are created before immediately
	  transitioning to either _focused_ or _unfocused_ [0.0, 1.0]
	- _step-size_: opacity change per step [0.05, 1.0]
	- _delta-t_: step time in milliseconds

	A transition animation may occur when changing between states with
	different opacity values configured. Instead of setting the view's
	opacity to the value for the new state immediately, it is changed
	incrementally in steps of _step-size_ every _delta-t_ milliseconds.
	Setting _step-size_ to 1.0 disables transitions fully regardless of
	the value of _delta-t_.

*set-repeat* _rate_ _delay_
	Set the keyboard repeat rate to _rate_ key repeats per second and
	repeat delay to _delay_ milliseconds.

*xcursor-theme* _theme_name_ [_size_]
	Set the xcursor theme to _theme_name_ and optionally set the _size_.
	The theme of the default seat determines the default for Xwayland
	and is made available through the _XCURSOR_THEME_ and _XCURSOR_SIZE_
	environment variables.

## INPUT CONFIGURATION

*list-inputs*
	List all input devices.

*list-input-configs*
	List all input configurations.

The _input_ command can be used to create a configuration rule for an input
device identified by its _name_.

A list of all device properties that can be configured maybe found below.
However note that not every input device supports every property.

*input* _name_ *events* *enabled*|*disabled*|*disabled-on-external-mouse*
	Configure whether the input devices events will be used by river.

*input* _name_ *accel-profile* *none*|*flat*|*adaptive*
	Set the pointer acceleration profile of the input device.

*input* _name_ *pointer-accel* _factor_
	Set the pointer acceleration factor of the input device. Needs a float
	between -1.0 and 1.0.

*input* _name_ *click-method* *none*|*button-areas*|*clickfinger*
	Set the click method of the input device.

*input* _name_ *drag* *enabled*|*disabled*
	Enable or disable the tap-and-drag functionality of the input device.

*input* _name_ *drag-lock* *enabled*|*disabled*
	Enable or disable the drag lock functionality of the input device.

*input* _name_ *disable-while-typing* *enabled*|*disabled*
	Enable or disable the disable-while-typing functionality of the input device.

*input* _name_ *middle-emulation* *enabled*|*disabled*
	Enable or disable the middle click emulation functionality of the input device.

*input* _name_ *natural-scroll* *enabled*|*disabled*
	Enable or disable the natural scroll functionality of the input device. If
	active, the scroll direction is inverted.

*input* _name_ *left-handed* *enabled*|*disabled*
	Enable or disable the left handed mode of the input device.

*input* _name_ *tap* *enabled*|*disabled*
	Enable or disable the tap functionality of the input device.

*input* _name_ *tap-button-map* *left-right-middle*|*left-middle-right*
	Configure the button mapping for tapping.

	- _left-right-middle_: 1 finger tap equals left click, 2 finger tap equals
	  right click, 3 finger tap equals middle click.
	- _left-middle-right_: 1 finger tap equals left click, 2 finger tap equals
	  middle click, 3 finger tap equals right click.

*input* _name_ *scroll-method* *none*|*two-finger*|*edge*|*button*
	Set the scroll method of the input device.

	- _none_: No scrolling
	- _two-finger_: Scroll by swiping with two fingers simultaneously
	- _edge_: Scroll by swiping along the edge
	- _button_: Scroll with pointer movement while holding down a button

*input* _name_ *scroll-button* _button_
	Set the scroll button of an input device. _button_ is the name of a linux
	input event code.

# EXAMPLES

Bind bemenu-run to Super+P in normal mode:

	riverctl map normal Mod4 P spawn bemenu-run

See also the example init script at /etc/river/init.

# AUTHORS

Maintained by Isaac Freund <ifreund@ifreund.xyz> who is assisted by open
source contributors. For more information about river's development, see
<https://github.com/ifreund/river>.

# SEE ALSO

*river*(1), *rivertile*(1)
