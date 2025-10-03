extends Node2D

# --- Configuration Constants ---
const PADDING = 50.0 
const FALLBACK_VIEWPORT_SIZE = Vector2(1024.0, 600.0)
const MIN_ZOOM = 0.5
const MAX_ZOOM = 3.0
const ZOOM_FACTOR = 1.1 
const PAN_BUTTON = MOUSE_BUTTON_RIGHT # Right click for pan
const PAN_SPEED = 1.0 
const ZOOM_SMOOTH_SPEED = 10.0 

# Internal variables for calculated transform
var calculated_scale = 1.0
var calculated_offset = Vector2.ZERO
# var owner_colors: Dictionary = {} # REMOVED: Owner coloring moved to external file/system

# Camera Control State
var is_panning = false
var last_mouse_position = Vector2.ZERO 
var camera: Camera2D = null 
var target_zoom = Vector2(1.0, 1.0) 

const DEFAULT_PROVINCE_DATA = {
	"name": "Unnamed Province",
	"owner": "Neutral", # The default owner reference
	"supply": 10,
	"units": 0
}

# ----------------------------------------------------------------------
## Initialization and Map Loading
# ----------------------------------------------------------------------

func _ready():
	# Standard Camera2D Initialization
	camera = Camera2D.new()
	add_child(camera)
	camera.make_current()
	
	# Set up for a smooth, immediate snap on load, followed by smooth panning
	camera.position_smoothing_enabled = false
	camera.zoom = Vector2(1.0, 1.0)
	
	load_map("res://map.json")
	
	target_zoom = camera.zoom 
	
	# Re-enable smoothing now that the camera is at the correct position.
	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 8.0 

# ----------------------------------------------------------------------
## Zoom Smoothing
# ----------------------------------------------------------------------

func _process(delta):
	if camera and camera.zoom != target_zoom:
		# Smoothly interpolate the camera's zoom towards the target zoom
		camera.zoom = camera.zoom.lerp(target_zoom, delta * ZOOM_SMOOTH_SPEED)


# --- Map Loading and Parsing ---

func load_map(path: String) -> void:
	"""Loads, parses, transforms, and draws the map geometry from a GeoJSON file."""
	if not FileAccess.file_exists(path):
		push_error("Error: Map file not found at: " + path)
		return

	var file = FileAccess.open(path, FileAccess.READ)
	var json_text = file.get_as_text()
	file.close()

	var data = JSON.parse_string(json_text)

	if typeof(data) != TYPE_DICTIONARY or data == null or not data.has("features"):
		push_error("Error: Failed to parse valid GeoJSON data.")
		return

	var features = data["features"]

	# 1. Calculate the necessary scale and offset based on map bounds
	calculate_and_set_transform(features)
	
	# 2. Draw Provinces (Delegate to the drawing function)
	_draw_provinces(features) # Simplified call flow

func _draw_provinces(features: Array) -> void:
	"""Iterates through all GeoJSON features and creates Area2D nodes for them."""
	for feature in features:
		if feature == null: continue # ROBUSTNESS CHECK: Skip null feature
		
		var geometry = feature.get("geometry", {})
		var properties = feature.get("properties", {})
		
		# Skip if geometry is missing or null
		if geometry == null or not geometry.has("type"): continue

		if geometry.get("type") == "Polygon":
			create_province(geometry["coordinates"], properties)
		elif geometry.get("type") == "MultiPolygon":
			for polygon_coords in geometry["coordinates"]:
				create_province(polygon_coords, properties)

# ----------------------------------------------------------------------
## Automated Transform Calculation
# ----------------------------------------------------------------------

