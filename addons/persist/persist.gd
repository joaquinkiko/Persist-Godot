## Persist autoload for save / load management
extends Node

const _TEMP_FILE_PREFIX := "save"
const _SAVE_DIR := "user://"
const _SAVE_EXTENSION := "sav"

var TEMP_PATH: String
var SAVE_PATH: String = "%s/.%s"%[_SAVE_DIR, _SAVE_EXTENSION]

## Current context to assign to newly registered [PersistNode]s
var context: StringName
## Registered [PersistNode]s
var registry: Dictionary[StringName, Dictionary] # context -> path -> node
## Data to be flushed to temporary save file
var pending_writes: Dictionary[StringName, Dictionary] # context -> path -> data

## Temporary save file for read/write without effecting permanent save
var _temp_file: FileAccess

func _exit_tree() -> void:
	_temp_file = null

func _temp_create() -> void:
	_temp_file = FileAccess.create_temp(FileAccess.WRITE, _TEMP_FILE_PREFIX)
	if _temp_file == null:
		push_error("Couldn't create temporary save: %s"%FileAccess.get_open_error())
		return
	TEMP_PATH = _temp_file.get_path()
	_temp_file.close()

func _temp_open(mode: FileAccess.ModeFlags) -> FileAccess:
	if _temp_file == null:
		_temp_create()
	return FileAccess.open(TEMP_PATH, mode)

func _temp_close() -> void:
	if _temp_file == null:
		push_warning("No temp file to close")
		return
	_temp_file.close()

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
	
	var file: FileAccess
	if _temp_file != null && _temp_file.is_open():
		file = _temp_file
	else:
		file = _temp_open(FileAccess.READ)
	file.seek(index[load_context_name][0])
	var data: Dictionary = file.get_var(false)
	var context_registry: Dictionary = registry[load_context_name]
	for path in data.keys():
		if context_registry.has(path):
			context_registry[path].set_state(data[path])
	_clean_up_load_context.call_deferred()

## Should be called after [method load_context] to ensure proper cleanup.
## Kept seperate so it may be called deffered, so we can load multiple contextes
## in a single frame, and only clean up once.
func _clean_up_load_context() -> void:
	if _temp_file != null && _temp_file.is_open():
		_temp_close()

## Returns a [Dictionary] of contexts and their file offset
## and length in our temporary save file
func read_temp_index() -> Dictionary:
	if not FileAccess.file_exists(TEMP_PATH):
		return {}
	var file := _temp_open(FileAccess.READ)
	if file.get_length() < 8:
		_temp_close()
		return {}
	file.seek(file.get_length() - 8)
	var index_position: int = file.get_64()
	file.seek(index_position)
	var index: Dictionary = file.get_var(false)
	_temp_close()
	return index

## Flushes data from [member pending_writes] to our temporary save file
func flush_pending_writes() -> void:
	if pending_writes.is_empty():
		return
	var old_index: Dictionary = read_temp_index()
	var old_file: FileAccess = null
	old_file = _temp_open(FileAccess.READ)
	
	var new_file := FileAccess.create_temp(FileAccess.WRITE, _TEMP_FILE_PREFIX)
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
		_temp_close()
	
	for context_name in pending_writes.keys():
		var start_position: int = new_file.get_position()
		new_file.store_var(pending_writes[context_name], false)
		new_index[context_name] = [start_position, new_file.get_position() - start_position]
	
	var index_position: int = new_file.get_position()
	new_file.store_var(new_index, false)
	new_file.store_64(index_position)
	new_file.close()
	
	#DirAccess.rename_absolute(TEMP_PATH + ".new", TEMP_PATH)
	TEMP_PATH = new_file.get_path()
	_temp_file = new_file
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
	var temp_file := _temp_open(FileAccess.WRITE)
	temp_file.store_buffer(bytes)
	_temp_close()
	pending_writes.clear()

## Saves currrent file
func save_to_binary() -> void:
	flush_all()
	if not FileAccess.file_exists(TEMP_PATH):
		return
	var temp_file := _temp_open(FileAccess.READ)
	var bytes: PackedByteArray = temp_file.get_buffer(temp_file.get_length())
	_temp_close()
	var save_file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	save_file.store_buffer(bytes)
	save_file.close()

## Loads a new, blank file
func new_binary() -> void:
	var temp_file := _temp_open(FileAccess.WRITE)
	temp_file.store_buffer([])
	_temp_close()
	pending_writes.clear()

## Updates [member SAVE_PATH] using [member _SAVE_DIR], [param save_name],
## and [member _SAVE_EXTENSION]. [param save_name] will have invalid
## file characters replaced with '_'.
func set_save_path(save_name: String) -> void:
	save_name.validate_filename()
	var path := "%s/%s.%s"%[_SAVE_DIR, save_name, _SAVE_EXTENSION]
	if !DirAccess.dir_exists_absolute(path.get_base_dir()):
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if !path.is_valid_filename():
		push_error("Invlaid save path: %s"%path)
		return
	if !DirAccess.dir_exists_absolute(path.get_base_dir()):
		DirAccess.make_dir_absolute(path.get_base_dir())
	SAVE_PATH = path

## Lists names of all save file (excluding [member _SAVE_DIR] and
## [member _SAVE_EXTENSION]. Use [param subdir] to search a subdir
func get_saves_list(subdir: String = "") -> PackedStringArray:
	var dir := "%s/%s"%[_SAVE_DIR, subdir]
	if !DirAccess.dir_exists_absolute(dir):
		return []
	var out: PackedStringArray = []
	for file in DirAccess.get_files_at(dir):
		if file.get_extension() == _SAVE_EXTENSION:
			out.append(file.get_file().get_basename())
	return out

## List any subdirectories containing save files.
## Use [param subdir] to search for subdirs within a subdir
func get_save_subdirs(subdir: String = "") -> PackedStringArray:
	var dir := "%s/%s"%[_SAVE_DIR, subdir]
	if !DirAccess.dir_exists_absolute(dir):
		return []
	var out: PackedStringArray = []
	for _subdir in DirAccess.get_directories_at(dir):
		for file in DirAccess.get_files_at(_subdir):
			if file.get_extension() == _SAVE_EXTENSION:
				out.append(_subdir)
				continue
	return out
