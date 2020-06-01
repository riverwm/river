#!/bin/sh

# Use the "logo" key as the primary modifier
mod="Mod4"

# Mod+Shift+Return to start an instance of alacritty
riverctl map normal $mod+Shift Return spawn alacritty

# Mod+Q to close the focused view
riverctl map normal $mod Q close

# Mod+E to exit river
riverctl map normal $mod E exit

# Mod+J and Mod+K to focus the next/previous view in the layout stack
riverctl map normal $mod J focus next
riverctl map normal $mod K focus previous

# Mod+Period and Mod+Comma to focus the next/previous output
riverctl map normal $mod Period focus-output next
riverctl map normal $mod Comma focus-output previous

# Mod+Shift+{Period,Comma} to send the focused view to the next/previous output
riverctl map normal $mod+Shift Period send-to-output next
riverctl map normal $mod+Shift Comma send-to-output previous

# Mod+Return to bump the focused view to the top of the layout stack, making
# it the new master
riverctl map normal $mod Return zoom

# Mod+H and Mod+L to decrease/increase the width of the master column by 5%
riverctl map normal $mod H mod-master-factor -0.05
riverctl map normal $mod L mod-master-factor +0.05

# Mod+Shift+H and Mod+Shift+L to increment/decrement the number of
# master views in the layout
riverctl map normal $mod+Shift H mod-master-count +1
riverctl map normal $mod+Shift L mod-master-count -1

for i in $(seq 1 9); do
    # Mod+[1-9] to focus tag [1-9]
    riverctl map normal $mod $i focus-tag $i

    # Mod+Shift+[1-9] to tag focused view with tag [1-9]
    riverctl map normal $mod+Shift $i tag-view $i

    # Mod+Ctrl+[1-9] to toggle focus of tag [1-9]
    riverctl map normal $mod+Control $i toggle-tag-focus $i

    # Mod+Shift+Ctrl+[1-9] to toggle tag [1-9] of focused view
    riverctl map normal $mod+Shift+Control $i toggle-view-tag $i
done

# Mod+0 to focus all tags
riverctl map normal $mod 0 focus-all-tags

# Mod+Shift+0 to tag focused view with all tags
riverctl map normal $mod+Shift 0 tag-view-all-tags

# Mod+Space to toggle float
riverctl map normal $mod Space toggle-float

# Mod+{Up,Right,Down,Left} to change master orientation
riverctl map normal $mod Up layout top-master
riverctl map normal $mod Right layout right-master
riverctl map normal $mod Down layout bottom-master
riverctl map normal $mod Left layout left-master

# Mod+f to change to Full layout
riverctl map normal $mod F layout full

# Declare a passthrough mode. This mode has only a single mapping to return to
# normal mode. This makes it useful for testing a nested wayland compositor
riverctl declare-mode passthrough

# Mod+F11 to enter passthrough mode
riverctl map normal $mod F11 enter-mode passthrough

# Mod+F11 to return to normal mode
riverctl map passthrough $mod F11 enter-mode normal