func get_map_bounds(features: Array) -> Rect2:
	var min_lon = INF
	var max_lon = -INF
	var min_lat = INF
	var max_lat = -INF

	for feature in features:
		if feature == null: continue # ROBUSTNESS CHECK: Skip null feature
		
		# If the GeoJSON has {"geometry": null}, feature.get("geometry", {}) will return {}.
		# We must ensure that we don't proceed if it's invalid.
		var geometry = feature.get("geometry", {})
		
		# Check if geometry is a dictionary and has a type key
		if typeof(geometry) != TYPE_DICTIONARY or not geometry.has("type"): continue

		var coords_array = geometry.get("coordinates", [])

		var geom_type = geometry.get("type")
		var rings_to_process = []

		if geom_type == "Polygon":
			if coords_array.size() > 0:
				# We expect coords_array[0] to be the exterior ring array
				if coords_array[0] != null: # Robustness against null ring
					rings_to_process.append(coords_array[0]) 
		elif geom_type == "MultiPolygon":
			for polygon in coords_array:
				if polygon != null and polygon.size() > 0: # Robustness against null polygon
					# We expect polygon[0] to be the exterior ring array
					if polygon[0] != null: # Robustness against null ring
						rings_to_process.append(polygon[0]) 

		for ring_coords in rings_to_process:
			if ring_coords == null: continue # DEFENSIVE CHECK: Guard against null ring array
			for coord in ring_coords:
				if coord == null: continue # DEFENSIVE CHECK: Guard against null coordinate
				
				# This check prevents calling .size() on Nil
				if coord.size() >= 2: 
					var lon = float(coord[0])
					var lat = float(coord[1])
					min_lon = min(min_lon, lon)
					max_lon = max(max_lon, lon)
					min_lat = min(min_lat, lat)
					max_lat = max(max_lat, lat)

	var width = max_lon - min_lon
	var height = max_lat - min_lat
	return Rect2(min_lon, min_lat, width, height)

func calculate_and_set_transform(features: Array) -> void:
	# ... (rest of function remains unchanged) ...
	var bounds = get_map_bounds(features)

	if bounds.size.x <= 0 or bounds.size.y <= 0:
		push_warning("Map bounds are zero or negative. Cannot calculate transform.")
		return

	var viewport_size = get_viewport_rect().size
	if viewport_size == Vector2.ZERO:
		viewport_size = FALLBACK_VIEWPORT_SIZE

	var draw_width = viewport_size.x - 2 * PADDING
	var draw_height = viewport_size.y - 2 * PADDING

	var scale_x = draw_width / bounds.size.x
	var scale_y = draw_height / bounds.size.y

	calculated_scale = min(scale_x, scale_y)

	var projected_width = bounds.size.x * calculated_scale
	var projected_height = bounds.size.y * calculated_scale

	# Calculate offset to center the map content relative to the viewport.
	var map_left_edge_x = (viewport_size.x - projected_width) / 2.0
	calculated_offset.x = map_left_edge_x - bounds.position.x * calculated_scale
	
	var map_top_edge_y = (viewport_size.y - projected_height) / 2.0
	calculated_offset.y = map_top_edge_y + bounds.end.y * calculated_scale
	
	if camera:
		# Set camera position to the CENTER of the mapped area.
		var map_center_lon = bounds.position.x + bounds.size.x / 2.0
		var map_center_lat = bounds.position.y + bounds.size.y / 2.0
		
		var camera_target_x = map_center_lon * calculated_scale + calculated_offset.x
		var camera_target_y = -map_center_lat * calculated_scale + calculated_offset.y
		
		camera.position = Vector2(camera_target_x, camera_target_y)

# ----------------------------------------------------------------------
## Coordinate and Province Creation (Pure Renderer)
# ----------------------------------------------------------------------

