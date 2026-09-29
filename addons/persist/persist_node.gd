## Defines properties that should be save / load managed
class_name PersistNode extends Node

## Used if context cannot be found
const _FALLBACK_CONTEXT := &"DEFAULT"

## [param properties] are relative to this. Defaults to self.
@export var root: Node
## Properties to be save / loaded. This cannot include Objects or
## Callables. These are validated on initialization.
@export var properties: PackedStringArray
@export_group("Optional Overrides", "override")
## Context this node is saved under. Typically left blank so that
## it can be populated by [Persist] when entering the tree. Optionally
## you can predefine a specific context to override [Persist] with.
@export var context: StringName
## Optional: Overrides the [member initial_path] for indexing.
## Defaults to this node's nodepath
@export var index_name: StringName

func _enter_tree() -> void:
	if root == null:
		root = self
	if context.is_empty():
		if Persist.context.is_empty():
			push_warning("No persist context set, defaulting to: %s"%_FALLBACK_CONTEXT)
			context = _FALLBACK_CONTEXT
		else:
			context = Persist.context
	_validate_properties()
	if index_name.is_empty():
		index_name = StringName(get_path())
	Persist.register_node(self)

func _exit_tree() -> void:
	Persist.unregister_node(self)

## Checks all [member properties], throwing errors and erasing any that are
## invalid (Object, Callable, or non-existent).
func _validate_properties() -> void:
	var prop_type: Dictionary[String, int]
	for info in root.get_property_list():
		prop_type[info["name"]] = info["type"]
	for property: String in properties.duplicate():
		if !prop_type.has(property):
			push_error("Unable to locate property to persist: %s"%property)
			properties.erase(property)
		elif prop_type[property] == TYPE_OBJECT:
			push_error("Cannot persist OBJECT on: %s"%property)
			properties.erase(property)
		elif prop_type[property] == TYPE_CALLABLE:
			push_error("Cannot persist CALLABLE on: %s"%property)
			properties.erase(property)
		elif prop_type[property] == TYPE_SIGNAL:
			push_error("Cannot persist SIGNAL on: %s"%property)
			properties.erase(property)

## Output the current values of [member root] [member properties]
func get_state() -> Dictionary:
	if root == null || !is_instance_valid(root):
		push_error("Missing root node to persist for: %s"%self.name)
		return {}
	var data: Dictionary = {}
	for property in properties:
		data[property] = root.get(property)
	return data

## Load stored [member root] [member properties] from [param data].
## Will reject values not part of [member properties].
func set_state(data: Dictionary) -> void:
	if root == null || !is_instance_valid(root):
		push_error("Missing root node to persist for: %s"%self.name)
		return
	for property in data.keys():
		match typeof(property):
			TYPE_OBJECT, TYPE_CALLABLE, TYPE_SIGNAL:
				push_error("Cannot assign property type: %s"%type_string(typeof(property)))
				continue
		if !properties.has(property):
			push_warning("Skipping assignment of unkeyed property: %s"%property)
			continue
		root.set(property, data[property])
