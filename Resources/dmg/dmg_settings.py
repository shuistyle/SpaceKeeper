# ======================================================================
# dmg_settings.py - how the SpaceKeeper installer window looks
# ======================================================================
# Read by dmgbuild (run from make_release.sh). It describes the window you
# see when you open SpaceKeeper-x.y.z.dmg:
#
#      Install SpaceKeeper
#      Drag the SpaceKeeper icon onto the Applications folder.
#
#      [SpaceKeeper]  ------->  [Applications]
#      ----------------------------------------
#      Opening it for the first time?
#      [First time opening SpaceKeeper.pdf]
#
# The words and arrow are part of background.png (drawn by
# artwork/background.py); the icon positions below line up with them.
# make_release.sh passes in: -D app=<path to SpaceKeeper.app> -D here=<this folder>
# ======================================================================
import os

app = defines["app"]    # noqa: F821  (dmgbuild provides "defines")
here = defines["here"]  # noqa: F821  (this folder, Resources/dmg)
app_name = os.path.basename(app)
guide = os.path.join(here, "First time opening SpaceKeeper.pdf")

format = "UDZO"            # compressed, opens on every supported macOS
filesystem = "HFS+"
size = None                # work it out from the contents

files = [app, guide]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]

icon = os.path.join(here, "..", "AppIcon.icns")   # the disk's own icon
background = os.path.join(here, "background.png")  # background@2x.png is used on Retina screens

# Window: 680 x 480 points, no toolbar or sidebar, big icons.
window_rect = ((200, 140), (680, 480))
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_tab_view = False
show_pathbar = False
default_view = "icon-view"
icon_size = 112
text_size = 14
arrange_by = None
icon_locations = {
    app_name: (180, 190),
    "Applications": (500, 190),
    "First time opening SpaceKeeper.pdf": (340, 385),
}
