class_name TuningGUI
extends Control

## Runtime interactive GUI panel for dynamically tuning atmosphere, sun, and cloud parameters.
## Supports real-time two-way synchronization, preset selection, collapse/expand, and [Tab] toggle.

const CloudController = preload("res://scripts/atmosphere_cloud_controller.gd")

@export var controller: Node

var _panel_container: PanelContainer
var _scroll_container: ScrollContainer
var _vbox_content: VBoxContainer
var _toggle_button: Button
var _is_collapsed: bool = false
var _is_user_dragging: bool = false

var _slider_entries: Array[Dictionary] = []
var _time_slider: HSlider
var _time_label: Label
var _animate_button: Button
var _weather_option: OptionButton
var _perf_option: OptionButton
var _time_slider_entry: Dictionary

# Cached initial defaults
var _saved_defaults: Dictionary = {}

func _ready() -> void:
	# Ignore clicks on empty areas of CanvasLayer
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	
	if not controller:
		controller = get_node_or_null("../../AtmosphereCloudController")
		if not controller:
			controller = get_tree().root.find_child("AtmosphereCloudController", true, false)
			
	_cache_defaults()
	_build_ui()
	_sync_all_from_controller()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB:
			_toggle_collapse()
			get_viewport().set_input_as_handled()

func _cache_defaults() -> void:
	if not controller:
		return
	_saved_defaults = {
		"time_of_day": controller.time_of_day,
		"sun_latitude": controller.sun_latitude,
		"sun_intensity": controller.sun_intensity,
		"cloud_coverage": controller.cloud_coverage,
		"cloud_density": controller.cloud_density,
		"cloud_scale": controller.cloud_scale,
		"cloud_bottom_altitude": controller.cloud_bottom_altitude,
		"cloud_thickness": controller.cloud_thickness,
		"detail_fluffiness": controller.detail_fluffiness,
		"cloud_curvature_radius_km": controller.cloud_curvature_radius_km,
		"satellite_cloud_amount": controller.satellite_cloud_amount,
		"zenith_sky_clearance": controller.zenith_sky_clearance,
		"silver_lining": controller.silver_lining,
		"wind_speed_kmh": controller.wind_speed_kmh,
		"wind_heading_degrees": controller.wind_heading_degrees,
		"weather_preset": controller.weather_preset,
		"performance_mode": controller.performance_mode
	}

