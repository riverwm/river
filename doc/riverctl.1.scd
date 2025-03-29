RIVERCTL(1)

# NAME

riverctl - command-line interface for controlling river

# SYNOPSIS

*riverctl* [_options_] _command_ [_command specific arguments_]

# DESCRIPTION

*riverctl* is a command-line utility used to control and configure river
over the Wayland protocol.

# OPTIONS

*-h*
	Print a help message and exit.

*-version*
	Print the version number and exit.

# TERMINOLOGY

This manual uses terms that some may find confusing, coming mostly from their
usage among other Wayland projects.

The *compositor*, display server, Wayland server etc. are ways to refer to river
itself.

A *view* (or *toplevel*) is what most call a window.

An *output* is a synonym for a screen or monitor.

*Tags* are river's way of dividing views of an output into groups (not
necessarily disjunct), an analogy to workspaces.

# COMMANDS

## ACTIONS

*close*
	Close the focused view.

*exit*
	Exit the compositor, terminating the Wayland session.

*focus-output* *next*|*previous*|*up*|*right*|*down*|*left*|_name_
	Focus the next or previous output, the closest output in any direction
	or an output by name.

*focus-view* [*-skip-floating*] *next*|*previous*|*up*|*down*|*left*|*right*
	Focus the next or previous view in the stack or the closest view in
	any direction.

	- *-skip-floating*: Skip floating views, only focusing tiled ones.

*move* *up*|*down*|*left*|*right* _delta_
	Move the focused view in the specified direction by _delta_ logical
	pixels. The view will be set to floating.

*resize* *horizontal*|*vertical* _delta_
	Resize the focused view along the given axis by _delta_ logical
	pixels. The view will be set to floating.

*snap* *up*|*down*|*left*|*right*
	Snap the focused view to the specified screen edge. The view will
	be set to floating.

*send-to-output* [*-current-tags*] *next*|*previous*|*up*|*right*|*down*|*left*|_name_
	Send the focused view to the next or previous output, the closest
	output in any direction or to an output by name.

	- *-current-tags*: Assign the currently focused tags of the destination
	  output to the view.

*spawn* _shell_command_
	Run _shell_command_ using `/bin/sh -c _shell_command_`. Note that
	*spawn* only takes a single argument. To spawn a command taking
	multiple arguments, wrapping the command in quotes is recommended.

*swap* *next*|*previous*|*up*|*down*|*left*|*right*
	Swap the focused view with the next or previous non-floating view in the
	stack or the closest non-floating view in any direction.

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

*send-layout-cmd* _namespace_ _command_
	Send _command_ to the layout generator on the currently focused output
	with the given _namespace_, if any. What commands a layout generator
	understands depends on the layout generator. For rivertile, see the
	documentation in the *rivertile*(1) man page.

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
	Set a _tagmask_ to filter the tags assigned to newly spawned views. This mask
	will be applied to the tags of new views with a bitwise and. If, for example,
	the tags 000011111 are focused and the spawn _tagmask_ is 111110001, a
	new view will be assigned the tags 000010001. If no tags would remain after
	filtering, the _tagmask_ is ignored.

*focus-previous-tags*
	Sets tags to their previous value on the currently focused output,
	allowing jumping back and forth between 2 tag setups.

*send-to-previous-tags*
	Assign the currently focused view the previous tags of the currently
	focused output.

## MAPPINGS

Mappings are modal in river. Each mapping is associated with a mode and
is only active while in that mode. There are two special modes: "normal"
and "locked". The normal mode is the initial mode on startup. The locked
mode is automatically entered while the session is locked (e.g. due to
a screenlocker). It cannot be entered or exited manually.

The following modifiers are available for use in mappings:

	- Shift
	- Control
	- Mod1 (Alt)
	- Mod3
	- Mod4 (Super)
	- Mod5
	- None

Alt and Super are aliases for Mod1 and Mod4 respectively. None allows creating
a mapping without modifiers.

Keys are specified by their XKB keysym name. See
_/usr/include/xkbcommon/xkbcommon-keysyms.h_ for the complete list.

Mouse buttons are specified by Linux input event code names. The most commonly
used values are:

	- BTN_LEFT - left mouse button
	- BTN_RIGHT - right mouse button
	- BTN_MIDDLE - middle mouse button

