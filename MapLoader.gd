extends Node2D

# --- Configuration Constants ---
# Target padding around the map in the viewport (in pixels).
const PADDING = 50.0 
# Default aspect ratio if the viewport size is not yet available (e.g., in _ready).
const FALLBACK_VIEWPORT_SIZE = Vector2(1024.0, 600.0) 
# Camera Zoom limits
const MIN_ZOOM = 0.5
const MAX_ZOOM = 3.0
const ZOOM_SPEED = 0.1

# Internal variables for calculated transform
var calculated_scale = 1.0
var calculated_offset = Vector2.ZERO

# Camera Control State
var is_panning = false
var pan_start_position = Vector2.ZERO
var camera: Camera2D = null # Reference to the Camera2D node

const DEFAULT_PROVINCE_DATA = {
	"name": "Unnamed Province",
	"owner": "Neutral",
	"supply": 10,
	"units": 0
}

# --- Initialization ---
func _ready():
	# Setup Camera
	camera = Camera2D.new()
	add_child(camera)
	camera.current = true
	camera.limit_smoothed = true
	camera.position_smoothing_enabled = true
	camera.zoom = Vector2(1.0, 1.0)
	
	# The map loading process now includes automatic coordinate transformation
	load_map("res://map.json")

# --- Map Loading and Parsing ---
func load_map(path: String) -> void:
	# 1. Load and Parse JSON
	if not FileAccess.file_exists(path):
		push_error("Error: Map file not found at: " + path)
		return

	var file = FileAccess.open(path, FileAccess.READ)
	var json_text = file.get_as_text()
	file.close()

	var data = JSON.parse_string(json_text)

	if typeof(data) != TYPE_DICTIONARY or data == null:
		push_error("Error: Failed to parse JSON. Check syntax.")
		return

	if not data.has("features") or data.get("type") != "FeatureCollection":
		push_error("Error: JSON is not a valid GeoJSON FeatureCollection.")
		return

	var features = data.features
	
	# 2. Automatically Calculate Transform (The new, crucial step)
	calculate_and_set_transform(features)

	# 3. Process each feature
	for feature in features:
		var properties = feature.get("properties", {})
		var geometry = feature.get("geometry", {})

		if geometry.get("type") == "Polygon":
			create_province(geometry.coordinates, properties)
		elif geometry.get("type") == "MultiPolygon":
			for polygon_coords in geometry.coordinates:
				create_province(polygon_coords, properties)

# --- Automated Transform Calculation ---

# Finds the min/max longitude and latitude across ALL map features.
func get_map_bounds(features: Array) -> Rect2:
	var min_lon = INF
	var max_lon = -INF
	var min_lat = INF
	var max_lat = -INF

	for feature in features:
		var geometry = feature.get("geometry", {})
		var coords_array = geometry.get("coordinates", [])

		var geom_type = geometry.get("type")
		var rings_to_process = []

		if geom_type == "Polygon":
			if coords_array.size() > 0:
				rings_to_process.append(coords_array[0]) # Exterior ring
		elif geom_type == "MultiPolygon":
			for polygon in coords_array:
				if polygon.size() > 0:
					rings_to_process.append(polygon[0]) # Exterior ring of each polygon

		for ring_coords in rings_to_process:
			for coord in ring_coords:
				if coord.size() >= 2:
					var lon = float(coord[0])
					var lat = float(coord[1])
					min_lon = min(min_lon, lon)
					max_lon = max(max_lon, lon)
					min_lat = min(min_lat, lat)
					max_lat = max(max_lat, lat)

	# Return bounds as Rect2(position, size)
	var width = max_lon - min_lon
	var height = max_lat - min_lat
	return Rect2(min_lon, min_lat, width, height)

# Calculates the necessary scale and offset to center the map in the viewport.
func calculate_and_set_transform(features: Array) -> void:
	var bounds = get_map_bounds(features)

	if bounds.size.x <= 0 or bounds.size.y <= 0:
		push_warning("Map bounds are zero or negative. Cannot calculate transform.")
		return

	# Use viewport size, fall back if not available (e.g., if called too early)
	var viewport_size = get_viewport_rect().size
	if viewport_size == Vector2.ZERO:
		viewport_size = FALLBACK_VIEWPORT_SIZE

	# 1. Calculate Scale
	# We need to fit the horizontal range (bounds.size.x) and the vertical range (bounds.size.y)
	var draw_width = viewport_size.x - 2 * PADDING
	var draw_height = viewport_size.y - 2 * PADDING

	var scale_x = draw_width / bounds.size.x
	var scale_y = draw_height / bounds.size.y

	# Use the smaller scale factor to ensure the entire map fits within the viewport.
	calculated_scale = min(scale_x, scale_y)

	# 2. Calculate Offset (for centering)
	# The projected map size after scaling:
	var projected_width = bounds.size.x * calculated_scale
	var projected_height = bounds.size.y * calculated_scale

	# Calculate offset to center the map within the draw area.
	# Longitude (X): Shift the min_lon coordinate (which becomes the left edge) 
	# to the screen's center point.
	var center_x = (viewport_size.x - projected_width) / 2.0
	calculated_offset.x = center_x - bounds.position.x * calculated_scale

	# Latitude (Y): This is trickier due to the Y-flip. The max_lat (top of the map) 
	# should land near the top of the viewport.
	var center_y = (viewport_size.y - projected_height) / 2.0
	# The Y flip means we calculate based on the MAX latitude coordinate 
	# landing near the TOP (low Y value) of the screen.
	calculated_offset.y = center_y + bounds.end.y * calculated_scale
	
	# Set the initial camera position to the calculated center offset.
	if camera:
		camera.position = calculated_offset
	else:
		# If camera not initialized yet, set the map position itself
		position = calculated_offset

	print("\n--- Auto-Calculated Transform Results ---")
	print("Map Bounds: ", bounds)
	print("Calculated Scale (Factor): ", calculated_scale)
	print("Calculated Offset (Vector2): ", calculated_offset)
	print("---------------------------------------")