func _build_ui() -> void:
	# Main Panel Container
	_panel_container = PanelContainer.new()
	_panel_container.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel_container.anchor_left = 1.0
	_panel_container.anchor_right = 1.0
	_panel_container.anchor_top = 0.0
	_panel_container.anchor_bottom = 0.0
	_panel_container.offset_left = -370.0
	_panel_container.offset_right = -16.0
	_panel_container.offset_top = 16.0
	_panel_container.offset_bottom = 720.0
	
	# Dark Translucent Glass Style
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.09, 0.13, 0.88)
	style.border_color = Color(0.24, 0.38, 0.55, 0.70)
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.shadow_color = Color(0, 0, 0, 0.45)
	style.shadow_size = 12
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	_panel_container.add_theme_stylebox_override("panel", style)
	add_child(_panel_container)
	
	var main_vbox = VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 8)
	_panel_container.add_child(main_vbox)
	
	# Top Header
	var header_hbox = HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 8)
	main_vbox.add_child(header_hbox)
	
	var title_label = Label.new()
	title_label.text = "☁ Sky & Cloud Controls"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.add_theme_font_size_override("font_size", 15)
	title_label.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
	header_hbox.add_child(title_label)
	
	_toggle_button = Button.new()
	_toggle_button.text = "[-]"
	_toggle_button.focus_mode = Control.FOCUS_NONE
	_toggle_button.pressed.connect(_toggle_collapse)
	header_hbox.add_child(_toggle_button)
	
	# Scrollable Area for all Controls
	_scroll_container = ScrollContainer.new()
	_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	main_vbox.add_child(_scroll_container)
	
	_vbox_content = VBoxContainer.new()
	_vbox_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox_content.add_theme_constant_override("separation", 10)
	_scroll_container.add_child(_vbox_content)
	
	# --- SECTION 1: PRESETS ---
	_add_section_header("PRESETS & QUALITY")
	
	var preset_grid = GridContainer.new()
	preset_grid.columns = 2
	preset_grid.add_theme_constant_override("h_separation", 8)
	preset_grid.add_theme_constant_override("v_separation", 6)
	_vbox_content.add_child(preset_grid)
	
	# Weather Preset
	var weather_lbl = Label.new()
	weather_lbl.text = "Weather Preset:"
	weather_lbl.add_theme_font_size_override("font_size", 12)
	preset_grid.add_child(weather_lbl)
	
	_weather_option = OptionButton.new()
	_weather_option.focus_mode = Control.FOCUS_NONE
	_weather_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for key in CloudController.WeatherPreset.keys():
		_weather_option.add_item(key.capitalize().replace("_", " "))
	_weather_option.item_selected.connect(_on_weather_preset_selected)
	preset_grid.add_child(_weather_option)
	
	# Performance Mode
	var perf_lbl = Label.new()
	perf_lbl.text = "Performance Mode:"
	perf_lbl.add_theme_font_size_override("font_size", 12)
	preset_grid.add_child(perf_lbl)
	
	_perf_option = OptionButton.new()
	_perf_option.focus_mode = Control.FOCUS_NONE
	_perf_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for key in CloudController.PerformanceMode.keys():
		_perf_option.add_item(key.capitalize())
	_perf_option.item_selected.connect(_on_performance_mode_selected)
	preset_grid.add_child(_perf_option)
	
	# --- SECTION 2: TIME & SUN ---
	_add_section_header("TIME & SUNLIGHT")
	
	# Time of day row with Play/Pause button
	var time_entry = _add_slider_row("Time of Day", 0.0, 24.0, 0.05, 12.95, "time", func(val):
		if controller: controller.time_of_day = val
	)
	_time_slider = time_entry.slider
	_time_label = time_entry.label
	_time_slider_entry = time_entry
	
	var anim_hbox = HBoxContainer.new()
	_vbox_content.add_child(anim_hbox)
	
	_animate_button = Button.new()
	_animate_button.text = "▶ Play Time"
	_animate_button.focus_mode = Control.FOCUS_NONE
	_animate_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_animate_button.pressed.connect(func():
		if controller:
			controller.animate_time = !controller.animate_time
			_animate_button.text = "⏸ Pause Time" if controller.animate_time else "▶ Play Time"
	)
	anim_hbox.add_child(_animate_button)
	
	_add_slider_row("Sun Latitude", -90.0, 90.0, 1.0, 35.0, "%.1f°", func(val):
		if controller: controller.sun_latitude = val
	)
	_add_slider_row("Sun Intensity", 0.0, 50.0, 0.5, 24.0, "%.1f", func(val):
		if controller: controller.sun_intensity = val
	)
	
	# --- SECTION 3: CLOUD APPEARANCE ---
	_add_section_header("CLOUD APPEARANCE")
	
	_add_slider_row("Cloud Coverage", 0.0, 1.0, 0.01, 0.36, "%.2f", func(val):
		if controller: controller.cloud_coverage = val
	)
	_add_slider_row("Cloud Density", 0.1, 3.0, 0.05, 0.70, "%.2f", func(val):
		if controller: controller.cloud_density = val
	)
	_add_slider_row("Cloud Scale", 0.05, 1.0, 0.01, 0.28, "%.2f", func(val):
		if controller: controller.cloud_scale = val
	)
	_add_slider_row("Base Altitude", 500.0, 4000.0, 50.0, 1000.0, "%.0f m", func(val):
		if controller: controller.cloud_bottom_altitude = val
	)
	_add_slider_row("Cloud Thickness", 500.0, 7000.0, 50.0, 6000.0, "%.0f m", func(val):
		if controller: controller.cloud_thickness = val
	)
	_add_slider_row("Detail Fluffiness", 0.0, 1.0, 0.01, 0.26, "%.2f", func(val):
		if controller: controller.detail_fluffiness = val
	)
	_add_slider_row("Curvature Radius", 50.0, 1000.0, 10.0, 100.0, "%.0f km", func(val):
		if controller: controller.cloud_curvature_radius_km = val
	)
	_add_slider_row("Satellite Clouds", 0.0, 1.0, 0.05, 0.80, "%.2f", func(val):
		if controller: controller.satellite_cloud_amount = val
	)
	_add_slider_row("Zenith Clearance", 0.0, 1.0, 0.05, 0.30, "%.2f", func(val):
		if controller: controller.zenith_sky_clearance = val
	)
	_add_slider_row("Silver Lining", 0.0, 5.0, 0.1, 2.4, "%.1f", func(val):
		if controller: controller.silver_lining = val
	)
	
	# --- SECTION 4: WIND ---
	_add_section_header("WIND & DYNAMICS")
	
	_add_slider_row("Wind Speed", 0.0, 100.0, 1.0, 25.0, "%.1f km/h", func(val):
		if controller: controller.wind_speed_kmh = val
	)
	_add_slider_row("Wind Heading", 0.0, 360.0, 5.0, 60.0, "%.0f°", func(val):
		if controller: controller.wind_heading_degrees = val
	)
	
	# --- SECTION 5: FOOTER ACTIONS ---
	_add_section_header("ACTIONS")
	
	var reset_btn = Button.new()
	reset_btn.text = "↺ Reset to Saved Settings"
	reset_btn.focus_mode = Control.FOCUS_NONE
	reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_btn.pressed.connect(_reset_to_saved_defaults)
	_vbox_content.add_child(reset_btn)
	
	var hint_lbl = Label.new()
	hint_lbl.text = "Tip: Press [Tab] to toggle UI | Hold RMB to look"
	hint_lbl.add_theme_font_size_override("font_size", 11)
	hint_lbl.add_theme_color_override("font_color", Color(0.65, 0.75, 0.85, 0.75))
	hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vbox_content.add_child(hint_lbl)