A complete list may be found in _/usr/include/linux/input-event-codes.h_

*declare-mode* _name_
	Create a new mode called _name_.

*enter-mode* _name_
	Switch to given mode if it exists.

*map* [*-release*|*-repeat*|*-layout* _index_] _mode_ _modifiers_ _key_ _command_
	Run _command_ when _key_ is pressed while _modifiers_ are held down
	and in the specified _mode_.

	- *-release*: if passed activate on key release instead of key press
	- *-repeat*: if passed activate repeatedly until key release; may not
	  be used with *-release*
	- *-layout*: if passed, a specific layout is pinned to the mapping.
	  When the mapping is checked against a pressed key, this layout is
	  used to translate the key independent of the active layout
		- _index_: zero-based index of a layout set with the *keyboard-layout*
		  command. If the index is out of range, the *-layout* option will
		  have no effect
	- _mode_: name of the mode for which to create the mapping
	- _modifiers_: one or more of the modifiers listed above, separated
	  by a plus sign (+).
	- _key_: an XKB keysym name as described above
	- _command_: any command that may be run with riverctl

*map-pointer* _mode_ _modifiers_ _button_ _action_|_command_
	Move or resize views or run _command_ when _button_ and _modifiers_ are held
	down while in the specified _mode_. The view under the cursor will be
	focused.

	- _mode_: name of the mode for which to create the mapping
	- _modifiers_: one or more of the modifiers listed above, separated
	  by a plus sign (+).
	- _button_: the name of a Linux input event code as described above
	- _action_: one of the following values:
		- move-view
		- resize-view
	- _command_: any command that may be run with riverctl

*map-switch* _mode_ *lid*|*tablet* _state_ _command_
	Run _command_ when river receives a certain switch event.

	- _mode_: name of the mode for which to create the mapping
	- _lid_|_tablet_: 'lid switch' and 'tablet mode switch' are supported
	- _state_:
		- possible states for _lid_:
			- close
			- open
		- possible states for _tablet_:
			- on
			- off
	- _command_: any command that may be run with riverctl

*unmap* [*-release*] _mode_ _modifiers_ _key_
	Remove the mapping defined by the arguments:

	- *-release*: if passed unmap the key release instead of the key press
	- _mode_: name of the mode for which to remove the mapping
	- _modifiers_: one or more of the modifiers listed above, separated
	  by a plus sign (+).
	- _key_: an XKB keysym name as described above

*unmap-pointer* _mode_ _modifiers_ _button_
	Remove the pointer mapping defined by the arguments:

	- _mode_: name of the mode for which to remove the mapping
	- _modifiers_: one or more of the modifiers listed above, separated
	  by a plus sign (+).
	- _button_: the name of a Linux input event code as described above

*unmap-switch* _mode_ *lid*|*tablet* _state_
	Remove the switch mapping defined by the arguments:

	- _mode_: name of the mode for which to remove the mapping
	- _lid_|_tablet_: the switch for which to remove the mapping
	- _state_: a state as listed above

## RULES

Rules match the app-id and title of views against a _glob_ pattern.  A _glob_
is a string that may optionally have an _\*_ at the beginning and/or end. An
_\*_ in a _glob_ matches zero or more arbitrary characters in the app-id
or title.

For example, _abc_ is matched by _a\*_, _\*a\*_, _\*b\*_, _\*c_, _abc_, and
_\*_ but not matched by _\*a_, _b\*_, _\*b_, _c\*_, or _ab_. Note that _\*_
matches everything while _\*\*_ and the empty string are invalid.