func create_province(nested_coords: Array, properties: Dictionary) -> void:
	var rings: Array = nested_coords
	if rings.is_empty() or rings[0] == null:
		return

	var exterior_coords: Array = rings[0]
	var points: PackedVector2Array = convert_coords_to_points(exterior_coords)

	if points.size() < 3:
		return

	var area = Area2D.new()
	var province_data = DEFAULT_PROVINCE_DATA.duplicate()

	# --- Owner Identification for Data Storage Only (Not Coloring) ---
	var owner_name = "Neutral"
	if properties.has("owner"):
		owner_name = properties["owner"]
	elif properties.has("country"):
		owner_name = properties["country"]
	elif properties.has("name"):
		owner_name = properties["name"]
	
	province_data.name = properties.get("name", "Unnamed Province")
	province_data.owner = owner_name # Store the determined owner name
	# -----------------------------------------------------------------

	area.name = "Province_" + province_data.name
	area.set_meta("data", province_data)

	var visual_poly = Polygon2D.new()
	visual_poly.polygon = points
	
	# TEMPORARY COLOR: Apply a simple random color until the Owner Registry 
	# (external file) can supply the correct, stable color.
	visual_poly.color = Color.from_hsv(randf(), 0.7, 0.9)
	
	visual_poly.z_index = 1 
	visual_poly.light_mask = 1 
	visual_poly.self_modulate = Color.WHITE # Ensures unmuted color
	
	area.add_child(visual_poly)

	var collision_poly = CollisionPolygon2D.new()
	collision_poly.polygon = points
	area.add_child(collision_poly)

	area.input_event.connect(_on_province_clicked.bind(area))

	add_child(area) 

func convert_coords_to_points(coords_array: Array) -> PackedVector2Array:
	var points: PackedVector2Array = []

	for coord in coords_array:
		if coord == null: continue # DEFENSIVE CHECK ADDED: Guard against null coordinate
		if coord.size() >= 2:
			var lon: float = float(coord[0])
			var lat: float = float(coord[1])

			var x = lon * calculated_scale + calculated_offset.x
			var y = -lat * calculated_scale + calculated_offset.y 

			points.append(Vector2(x, y))

	return points

# ----------------------------------------------------------------------
## Camera Control and Interaction Handling
# ----------------------------------------------------------------------

func _unhandled_input(event):
	if camera == null:
		return 

	# --- Panning Start/Stop and Zoom ---
	if event is InputEventMouseButton:
		var handled = false
		
		# Panning Start/Stop (Right Mouse Button)
		if event.button_index == PAN_BUTTON:
			is_panning = event.pressed
			if event.pressed:
				last_mouse_position = get_viewport().get_mouse_position()
			handled = true
		
		# Zoom (Mouse Wheel)
		var new_zoom = target_zoom.x 
		var zoom_changed = false
		
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			new_zoom *= ZOOM_FACTOR
			zoom_changed = true
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			new_zoom /= ZOOM_FACTOR
			zoom_changed = true
			
		if zoom_changed:
			new_zoom = clamp(new_zoom, MIN_ZOOM, MAX_ZOOM)
			target_zoom = Vector2(new_zoom, new_zoom) 
			handled = true 

		if handled:
			get_viewport().set_input_as_handled()


	# --- Panning Motion ---
	elif event is InputEventMouseMotion and is_panning:
		var current_mouse_position = get_viewport().get_mouse_position()
		var delta = current_mouse_position - last_mouse_position
		
		# Panning is working correctly here, assuming the mouse input is received.
		camera.position -= delta * PAN_SPEED / camera.zoom.x
		
		last_mouse_position = current_mouse_position
		get_viewport().set_input_as_handled()

# ----------------------------------------------------------------------
## Province Interaction
# ----------------------------------------------------------------------

func _reset_province_color(province_poly: Polygon2D, original_color: Color):
	if is_instance_valid(province_poly):
		province_poly.color = original_color

func _on_province_clicked(_viewport: Node, event: InputEvent, _shape_idx: int, area: Area2D):
	if not self.is_panning:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var data: Dictionary = area.get_meta("data")

			var visual_poly = area.get_child(0) as Polygon2D
			if visual_poly:
				var original_color = visual_poly.color
				visual_poly.color = Color.WHITE.lerp(original_color, 0.5)

				var timer = self.get_tree().create_timer(0.15)
				timer.timeout.connect(_reset_province_color.bind(visual_poly, original_color))

			print("Province clicked: ", data.name)
			print(" → Owner:", data.owner, " Supply:", data.supply, " Units:", data.units)
