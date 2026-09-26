## Persist autoload for save / load management
extends Node

const TEMP_PATH: String = "user://save.tmp"
const SAVE_PATH: String = "user://save.bin"

## Current context to assign to newly registered [PersistNode]s
var context: StringName
## Registered [PersistNode]s
var registry: Dictionary[StringName, Dictionary] # context -> path -> node
## Data to be flushed to temporary save file
var pending_writes: Dictionary[StringName, Dictionary] # context -> path -> data

func set_context(new_context: StringName) -> void:
	context = new_context

## Start tracking a [PersistNode], and load it's context
func register_node(node: PersistNode) -> void:
	if !registry.has(node.context):
		registry[node.context] = {}
	registry[node.context][node.index_name] = node
	load_context(node.context)

## Stop tracking a [PersistNode], and call a [method queue_pending_write] on it
func unregister_node(node: PersistNode) -> void:
	if registry.has(node.context):
		registry[node.context].erase(node.index_name)
		queue_pending_write(node.context, node.index_name, node.get_state())

## Saves data to [member pending_writes] and makes a deffered call 
## to [method flush_pending_writes] (providing time for other writes to occur
## this frame before it they are flushed.
func queue_pending_write(write_context: StringName, index: StringName, data: Dictionary) -> void:
	if not pending_writes.has(write_context):
		pending_writes[write_context] = {}
	pending_writes[write_context][index] = data
	flush_pending_writes.call_deferred()

## Applies data for [param load_context_name] with matching registered [PersistNode]s
func load_context(load_context_name: StringName) -> void:
	var index := read_temp_index()
	if not index.has(load_context_name) or not registry.has(load_context_name):
		return
	var file := FileAccess.open(TEMP_PATH, FileAccess.READ)
	file.seek(index[load_context_name][0])
	var data: Dictionary = file.get_var(false)
	file.close()
	var context_registry: Dictionary = registry[load_context_name]
	for path in data.keys():
		if context_registry.has(path):
			context_registry[path].set_state(data[path])

## Returns a [Dictionary] of contexts and their file offset
## and length in our temporary save file
func read_temp_index() -> Dictionary:
	if not FileAccess.file_exists(TEMP_PATH):
		return {}
	var file := FileAccess.open(TEMP_PATH, FileAccess.READ)
	if file.get_length() < 8:
		file.close()
		return {}
	file.seek(file.get_length() - 8)
	var index_position: int = file.get_64()
	file.seek(index_position)
	var index: Dictionary = file.get_var(false)
	file.close()
	return index

## Flushes data from [member pending_writes] to our temporary save file
func flush_pending_writes() -> void:
	if pending_writes.is_empty():
		return
	var old_index: Dictionary = read_temp_index()
	var old_file: FileAccess = null
	if FileAccess.file_exists(TEMP_PATH):
		old_file = FileAccess.open(TEMP_PATH, FileAccess.READ)
	
	var new_file := FileAccess.open(TEMP_PATH + ".new", FileAccess.WRITE)
	var new_index: Dictionary = {}
	
	for context_name in old_index.keys():
		if pending_writes.has(context_name):
			continue
		var offset: int = old_index[context_name][0]
		var length: int = old_index[context_name][1]
		old_file.seek(offset)
		var raw_bytes: PackedByteArray = old_file.get_buffer(length)
		new_index[context_name] = [new_file.get_position(), length]
		new_file.store_buffer(raw_bytes)
	
	if old_file:
		old_file.close()
	
	for context_name in pending_writes.keys():
		var start_position: int = new_file.get_position()
		new_file.store_var(pending_writes[context_name], false)
		new_index[context_name] = [start_position, new_file.get_position() - start_position]
	
	var index_position: int = new_file.get_position()
	new_file.store_var(new_index, false)
	new_file.store_64(index_position)
	new_file.close()
	
	DirAccess.rename_absolute(TEMP_PATH + ".new", TEMP_PATH)
	pending_writes.clear()

## Flushes data from all registered [PersistNode]s to temporary save file
func flush_all() -> void:
	for context_name in registry.keys():
		for path in registry[context_name].keys():
			if not pending_writes.has(context_name):
				pending_writes[context_name] = {}
			pending_writes[context_name][path] = registry[context_name][path].get_state()
	flush_pending_writes()

## Loads specified file
func load_from_binary() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var save_file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	var bytes: PackedByteArray = save_file.get_buffer(save_file.get_length())
	save_file.close()
	var temp_file := FileAccess.open(TEMP_PATH, FileAccess.WRITE)
	temp_file.store_buffer(bytes)
	temp_file.close()
	pending_writes.clear()

## Saves currrent file
func save_to_binary() -> void:
	flush_all()
	if not FileAccess.file_exists(TEMP_PATH):
		return
	var temp_file := FileAccess.open(TEMP_PATH, FileAccess.READ)
	var bytes: PackedByteArray = temp_file.get_buffer(temp_file.get_length())
	temp_file.close()
	var save_file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	save_file.store_buffer(bytes)
	save_file.close()