*rule-add* [*-app-id* _glob_|*-title* _glob_] _action_ [_arguments_]
	Add a rule that applies an _action_ to views with *app-id* and *title*
	matched by the respective _glob_. Omitting *-app-id* or *-title*
	is equivalent to passing *-app-id* _\*_ or *-title* _\*_.
	Some actions require one or more _arguments_.

	The supported _action_ types are:

	- *float*: Make the view floating. Applies only to new views.
	- *no-float*: Don't make the view floating. Applies only to
	  new views.
	- *ssd*: Use server-side decorations for the view. Applies to new
	  and existing views.
	- *csd*: Use client-side decorations for the view. Applies to new
	  and existing views.
	- *tags*: Set the initial tags of the view. Requires the tags as
	  an argument. Applies only to new views.
	- *output*: Set the initial output of the view. Requires the output
	  as an argument. Applies only to new views. The output can be specified
	  either by connector name (such as _HDMI-A-1_, or _DP-2_), or by
	  identifier in the form of _MAKE MODEL SERIAL_, for example for an output
	  with make: _HP Inc._, model: _HP 22w_, and serial: _CNC93720WF_, the
	  identifier would be: _HP Inc. HP 22w CNC93720WF_. If the make, model, or
	  serial is unknown, the word "Unknown" is used instead.
	- *position*: Set the initial position of the view, clamping to the
	  bounds of the output. Requires x and y coordinates of the view as
	  arguments, both of which must be non-negative. Applies only to new views.
	- *dimensions*: Set the initial dimensions of the view, clamping to the
	  constraints of the view. Requires width and height of the view as
	  arguments, both of which must be non-negative. Applies only to new views.
	- *fullscreen*: Make the view fullscreen. Applies only to new views.
	- *no-fullscreen*: Don't make the view fullscreen. Applies only to
	  new views.
	- *tearing*: Allow the view to tear when fullscreen regardless of the
	  view's preference. Applies to new and existing views.
	- *no-tearing*: Disable tearing for the view regardless of the view's
	  preference. Applies to new and existing views.

	Both *float* and *no-float* rules are added to the same list,
	which means that adding a *no-float* rule with the same arguments
	as a *float* rule will overwrite it. The same holds for *ssd* and
	*csd*, *fullscreen* and *no-fullscreen*, *tearing* and
	*no-tearing* rules.

	If multiple rules in a list match a given view the most specific
	rule will be applied. For example with the following rules
	```
	app-id  title  action
	foo     bar    ssd
	foo     *      csd
	*       bar    csd
	*       baz    ssd
	```
	a view with app-id 'foo' and title 'bar' would get ssd despite matching
	two csd rules as the first rule is most specific. Furthermore a view
	with app-id 'foo' and title 'baz' would get csd despite matching the
	last rule in the list since app-id specificity takes priority over
	title specificity.

	If a view is not matched by any rule, river will respect the csd/ssd
	wishes of the client and may start the view floating based on simple
	heuristics intended to catch popup-like views.

	If a view is started fullscreen or is not floating, then *position* and
	*dimensions* rules will have no effect  A view must be matched by a *float*
	rule in order for them to take effect.

*rule-del* [*-app-id* _glob_|*-title* _glob_] _action_
	Delete a rule created using *rule-add* with the given arguments.

*list-rules* *float*|*ssd*|*tags*|*position*|*dimensions*|*fullscreen*
	Print the specified rule list. The output is ordered from most specific
	to least specific, the same order in which views are checked against
	when searching for a match. Only the first matching rule in the list
	has an effect on a given view.

## CONFIGURATION

*default-attach-mode* *top*|*bottom*|*above*|*below*|*after <N>*
	Set the attach mode to be used by all outputs by default.

	Possible values:
	- top: Prepends the newly spawned view at the top of the stack.
	- bottom: Appends the newly spawned view at the bottom of the stack.
	- above: Inserts the newly spawned view above the currently focused view.
	- below: Inserts the newly spawned view below the currently focused view.
	- after <N>: Inserts the newly spawned view after N views in the stack.

	Note that the deprecated *attach-mode* command is aliased to
	*default-attach-mode* for backwards compatibility.

*output-attach-mode* *top*|*bottom*|*above*|*below*|*after <N>*
	Set the attach mode of the currently focused output, overriding the value of
	default-attach-mode if any.

*allow-tearing* *enabled*|*disabled*
	Allow fullscreen views to tear if requested by the view. See also the
	*tearing* rule to force enable tearing for specific views.

*background-color* _0xRRGGBB_|_0xRRGGBBAA_
	Set the background color.

*border-color-focused* _0xRRGGBB_|_0xRRGGBBAA_
	Set the border color of focused views.

*border-color-unfocused* _0xRRGGBB_|_0xRRGGBBAA_
	Set the border color of unfocused views.

*border-color-urgent* _0xRRGGBB_|_0xRRGGBBAA_
	Set the border color of urgent views.

*border-width* _pixels_
	Set the border width to _pixels_.

