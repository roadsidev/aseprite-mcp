"""Deterministic Spanish captions for the live feed: one template per tool."""


def _layer(a):
    name = a.get("layer_name") or a.get("target_layer_name")
    return f" en «{name}»" if name else ""


def _frame(a):
    f = a.get("frame_index")
    return f", frame {f}" if isinstance(f, int) else ""


def _range(a):
    s, e = a.get("start_frame"), a.get("end_frame")
    if isinstance(s, int) and isinstance(e, int):
        return f", frames {s}–{e}"
    return ""


def _rect(a):
    w, h = a.get("width"), a.get("height")
    return f" {w}×{h}" if isinstance(w, int) and isinstance(h, int) else ""


def _painted(a):
    legend = a.get("legend") or {}
    n = sum(1 for row in a.get("rows") or () for ch in row if ch in legend)
    return f"{n} {'píxel' if n == 1 else 'píxeles'}"


def _n(items, one, many):
    n = len(items or [])
    return f"{n} {one if n == 1 else many}"


TEMPLATES = {
    "create_canvas": lambda a: f"Lienzo nuevo de {a.get('width')}×{a.get('height')}",
    "add_layer": lambda a: f"Capa nueva «{a.get('layer_name')}»",
    "add_group": lambda a: f"Grupo nuevo «{a.get('group_name')}»",
    "add_frame": lambda a: "Agrega un frame",
    "add_frames": lambda a: f"Agrega {a.get('count')} frames",
    "delete_frame": lambda a: f"Borra el frame {a.get('frame_index')}",
    "delete_layer": lambda a: f"Borra la capa «{a.get('layer_name')}»",
    "duplicate_layer": lambda a: f"Duplica «{a.get('layer_name')}» como «{a.get('new_name')}»",
    "rename_layer": lambda a: f"Renombra «{a.get('layer_name')}» a «{a.get('new_name')}»",
    "reorder_layer": lambda a: f"Mueve «{a.get('layer_name')}» a la posición {a.get('position')}",
    "merge_layer_down": lambda a: f"Fusiona «{a.get('layer_name')}» hacia abajo",
    "flatten_sprite": lambda a: "Aplana todas las capas",
    "set_layer_visibility": lambda a: f"{'Muestra' if a.get('visible') else 'Oculta'} «{a.get('layer_name')}»",
    "set_layer_opacity": lambda a: f"Opacidad {a.get('opacity')}{_layer(a)}",
    "set_layer_blend_mode": lambda a: f"Modo {a.get('mode')}{_layer(a)}",
    "set_cel_opacity": lambda a: f"Opacidad del cel {a.get('opacity')}{_layer(a)}{_frame(a)}",
    "set_cel_position": lambda a: f"Mueve el cel a ({a.get('x')}, {a.get('y')}){_layer(a)}{_frame(a)}",
    "create_cel": lambda a: f"Cel nuevo{_layer(a)}{_frame(a)}",
    "clear_cel": lambda a: f"Vacía el cel{_layer(a)}{_frame(a)}",
    "copy_cel": lambda a: f"Copia el cel {a.get('source_frame')} → {a.get('target_frame')}{_layer(a)}",
    "copy_frame": lambda a: f"Copia el frame {a.get('source_frame')} → {a.get('target_frame')}",
    "duplicate_frame_range": lambda a: f"Duplica{_range(a)} ×{a.get('times')}",
    "propagate_cels": lambda a: f"Propaga {_n(a.get('layer_names'), 'capa', 'capas')} desde el frame {a.get('source_frame')}{_range(a)}",
    "propagate_frame_to_range": lambda a: f"Propaga el frame {a.get('source_frame')}{_range(a)}",
    "draw_pixels": lambda a: f"Pinta {_n(a.get('pixels'), 'píxel', 'píxeles')}",
    "draw_pixels_at": lambda a: f"Pinta {_n(a.get('pixels'), 'píxel', 'píxeles')}{_layer(a)}{_frame(a)}",
    "draw_rows": lambda a: f"Pinta {_painted(a)}{_layer(a)}{_frame(a)}",
    "draw_line": lambda a: f"Línea {a.get('color')}",
    "draw_line_at": lambda a: f"Línea {a.get('color')}{_layer(a)}{_frame(a)}",
    "draw_path": lambda a: f"Trazo de {_n(a.get('points'), 'punto', 'puntos')}{_layer(a)}{_frame(a)}",
    "draw_polygon": lambda a: f"Polígono de {_n(a.get('points'), 'punto', 'puntos')}{_layer(a)}{_frame(a)}",
    "draw_rectangle": lambda a: f"Rectángulo{_rect(a)} {a.get('color')}",
    "draw_rectangle_at": lambda a: f"Rectángulo{_rect(a)} {a.get('color')}{_layer(a)}{_frame(a)}",
    "draw_circle": lambda a: f"Círculo de radio {a.get('radius')}",
    "draw_circle_at": lambda a: f"Círculo de radio {a.get('radius')}{_layer(a)}{_frame(a)}",
    "draw_ellipse_at": lambda a: f"Elipse {a.get('radius_x')}×{a.get('radius_y')}{_layer(a)}{_frame(a)}",
    "draw_iso_box": lambda a: f"Caja isométrica {a.get('w')}×{a.get('d')}×{a.get('h')}{_layer(a)}{_frame(a)}",
    "draw_text": lambda a: f"Texto «{a.get('text')}»{_layer(a)}{_frame(a)}",
    "fill_area": lambda a: f"Relleno {a.get('color')} desde ({a.get('x')}, {a.get('y')})",
    "fill_area_at": lambda a: f"Relleno {a.get('color')}{_layer(a)}{_frame(a)}",
    "erase_region": lambda a: f"Borra una región{_rect(a)}{_layer(a)}{_frame(a)}",
    "erase_color": lambda a: f"Borra el color {a.get('color')}{_layer(a)}{_frame(a)}",
    "move_region": lambda a: f"Mueve una región{_rect(a)}{_layer(a)}{_frame(a)}",
    "copy_region": lambda a: f"Copia una región{_rect(a)}{_layer(a)}{_frame(a)}",
    "replace_color": lambda a: f"Cambia {a.get('from_color')} → {a.get('to_color')}{_layer(a)}{_frame(a)}",
    "remap_colors_in_cel_range": lambda a: f"Recolorea {_n(a.get('mappings'), 'color', 'colores')}{_layer(a)}{_range(a)}",
    "invert_colors": lambda a: f"Invierte colores{_layer(a)}{_frame(a)}",
    "adjust_hsl": lambda a: f"Ajusta tono/saturación/luz{_layer(a)}{_frame(a)}",
    "adjust_hsl_native": lambda a: f"Ajusta tono/saturación/luz{_layer(a)}{_frame(a)}",
    "adjust_brightness_contrast": lambda a: f"Ajusta brillo y contraste{_layer(a)}{_frame(a)}",
    "apply_convolution": lambda a: f"Filtro {a.get('matrix')}{_layer(a)}{_frame(a)}",
    "apply_dither_gradient": lambda a: f"Degradado con dither {a.get('color_start')} → {a.get('color_end')}{_layer(a)}{_frame(a)}",
    "apply_dither_pattern": lambda a: f"Dither {a.get('color_a')} / {a.get('color_b')}{_layer(a)}{_frame(a)}",
    "apply_gradient_rect": lambda a: f"Degradado {a.get('color_start')} → {a.get('color_end')}{_layer(a)}{_frame(a)}",
    "outline_cel": lambda a: f"Contorno {a.get('color')}{_layer(a)}{_frame(a)}",
    "outline_native": lambda a: f"Contorno {a.get('color')}{_layer(a)}{_frame(a)}",
    "flip_layer": lambda a: f"Voltea {'horizontal' if str(a.get('direction', '')).startswith('h') else 'vertical'}{_layer(a)}{_frame(a)}",
    "rotate_layer": lambda a: f"Rota {a.get('angle')}°{_layer(a)}{_frame(a)}",
    "resize_canvas": lambda a: f"Lienzo a {a.get('width')}×{a.get('height')}",
    "crop_canvas": lambda a: f"Recorta a{_rect(a)}",
    "import_image_as_layer": lambda a: f"Importa una imagen como «{a.get('layer_name')}»",
    "set_palette": lambda a: f"Paleta de {_n(a.get('colors'), 'color', 'colores')}",
    "apply_palette_preset": lambda a: f"Paleta «{a.get('preset')}»",
    "quantize_to_palette": lambda a: f"Ajusta a la paleta{_layer(a)}{_range(a)}",
    "set_color_mode": lambda a: f"Modo de color {a.get('mode')}",
    "set_frame_duration": lambda a: f"Frame {a.get('frame_index')} dura {a.get('duration_ms')} ms",
    "set_frame_duration_all": lambda a: f"Todos los frames duran {a.get('duration_ms')} ms",
    "set_tag": lambda a: f"Tag «{a.get('name')}» {a.get('from_frame')}–{a.get('to_frame')}",
    "delete_tag": lambda a: f"Borra el tag «{a.get('name')}»",
    "offset_cel_positions": lambda a: f"Desplaza ({a.get('dx')}, {a.get('dy')}){_layer(a)}{_range(a)}",
    "oscillate_cel_positions": lambda a: f"Oscila{_layer(a)}{_range(a)}",
    "tween_cel_positions": lambda a: f"Interpola posición{_layer(a)}{_range(a)}",
    "tween_cel_positions_eased": lambda a: f"Interpola posición ({a.get('easing')}){_layer(a)}{_range(a)}",
    "tween_cel_opacity_eased": lambda a: f"Interpola opacidad ({a.get('easing')}){_layer(a)}{_range(a)}",
    "tween_cel_scale_eased": lambda a: f"Interpola escala ({a.get('easing')}){_layer(a)}{_range(a)}",
    "animation_sanitize": lambda a: f"Ordena la animación{_range(a)}",
    "ensure_layers_present": lambda a: f"Asegura {_n(a.get('layer_names'), 'capa', 'capas')}",
    "copy_layers_between_sprites": lambda a: f"Copia {_n(a.get('layer_names'), 'capa', 'capas')} entre sprites",
    "create_tilemap_layer": lambda a: f"Capa de tiles «{a.get('layer_name')}»",
    "draw_on_tile": lambda a: f"Pinta el tile {a.get('tile_index')}{_layer(a)}",
    "set_tiles": lambda a: f"Coloca {_n(a.get('tiles'), 'tile', 'tiles')}{_layer(a)}{_frame(a)}",
    "create_slice": lambda a: f"Slice «{a.get('name')}»",
}


def caption(tool: str, arguments: dict) -> str:
    template = TEMPLATES.get(tool)
    if template is None:
        return tool.replace("_", " ").capitalize()
    try:
        return template(arguments)
    except Exception:
        return tool.replace("_", " ").capitalize()
