# SPDX-License-Identifier: GPL-2.0-or-later
"""
iPhone Duo support for Blender.

Fold: two editors that meet exactly at the crease, top/bottom in the laptop pose and left/right in
the book pose, applied automatically when the phone is partly folded. Mirror: show Blender on the
outer display too. The iOS side (GHOST) reports the hinge and crease in duo_fold_state.txt and
reads duo_mirror_request.txt, both in the app's temporary folder.
"""

import os
import tempfile

import bpy
from bpy.props import BoolProperty, EnumProperty, FloatProperty, PointerProperty, StringProperty

FOLD_WORKSPACE = "Duo Fold"
STATE_FILE = "duo_fold_state.txt"
MIRROR_FILE = "duo_mirror_request.txt"

# UIHingeStatus
HINGE_UNKNOWN, HINGE_CLOSED, HINGE_PARTIAL, HINGE_OPEN = range(4)

EDITORS = [
    ('VIEW_3D', "3D Viewport", "", 'VIEW3D', 0),
    ('PROPERTIES', "Properties", "", 'PROPERTIES', 1),
    ('OUTLINER', "Outliner", "", 'OUTLINER', 2),
    ('ShaderNodeTree', "Shader Editor", "", 'NODE_MATERIAL', 3),
    ('GeometryNodeTree', "Geometry Nodes", "", 'GEOMETRY_NODES', 4),
    ('IMAGE_EDITOR', "Image Editor", "", 'IMAGE', 5),
    ('UV', "UV Editor", "", 'UV', 6),
    ('TIMELINE', "Timeline", "", 'TIME', 7),
    ('DOPESHEET', "Dope Sheet", "", 'ACTION', 8),
    ('FCURVES', "Graph Editor", "", 'GRAPH', 9),
    ('TEXT_EDITOR', "Text Editor", "", 'TEXT', 10),
    ('ASSETS', "Asset Browser", "", 'ASSET_MANAGER', 11),
]


def _tmp(name):
    return os.path.join(os.environ.get("TMPDIR") or tempfile.gettempdir(), name)


def read_state():
    """Parse the state the iOS side writes. Missing values stay None."""
    state = {"hinge": None, "angle": None, "crease": None, "mirror_on": False,
             "mirror_available": False}
    try:
        with open(_tmp(STATE_FILE)) as f:
            lines = f.read().splitlines()
    except OSError:
        return state
    for line in lines:
        parts = line.split()
        if not parts:
            continue
        try:
            if parts[0] == "hinge" and len(parts) >= 3:
                state["hinge"] = int(parts[1])
                state["angle"] = float(parts[2])
            elif parts[0] == "crease" and len(parts) >= 7:
                state["crease"] = {
                    "across": parts[1] == "across",
                    "x": float(parts[2]), "y": float(parts[3]),
                    "w": float(parts[4]), "h": float(parts[5]),
                    "active": parts[6] == "1",
                }
            elif parts[0] == "mirror" and len(parts) >= 3:
                state["mirror_on"] = parts[1] == "1"
                state["mirror_available"] = parts[2] == "1"
        except ValueError:
            pass
    return state


def _write_mirror(on):
    try:
        with open(_tmp(MIRROR_FILE), "w") as f:
            f.write("1" if on else "0")
    except OSError:
        pass


class DuoFoldSettings(bpy.types.PropertyGroup):
    top: EnumProperty(name="Top / left half",
                      description="Editor on the top half (laptop pose) or the left half (book pose)",
                      items=EDITORS, default='VIEW_3D')
    bottom: EnumProperty(name="Bottom / right half",
                         description="Editor on the bottom half (laptop pose) or the right half (book pose)",
                         items=EDITORS, default='PROPERTIES')
    automatic: BoolProperty(
        name="Automatic",
        description="Fold the layout when the phone is partly folded, unfold it when opened flat",
        default=True)
    crease_offset: FloatProperty(
        name="Seam nudge",
        description="Move the seam off the crease reported by iOS, as a fraction of the window",
        default=0.0, min=-0.1, max=0.1, subtype='FACTOR')
    mirror: BoolProperty(
        name="Mirror on outer display",
        description="Show Blender on the outer display too. iOS only allows this while the camera "
                    "is running, so the camera indicator stays on and battery use goes up",
        default=False,
        update=lambda self, context: _write_mirror(self.mirror))
    previous_workspace: StringProperty()
    applied: StringProperty(description="Orientation of the layout last applied")


def _settings(context):
    return context.window_manager.duo_fold


def _window_region(area):
    return next((r for r in area.regions if r.type == 'WINDOW'), area.regions[0])


