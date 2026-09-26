"""Finder layout written directly to .DS_Store by dmgbuild, including Retina artwork."""
import os

root = defines["root"]
files = [os.path.join(root, "build", "ELTransfer.app")]
symlinks = {"Applications": "/Applications"}
background = defines["background"]
format = "UDZO"
filesystem = "HFS+"
window_rect = ((100, 80), (820, 660))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 14
arrange_by = None
scroll_position = (0, 0)
icon_locations = {
    "ELTransfer.app": (220, 252),
    "Applications": (600, 252),
    # Keep every icon inside the viewport, even when hidden files are shown.
    ".background.tiff": (90, 252),
    ".DS_Store": (730, 252),
    ".fseventsd": (730, 110),
}
