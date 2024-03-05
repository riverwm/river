#!/bin/sh

# This is the example configuration file for river.
#
# If you wish to edit this, you will probably want to copy it to
# $XDG_CONFIG_HOME/river/init or $HOME/.config/river/init first.
#
# See the river(1), riverctl(1), and rivertile(1) man pages for complete
# documentation.

# Note: the "Super" modifier is also known as Logo, GUI, Windows, Mod4, etc.

# Super+Shift+Return to start an instance of foot (https://codeberg.org/dnkl/foot)
riverctl map normal Super+Shift Return spawn foot

# Super+Q to close the focused view
riverctl map normal Super Q close

# Super+Shift+E to exit river
riverctl map normal Super+Shift E exit

# Super+J and Super+K to focus the next/previous view in the layout stack
riverctl map normal Super J focus-view next
riverctl map normal Super K focus-view previous

# Super+Shift+J and Super+Shift+K to swap the focused view with the next/previous
# view in the layout stack
riverctl map normal Super+Shift J swap next
riverctl map normal Super+Shift K swap previous

# Super+Period and Super+Comma to focus the next/previous output
riverctl map normal Super Period focus-output next
riverctl map normal Super Comma focus-output previous

# Super+Shift+{Period,Comma} to send the focused view to the next/previous output
riverctl map normal Super+Shift Period send-to-output next
riverctl map normal Super+Shift Comma send-to-output previous

# Super+Return to bump the focused view to the top of the layout stack
riverctl map normal Super Return zoom

# Super+H and Super+L to decrease/increase the main ratio of rivertile(1)
riverctl map normal Super H send-layout-cmd rivertile "main-ratio -0.05"
riverctl map normal Super L send-layout-cmd rivertile "main-ratio +0.05"

# Super+Shift+H and Super+Shift+L to increment/decrement the main count of rivertile(1)
riverctl map normal Super+Shift H send-layout-cmd rivertile "main-count +1"
riverctl map normal Super+Shift L send-layout-cmd rivertile "main-count -1"

# Super+Alt+{H,J,K,L} to move views
riverctl map normal Super+Alt H move left 100
riverctl map normal Super+Alt J move down 100
riverctl map normal Super+Alt K move up 100
riverctl map normal Super+Alt L move right 100

# Super+Alt+Control+{H,J,K,L} to snap views to screen edges
riverctl map normal Super+Alt+Control H snap left
riverctl map normal Super+Alt+Control J snap down
riverctl map normal Super+Alt+Control K snap up
riverctl map normal Super+Alt+Control L snap right

# Super+Alt+Shift+{H,J,K,L} to resize views
riverctl map normal Super+Alt+Shift H resize horizontal -100
riverctl map normal Super+Alt+Shift J resize vertical 100
riverctl map normal Super+Alt+Shift K resize vertical -100
riverctl map normal Super+Alt+Shift L resize horizontal 100

# Super + Left Mouse Button to move views
riverctl map-pointer normal Super BTN_LEFT move-view

# Super + Right Mouse Button to resize views
riverctl map-pointer normal Super BTN_RIGHT resize-view

# Super + Middle Mouse Button to toggle float
riverctl map-pointer normal Super BTN_MIDDLE toggle-float

for i in $(seq 1 9)
do
    tags=$((1 << ($i - 1)))

    # Super+[1-9] to focus tag [0-8]
    riverctl map normal Super $i set-focused-tags $tags

    # Super+Shift+[1-9] to tag focused view with tag [0-8]
    riverctl map normal Super+Shift $i set-view-tags $tags

    # Super+Control+[1-9] to toggle focus of tag [0-8]
    riverctl map normal Super+Control $i toggle-focused-tags $tags

    # Super+Shift+Control+[1-9] to toggle tag [0-8] of focused view
    riverctl map normal Super+Shift+Control $i toggle-view-tags $tags
done

# Super+0 to focus all tags
# Super+Shift+0 to tag focused view with all tags
all_tags=$(((1 << 32) - 1))
riverctl map normal Super 0 set-focused-tags $all_tags
riverctl map normal Super+Shift 0 set-view-tags $all_tags

# Super+Space to toggle float
riverctl map normal Super Space toggle-float

# Super+F to toggle fullscreen
riverctl map normal Super F toggle-fullscreen

# Super+{Up,Right,Down,Left} to change layout orientation
riverctl map normal Super Up    send-layout-cmd rivertile "main-location top"
riverctl map normal Super Right send-layout-cmd rivertile "main-location right"
riverctl map normal Super Down  send-layout-cmd rivertile "main-location bottom"
riverctl map normal Super Left  send-layout-cmd rivertile "main-location left"

# Declare a passthrough mode. This mode has only a single mapping to return to
# normal mode. This makes it useful for testing a nested wayland compositor
riverctl declare-mode passthrough

# Super+F11 to enter passthrough mode
riverctl map normal Super F11 enter-mode passthrough

# Super+F11 to return to normal mode
riverctl map passthrough Super F11 enter-mode normal

# Various media key mapping examples for both normal and locked mode which do
# not have a modifier
for mode in normal locked
do
    # Eject the optical drive (well if you still have one that is)
    riverctl map $mode None XF86Eject spawn 'eject -T'

    # Control pulse audio volume with pamixer (https://github.com/cdemoulins/pamixer)
    riverctl map $mode None XF86AudioRaiseVolume  spawn 'pamixer -i 5'
    riverctl map $mode None XF86AudioLowerVolume  spawn 'pamixer -d 5'
    riverctl map $mode None XF86AudioMute         spawn 'pamixer --toggle-mute'

    # Control MPRIS aware media players with playerctl (https://github.com/altdesktop/playerctl)
    riverctl map $mode None XF86AudioMedia spawn 'playerctl play-pause'
    riverctl map $mode None XF86AudioPlay  spawn 'playerctl play-pause'
    riverctl map $mode None XF86AudioPrev  spawn 'playerctl previous'
    riverctl map $mode None XF86AudioNext  spawn 'playerctl next'

    # Control screen backlight brightness with brightnessctl (https://github.com/Hummer12007/brightnessctl)
    riverctl map $mode None XF86MonBrightnessUp   spawn 'brightnessctl set +5%'
    riverctl map $mode None XF86MonBrightnessDown spawn 'brightnessctl set 5%-'
done

# Set background and border color
riverctl background-color 0x002b36
riverctl border-color-focused 0x93a1a1
riverctl border-color-unfocused 0x586e75

# Set keyboard repeat rate
riverctl set-repeat 50 300

# Make all views with an app-id that starts with "float" and title "foo" start floating.
riverctl rule-add -app-id 'float*' -title 'foo' float

# Make all views with app-id "bar" and any title use client-side decorations
riverctl rule-add -app-id "bar" csd

# Set the default layout generator to be rivertile and start it.
# River will send the process group of the init executable SIGTERM on exit.
riverctl default-layout rivertile
rivertile -view-padding 6 -outer-padding 6 &