*focus-follows-cursor* *disabled*|*normal*|*always*
	There are three available modes:

	- _disabled_: Moving the cursor does not affect focus. This is
	  the default.
	- _normal_: Moving the cursor over a view will focus that view.
	  Moving the cursor within a view will not re-focus that view if
	  focus has moved elsewhere.
	- _always_: Moving the cursor will always focus whatever view is
	  under the cursor.

	If the view to be focused is on an output that does not have focus,
	focus is switched to that output.

*hide-cursor* *timeout* _timeout_
	Hide the cursor if it wasn't moved in the last _timeout_ milliseconds
	until it is moved again. The default value is 0, which disables
	automatically hiding the cursor. Show the cursor again on any movement.

*hide-cursor* *when-typing* *enabled*|*disabled*
	Hide the cursor when pressing any non-modifier key. Show the cursor
	again on any movement.

*set-cursor-warp* *disabled*|*on-output-change*|*on-focus-change*
	Set the cursor warp mode. There are two available modes:

	- _disabled_: Cursor will not be warped. This is the default.
	- _on-output-change_: When a different output is focused, the cursor will be
	  warped to its center.
	- _on-focus-change_: When a different view/output is focused, the cursor will be
	  warped to its center.

*set-repeat* _rate_ _delay_
	Set the keyboard repeat rate to _rate_ key repeats per second and
	repeat delay to _delay_ milliseconds. The default is a rate of 25
	repeats per second and a delay of 600ms.

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

*keyboard-layout* [-rules _rules_] [-model _model_] [-variant _variant_] \
[-options _options_] _layout_
	Set the XKB layout for all keyboards. Defaults from libxkbcommon are used for
	everything left unspecified. Note that _layout_ may be a comma separated list
	of layouts (e.g. "us,de") which may be switched between using various key
	combinations configured through the options argument (e.g. -options
	"grp:ctrl_space_toggle"). See *xkeyboard-config*(7) for possible values and
	more information.

*keyboard-layout-file* _path_
	Set the XKB layout for all keyboards from an XKB keymap file at the provided
	path. Documentation for the XKB keymap file format can be found at the
	following URL:
	https://xkbcommon.org/doc/current/keymap-text-format-v1.html

The _input_ command can be used to create a configuration rule for an input
device identified by its _name_.
The _name_ of an input device consists of its type, its decimal vendor id,
its decimal product id and finally its self-advertised name, separated by -.
Simple globbing patterns are supported, see the rules section for further
information on globs.

A list of all device properties that can be configured may be found below.
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

*input* _name_ *disable-while-trackpointing* *enabled*|*disabled*
	Enable or disable the disable-while-trackpointing functionality of the input device.

*input* _name_ *middle-emulation* *enabled*|*disabled*
	Enable or disable the middle click emulation functionality of the input device.

*input* _name_ *natural-scroll* *enabled*|*disabled*
	Enable or disable the natural scroll functionality of the input device. If
	active, the scroll direction is inverted.

*input* _name_ *scroll-factor* _factor_
	Set the scroll factor of the input device. Accepts a postive value
	greater than 0. For example, a _factor_ of 0.5 will make scrolling twice
	as slow while a _factor_ of 3 will make scrolling 3 times as fast.

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
	Set the scroll button of an input device. _button_ is the name of a Linux
	input event code.

*input* _name_ *scroll-button-lock* *enabled*|*disabled*
	Enable or disable the scroll button lock functionality of the input device. If
	active, the button does not need to be held down. One press makes the button
	considered to be held down, and a second press releases the button.

*input* _name_ *map-to-output* _output_|*disabled*
	Maps the input to a given output. This is valid even if the output isn't
	currently active and will lead to the device being mapped once it is
	connected.

# EXAMPLES

Bind Super+Return in normal mode to spawn a *foot*(1) terminal:

	riverctl map normal Mod4 Return spawn 'foot --app-id=foobar'

Bind Super+Shift+J to swap the focused view with the next visible view:

	riverctl map normal Mod4+Shift J swap next

# AUTHORS

Maintained by Isaac Freund <mail@isaacfreund.com> who is assisted by open
source contributors. For more information about river's development, see
<https://isaacfreund.com/software/river>.

# SEE ALSO

*river*(1), *rivertile*(1)