# ---
## Province Creation (Uses calculated_scale and calculated_offset)

func create_province(nested_coords: Array, properties: Dictionary) -> void:
	var rings: Array = nested_coords
	if rings.is_empty():
		return

	var exterior_coords: Array = rings[0]
	# NOTE: The convert function now uses the *calculated* global variables
	var points: PackedVector2Array = convert_coords_to_points(exterior_coords)

	if points.size() < 3:
		return

	var area = Area2D.new()
	var province_data = DEFAULT_PROVINCE_DATA.duplicate()

	for key in properties:
		# Temporary logic for uploaded file missing properties:
		if "id" not in properties:
			if exterior_coords[0][1] > 50:
				 province_data.name = "Quebec (Auto)"
			else:
				 province_data.name = "Italy (Auto)"

		province_data[key] = properties[key]

	area.name = "Province_" + province_data.name
	area.set_meta("data", province_data)

	var visual_poly = Polygon2D.new()
	visual_poly.polygon = points
	visual_poly.color = Color.from_hsv(randf(), 0.8, 1.0)
	area.add_child(visual_poly)

	var collision_poly = CollisionPolygon2D.new()
	collision_poly.polygon = points
	area.add_child(collision_poly)

	area.input_event.connect(_on_province_clicked.bind(area))

	add_child(area)
	print("Successfully created: ", province_data.name)


# Helper function for coordinate transformation
func convert_coords_to_points(coords_array: Array) -> PackedVector2Array:
	var points: PackedVector2Array = []

	for coord in coords_array:
		if coord.size() >= 2:
			var lon: float = float(coord[0])
			var lat: float = float(coord[1])

			# Transformation logic now uses calculated variables
			var x = lon * calculated_scale + calculated_offset.x
			var y = -lat * calculated_scale + calculated_offset.y

			points.append(Vector2(x, y))

	# NOTE: Debug print statements are moved to the calculation function
	return points


# ---
## Camera Control and Interaction Handling 

# Captures mouse wheel events for zoom and mouse presses for panning start/stop
func _unhandled_input(event):
	if event is InputEventMouseButton:
		# --- Panning Start/Stop (Middle Button for standard GIS/Map interaction) ---
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				is_panning = true
				# Get position relative to the camera's viewport
				pan_start_position = get_viewport().get_mouse_position()
			else:
				is_panning = false
		
		# --- Zoom (Mouse Wheel) ---
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			if camera:
				var new_zoom = camera.zoom.x + ZOOM_SPEED
				new_zoom = clamp(new_zoom, MIN_ZOOM, MAX_ZOOM)
				camera.zoom = Vector2(new_zoom, new_zoom)
				get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if camera:
				var new_zoom = camera.zoom.x - ZOOM_SPEED
				new_zoom = clamp(new_zoom, MIN_ZOOM, MAX_ZOOM)
				camera.zoom = Vector2(new_zoom, new_zoom)
				get_viewport().set_input_as_handled()
				
	# Handle the actual mouse movement for panning
	elif event is InputEventMouseMotion and is_panning:
		var mouse_current_pos = get_viewport().get_mouse_position()
		var delta = mouse_current_pos - pan_start_position
		
		# Panning moves the camera (which moves the viewport relative to the map)
		# Multiply by 1/zoom to account for the camera zoom level
		camera.position -= delta * (1.0 / camera.zoom)
		pan_start_position = mouse_current_pos
		get_viewport().set_input_as_handled()

# Dedicated function to reset the province color after a short delay
func _reset_province_color(province_poly: Polygon2D, original_color: Color):
	# Check if the node is still valid before attempting to set the color
	if is_instance_valid(province_poly):
		province_poly.color = original_color

func _on_province_clicked(_viewport: Node, event: InputEvent, shape_idx: int, area: Area2D):
	# Fix 1: Explicitly use self.is_panning
	if not self.is_panning:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var data: Dictionary = area.get_meta("data")

			var visual_poly = area.get_child(0) as Polygon2D
			if visual_poly:
				var original_color = visual_poly.color
				visual_poly.color = Color.WHITE.lerp(original_color, 0.5)

				# Fix 2: Explicitly use self.get_tree()
				var timer = self.get_tree().create_timer(0.15)
				# Now using the dedicated function for the callback
				timer.timeout.connect(_reset_province_color.bind(visual_poly, original_color))

			print("Province clicked: ", data.name)
			print("  → Owner:", data.owner, " Supply:", data.supply, " Units:", data.units)