def _close_all_but(context, window, screen, keep):
    """Close every area except `keep` so it fills the window."""
    for _attempt in range(64):
        others = [a for a in screen.areas if a != keep]
        if not others:
            return True
        area = others[0]
        with context.temp_override(window=window, screen=screen, area=area, region=_window_region(area)):
            if bpy.ops.screen.area_close() != {'FINISHED'}:
                return False
    return len(screen.areas) == 1


def _crease(window, settings):
    """Crease orientation and position in window pixels: (across, position). `across` means the
    crease runs side to side (laptop pose: top and bottom halves)."""
    crease = read_state()["crease"]
    if crease is not None:
        across = crease["across"]
        frac = crease["y"] if across else crease["x"]
    else:
        # No hinge data (not an iPhone Duo, or an older iOS): split the longer side in half.
        across = window.height > window.width
        frac = 0.5
    frac += settings.crease_offset
    if across:
        return True, window.height * (1.0 - frac)  # window y counts from the bottom
    return False, window.width * frac


def _split_at_crease(context, window, screen, area, settings):
    """Split `area` so the seam lands on the crease. Returns (first, second, across)."""
    across, crease = _crease(window, settings)
    direction = 'HORIZONTAL' if across else 'VERTICAL'

    def pos(a):
        return a.y if across else a.x

    def size(a):
        return a.height if across else a.width

    factor = min(max((crease - pos(area)) / max(size(area), 1), 0.1), 0.9)
    with context.temp_override(window=window, screen=screen, area=area, region=_window_region(area)):
        bpy.ops.screen.area_split(direction=direction, factor=factor)
    areas = sorted(screen.areas, key=pos)
    if len(areas) != 2:
        return None, None, across
    low, high = areas
    # Move the seam exactly onto the crease (area_split rounds, and may count from either edge).
    seam = pos(high)
    delta = int(round(crease - seam))
    if delta:
        mid_other = (low.x + low.width // 2) if across else (low.y + low.height // 2)
        x, y = (mid_other, seam) if across else (seam, mid_other)
        with context.temp_override(window=window, screen=screen, area=low, region=_window_region(low)):
            try:
                bpy.ops.screen.area_move(x=int(x), y=int(y), delta=delta)
            except RuntimeError as ex:
                print("iPhone Duo fold: could not move the seam:", ex)
        low, high = sorted(screen.areas, key=pos)
    # Top half first in the laptop pose (higher y); left half first in the book pose (lower x).
    return ((high, low) if across else (low, high)) + (across,)


def fold(context, window):
    settings = _settings(context)
    if window.workspace.name != FOLD_WORKSPACE:
        settings.previous_workspace = window.workspace.name
    workspace = bpy.data.workspaces.get(FOLD_WORKSPACE)
    if workspace is None:
        with context.temp_override(window=window):
            bpy.ops.workspace.duplicate()
        window.workspace.name = FOLD_WORKSPACE
    else:
        window.workspace = workspace
    screen = window.screen
    keep = max(screen.areas, key=lambda a: a.width * a.height)
    if not _close_all_but(context, window, screen, keep):
        return "Could not clear the layout"
    first, second, across = _split_at_crease(context, window, screen, keep, settings)
    if first is None:
        return "Could not split at the crease"
    first.ui_type = settings.top
    second.ui_type = settings.bottom
    settings.applied = "across" if across else "down"
    return None


def unfold(context, window):
    settings = _settings(context)
    previous = bpy.data.workspaces.get(settings.previous_workspace) if settings.previous_workspace else None
    if previous is None:
        previous = next((w for w in bpy.data.workspaces if w.name != FOLD_WORKSPACE), None)
    if previous is not None:
        window.workspace = previous
    settings.applied = ""


class DUO_OT_fold(bpy.types.Operator):
    """Lay out two editors that meet at the iPhone Duo's crease"""
    bl_idname = "duo.fold"
    bl_label = "Fold Layout"

    def execute(self, context):
        error = fold(context, context.window)
        if error:
            self.report({'WARNING'}, error)
            return {'CANCELLED'}
        return {'FINISHED'}


class DUO_OT_unfold(bpy.types.Operator):
    """Go back to the workspace you used before folding"""
    bl_idname = "duo.unfold"
    bl_label = "Unfold Layout"

    def execute(self, context):
        unfold(context, context.window)
        return {'FINISHED'}


class DUO_OT_swap(bpy.types.Operator):
    """Swap the editors on the two halves"""
    bl_idname = "duo.swap"
    bl_label = "Swap Halves"

    def execute(self, context):
        settings = _settings(context)
        settings.top, settings.bottom = settings.bottom, settings.top
        if context.window.workspace.name == FOLD_WORKSPACE:
            fold(context, context.window)
        return {'FINISHED'}


class DUO_PT_fold(bpy.types.Panel):
    bl_label = "iPhone Duo"
    bl_space_type = 'TOPBAR'
    bl_region_type = 'HEADER'
    bl_ui_units_x = 13

    def draw(self, context):
        layout = self.layout
        settings = _settings(context)
        state = read_state()
        crease = state["crease"]
        across = crease["across"] if crease else context.window.height > context.window.width
        col = layout.column()
        col.prop(settings, "top", text="Top" if across else "Left")
        col.prop(settings, "bottom", text="Bottom" if across else "Right")
        col.operator("duo.swap", icon='UV_SYNC_SELECT')
        col.prop(settings, "automatic")
        col.prop(settings, "crease_offset", slider=True)
        row = col.row(align=True)
        row.scale_y = 1.4
        row.operator("duo.fold", text="Fold", icon='SPLIT_HORIZONTAL' if across else 'SPLIT_VERTICAL')
        row.operator("duo.unfold", text="Unfold", icon='FULLSCREEN_ENTER')
        col.separator()
        col.prop(settings, "mirror")
        if settings.mirror:
            if not state["mirror_on"]:
                col.label(text="Starting the camera...", icon='TIME')
            elif not state["mirror_available"]:
                col.label(text="Waiting for iOS to offer the outer display", icon='INFO')
            else:
                col.label(text="Showing on the outer display", icon='CHECKMARK')
        hinge = {HINGE_CLOSED: "closed", HINGE_PARTIAL: "partly folded",
                 HINGE_OPEN: "open flat"}.get(state["hinge"], "unknown")
        angle = state["angle"]
        col.label(text=f"Hinge: {hinge}" + (f", {angle:.0f} degrees" if angle is not None and angle >= 0 else ""))


def draw_topbar(self, context):
    # The left part of the top bar is always on screen; the right part is cut off on a phone.
    if context.region.alignment == 'RIGHT':
        return
    folded = context.window.workspace.name == FOLD_WORKSPACE
    row = self.layout.row(align=True)
    row.operator("duo.unfold" if folded else "duo.fold",
                 text="Unfold" if folded else "Fold",
                 icon='FULLSCREEN_ENTER' if folded else 'SPLIT_HORIZONTAL')
    row.popover(panel="DUO_PT_fold", text="")


def draw_view_menu(self, context):
    layout = self.layout
    layout.separator()
    layout.operator("duo.fold", text="iPhone Duo: Fold Layout", icon='SPLIT_HORIZONTAL')
    layout.operator("duo.unfold", text="iPhone Duo: Unfold Layout", icon='FULLSCREEN_ENTER')
    layout.popover("DUO_PT_fold", text="iPhone Duo: Settings")


_last = {"hinge": None, "crease": None}


def _watch():
    """Follow the hinge: fold when partly folded, unfold when open flat, refold when the crease
    turns (book <-> laptop pose)."""
    try:
        wm = bpy.context.window_manager
        if wm is None or not wm.windows:
            return 0.5
        settings = wm.duo_fold
        state = read_state()
        crease = state["crease"]
        key = (crease["across"], round(crease["x"], 3), round(crease["y"], 3)) if crease else None
        changed = state["hinge"] != _last["hinge"] or key != _last["crease"]
        _last["hinge"], _last["crease"] = state["hinge"], key
        if not changed:
            return 0.4
        window = wm.windows[0]
        context = bpy.context
        with context.temp_override(window=window):
            folded = window.workspace.name == FOLD_WORKSPACE
            orientation = ("across" if crease["across"] else "down") if crease else None
            if settings.automatic and state["hinge"] == HINGE_PARTIAL:
                if not folded or settings.applied != orientation:
                    fold(context, window)
            elif settings.automatic and state["hinge"] in {HINGE_OPEN, HINGE_CLOSED} and folded:
                unfold(context, window)
            elif folded and orientation and settings.applied and settings.applied != orientation:
                fold(context, window)
    except Exception as ex:  # Never let the timer die.
        print("iPhone Duo fold:", ex)
    return 0.4


classes = (DuoFoldSettings, DUO_OT_fold, DUO_OT_unfold, DUO_OT_swap, DUO_PT_fold)


def register():
    for cls in classes:
        bpy.utils.register_class(cls)
    bpy.types.WindowManager.duo_fold = PointerProperty(type=DuoFoldSettings)
    bpy.types.TOPBAR_HT_upper_bar.prepend(draw_topbar)
    bpy.types.VIEW3D_MT_view.append(draw_view_menu)
    _write_mirror(False)
    bpy.app.timers.register(_watch, first_interval=2.0, persistent=True)
    print("iPhone Duo fold layout: ready (top bar, left; 3D Viewport > View menu)")


def unregister():
    if bpy.app.timers.is_registered(_watch):
        bpy.app.timers.unregister(_watch)
    bpy.types.TOPBAR_HT_upper_bar.remove(draw_topbar)
    bpy.types.VIEW3D_MT_view.remove(draw_view_menu)
    del bpy.types.WindowManager.duo_fold
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)