func _add_section_header(title: String) -> void:
	var sep = HSeparator.new()
	_vbox_content.add_child(sep)
	
	var lbl = Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.40, 0.70, 0.95, 0.90))
	_vbox_content.add_child(lbl)

func _add_slider_row(label_text: String, min_val: float, max_val: float, step_val: float, default_val: float, format_str: String, on_change: Callable) -> Dictionary:
	var row_vbox = VBoxContainer.new()
	row_vbox.add_theme_constant_override("separation", 2)
	_vbox_content.add_child(row_vbox)
	
	var label_hbox = HBoxContainer.new()
	row_vbox.add_child(label_hbox)
	
	var name_label = Label.new()
	name_label.text = label_text
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override("font_size", 12)
	label_hbox.add_child(name_label)
	
	var val_label = Label.new()
	val_label.text = _format_value(format_str, default_val)
	val_label.add_theme_font_size_override("font_size", 12)
	val_label.add_theme_color_override("font_color", Color(0.55, 0.90, 1.0))
	label_hbox.add_child(val_label)
	
	var slider = HSlider.new()
	slider.min_value = min_val
	slider.max_value = max_val
	slider.step = step_val
	slider.value = default_val
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.focus_mode = Control.FOCUS_NONE
	row_vbox.add_child(slider)
	
	var entry = {
		"name": label_text,
		"slider": slider,
		"label": val_label,
		"format": format_str,
		"on_change": on_change
	}
	_slider_entries.append(entry)
	
	slider.drag_started.connect(func(): _is_user_dragging = true)
	slider.drag_ended.connect(func(_val): _is_user_dragging = false)
	slider.value_changed.connect(func(new_val):
		val_label.text = _format_value(format_str, new_val)
		var is_user_action = _is_user_dragging or (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and slider.get_global_rect().has_point(get_global_mouse_position()))
		if is_user_action:
			on_change.call(new_val)
	)
	
	return entry

