# SPDX-License-Identifier: GPL-2.0-or-later
"""
iPhone Duo fold layout for Blender.

When the iPhone Duo is folded like a little laptop, the crease runs across the middle of the
screen. "Fold" lays the window out as two editors that meet exactly at the crease (one on the
upright half, one on the flat half) so nothing is drawn across the bend. "Unfold" goes back to the
workspace you were using. Pick the editor for each half from the Fold menu in the top bar.
"""

import bpy
from bpy.props import EnumProperty, StringProperty, FloatProperty, PointerProperty

FOLD_WORKSPACE = "Duo Fold"

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


class DuoFoldSettings(bpy.types.PropertyGroup):
    top: EnumProperty(name="Top half", description="Editor on the upright half",
                      items=EDITORS, default='VIEW_3D')
    bottom: EnumProperty(name="Bottom half", description="Editor on the flat half",
                         items=EDITORS, default='PROPERTIES')
    crease: FloatProperty(
        name="Crease position",
        description="Where the fold is, as a fraction of the window height from the top",
        default=0.5, min=0.3, max=0.7, subtype='FACTOR')
    previous_workspace: StringProperty()


def _settings(context):
    return context.window_manager.duo_fold


def _close_all_but(context, window, screen, keep):
    """Close every area except `keep` so it fills the window."""
    for _attempt in range(64):
        others = [a for a in screen.areas if a != keep]
        if not others:
            return True
        area = others[0]
        region = next((r for r in area.regions if r.type == 'WINDOW'), area.regions[0])
        with context.temp_override(window=window, screen=screen, area=area, region=region):
            if bpy.ops.screen.area_close() != {'FINISHED'}:
                return False
    return len(screen.areas) == 1


def _split_at_crease(context, window, screen, area, crease_from_top):
    """Split `area` horizontally so the boundary lands on the crease. Returns (top, bottom)."""
    crease_y = window.height * (1.0 - crease_from_top)  # window coordinates count from the bottom
    factor = (crease_y - area.y) / max(area.height, 1)
    factor = min(max(factor, 0.1), 0.9)
    region = next((r for r in area.regions if r.type == 'WINDOW'), area.regions[0])
    with context.temp_override(window=window, screen=screen, area=area, region=region):
        bpy.ops.screen.area_split(direction='HORIZONTAL', factor=factor)
    areas = sorted(screen.areas, key=lambda a: a.y)
    if len(areas) != 2:
        return None, None
    bottom, top = areas[0], areas[1]
    # area_split's factor may count from the other edge: if the seam missed the crease, redo it.
    seam = top.y
    if abs(seam - crease_y) > window.height * 0.05:
        keep = top if top.height > bottom.height else bottom
        _close_all_but(context, window, screen, keep)
        region = next((r for r in keep.regions if r.type == 'WINDOW'), keep.regions[0])
        with context.temp_override(window=window, screen=screen, area=keep, region=region):
            bpy.ops.screen.area_split(direction='HORIZONTAL', factor=1.0 - factor)
        areas = sorted(screen.areas, key=lambda a: a.y)
        if len(areas) != 2:
            return None, None
        bottom, top = areas[0], areas[1]
    return top, bottom


class DUO_OT_fold(bpy.types.Operator):
    """Lay out two editors that meet at the iPhone Duo's crease"""
    bl_idname = "duo.fold"
    bl_label = "Fold Layout"
    bl_options = {'REGISTER'}

    def execute(self, context):
        settings = _settings(context)
        window = context.window
        current = window.workspace
        if current.name != FOLD_WORKSPACE:
            settings.previous_workspace = current.name

        workspace = bpy.data.workspaces.get(FOLD_WORKSPACE)
        if workspace is None:
            with context.temp_override(window=window):
                bpy.ops.workspace.duplicate()
            workspace = window.workspace
            workspace.name = FOLD_WORKSPACE
        else:
            window.workspace = workspace
        return self._layout(context, settings)

    def _layout(self, context, settings):
        window = context.window
        screen = window.screen
        if screen is None:
            return {'CANCELLED'}
        keep = max(screen.areas, key=lambda a: a.width * a.height)
        if not _close_all_but(context, window, screen, keep):
            self.report({'WARNING'}, "Could not clear the layout")
            return {'CANCELLED'}
        top, bottom = _split_at_crease(context, window, screen, keep, settings.crease)
        if top is None:
            self.report({'WARNING'}, "Could not split at the crease")
            return {'CANCELLED'}
        top.ui_type = settings.top
        bottom.ui_type = settings.bottom
        return {'FINISHED'}


class DUO_OT_unfold(bpy.types.Operator):
    """Go back to the workspace you used before folding"""
    bl_idname = "duo.unfold"
    bl_label = "Unfold Layout"

    def execute(self, context):
        settings = _settings(context)
        previous = bpy.data.workspaces.get(settings.previous_workspace) if settings.previous_workspace else None
        if previous is None:
            previous = next((w for w in bpy.data.workspaces if w.name != FOLD_WORKSPACE), None)
        if previous is not None:
            context.window.workspace = previous
        return {'FINISHED'}


class DUO_OT_swap(bpy.types.Operator):
    """Swap the editors on the two halves"""
    bl_idname = "duo.swap"
    bl_label = "Swap Halves"

    def execute(self, context):
        settings = _settings(context)
        settings.top, settings.bottom = settings.bottom, settings.top
        if context.window.workspace.name == FOLD_WORKSPACE:
            return bpy.ops.duo.fold()
        return {'FINISHED'}


class DUO_PT_fold(bpy.types.Panel):
    bl_label = "iPhone Duo Fold"
    bl_space_type = 'TOPBAR'
    bl_region_type = 'HEADER'
    bl_ui_units_x = 12

    def draw(self, context):
        layout = self.layout
        settings = _settings(context)
        col = layout.column()
        col.prop(settings, "top", text="Top")
        col.prop(settings, "bottom", text="Bottom")
        col.operator("duo.swap", icon='UV_SYNC_SELECT')
        col.prop(settings, "crease", slider=True)
        col.separator()
        row = col.row(align=True)
        row.scale_y = 1.4
        row.operator("duo.fold", text="Fold", icon='SPLIT_HORIZONTAL')
        row.operator("duo.unfold", text="Unfold", icon='FULLSCREEN_ENTER')


def draw_topbar(self, context):
    # The left part of the top bar (before the File menu) is always on screen; the right part is
    # cut off on a phone.
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
    layout.popover("DUO_PT_fold", text="iPhone Duo: Fold Settings")


classes = (DuoFoldSettings, DUO_OT_fold, DUO_OT_unfold, DUO_OT_swap, DUO_PT_fold)


def register():
    for cls in classes:
        bpy.utils.register_class(cls)
    bpy.types.WindowManager.duo_fold = PointerProperty(type=DuoFoldSettings)
    bpy.types.TOPBAR_HT_upper_bar.prepend(draw_topbar)
    bpy.types.VIEW3D_MT_view.append(draw_view_menu)
    print("iPhone Duo fold layout: ready (top bar, left; 3D Viewport > View menu)")


def unregister():
    bpy.types.TOPBAR_HT_upper_bar.remove(draw_topbar)
    bpy.types.VIEW3D_MT_view.remove(draw_view_menu)
    del bpy.types.WindowManager.duo_fold
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)
