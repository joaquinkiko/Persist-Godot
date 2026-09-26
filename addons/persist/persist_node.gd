## Defines properties that should be save / load managed
class_name PersistNode extends Node 

## [param properties] are relative to this. Defaults to self.
@export var root: Node
## Properties to be save / loaded. This cannot include Objects or
## Callables. These are validated on initialization.
@export var properties: PackedStringArray
## Inital path on entering tree
var initial_path: NodePath
## Context this node is saved under. Typically left blank so that
## it can be populated by [Persist] when entering the tree. Optionally
## you can predefine a specific context to override [Persist] with.
@export var context: StringName

func _init() -> void:
	if root == null:
		root = self
	if context.is_empty():
		context = Persist.context
	_validate_properties()

func _enter_tree() -> void:
	initial_path = get_path()
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

## Output the current values of [member root] [member properties]
func get_state() -> Dictionary:
	var data: Dictionary = {}
	for property in properties:
		data[property] = root.get(property)
	return data

## Load stored [member root] [member properties] from [param data].
## Will reject values not part of [member properties].
func set_state(data: Dictionary) -> void:
	for property in data.keys():
		if !properties.has(property): continue
		root.set(property, data[property])