func _format_value(format_str: String, val: float) -> String:
	if format_str == "time":
		var h = int(val)
		var m = int(fposmod(val * 60.0, 60.0))
		return "%02d:%02d (%.2fh)" % [h, m, val]
	return format_str % val

func _toggle_collapse() -> void:
	_is_collapsed = !_is_collapsed
	if _is_collapsed:
		_scroll_container.visible = false
		_panel_container.offset_bottom = _panel_container.offset_top + 48.0
		_panel_container.offset_left = -170.0
		_toggle_button.text = "[+] Tuning"
	else:
		_scroll_container.visible = true
		_panel_container.offset_bottom = minf(get_viewport_rect().size.y - 20.0, 750.0)
		_panel_container.offset_left = -370.0
		_toggle_button.text = "[-]"

func _on_weather_preset_selected(index: int) -> void:
	if controller:
		controller.weather_preset = index
		_sync_all_from_controller()

func _on_performance_mode_selected(index: int) -> void:
	if controller:
		controller.performance_mode = index

func _reset_to_saved_defaults() -> void:
	if not controller or _saved_defaults.is_empty():
		return
	for key in _saved_defaults:
		controller.set(key, _saved_defaults[key])
	_sync_all_from_controller()

func _sync_all_from_controller() -> void:
	if not controller:
		return
	
	for entry in _slider_entries:
		var prop_name = _get_prop_name_for_label(entry.name)
		if prop_name != "" and prop_name in controller:
			var curr_val = controller.get(prop_name)
			entry.slider.set_value_no_signal(curr_val)
			entry.label.text = _format_value(entry.format, curr_val)
			
	if _weather_option:
		_weather_option.selected = controller.weather_preset
	if _perf_option:
		_perf_option.selected = controller.performance_mode
	if _animate_button:
		_animate_button.text = "⏸ Pause Time" if controller.animate_time else "▶ Play Time"

func _get_prop_name_for_label(lbl_text: String) -> String:
	match lbl_text:
		"Time of Day": return "time_of_day"
		"Sun Latitude": return "sun_latitude"
		"Sun Intensity": return "sun_intensity"
		"Cloud Coverage": return "cloud_coverage"
		"Cloud Density": return "cloud_density"
		"Cloud Scale": return "cloud_scale"
		"Base Altitude": return "cloud_bottom_altitude"
		"Cloud Thickness": return "cloud_thickness"
		"Detail Fluffiness": return "detail_fluffiness"
		"Curvature Radius": return "cloud_curvature_radius_km"
		"Satellite Clouds": return "satellite_cloud_amount"
		"Zenith Clearance": return "zenith_sky_clearance"
		"Silver Lining": return "silver_lining"
		"Wind Speed": return "wind_speed_kmh"
		"Wind Heading": return "wind_heading_degrees"
	return ""

func _process(_delta: float) -> void:
	if not controller or _is_collapsed:
		return
		
	# Sync animate button text if state toggled via Space
	if _animate_button:
		var expected = "⏸ Pause Time" if controller.animate_time else "▶ Play Time"
		if _animate_button.text != expected:
			_animate_button.text = expected
			
	# Update Time slider smoothly if time is animating or changed via keys
	if not _is_user_dragging and _time_slider:
		if abs(_time_slider.value - controller.time_of_day) > 0.005:
			_time_slider.set_value_no_signal(controller.time_of_day)
			_time_label.text = _format_value("time", controller.time_of_day)
			
	# Sync weather preset option if flipped via hotkeys or parameter tweak
	if _weather_option and _weather_option.selected != controller.weather_preset:
		_weather_option.selected = controller.weather_preset
		
	# If not user dragging, keep other sliders in sync with controller if hotkeys modified them
	if not _is_user_dragging:
		for entry in _slider_entries:
			if entry.name == "Time of Day": continue
			var prop_name = _get_prop_name_for_label(entry.name)
			if prop_name != "" and prop_name in controller:
				var curr_val = controller.get(prop_name)
				if abs(entry.slider.value - curr_val) > 0.001:
					entry.slider.set_value_no_signal(curr_val)
					entry.label.text = _format_value(entry.format, curr_val)
