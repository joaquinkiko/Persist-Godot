## Persist autoload for save / load management
extends Node

const _TEMP_FILE_PREFIX := "save"
const _SAVE_DIR := "user://"
const _SAVE_EXTENSION := "sav"

## Used at start of file to confirm this is a valid filetype
const _MAGIC := "GDT"
## Current protocol version in use
const PROTOCOL_VERSION := 0
## Size in bytes of the header for each protocol version
const _HEADER_SIZES := {0: 0}
## [member _MAGIC] size + 1 byte for PROTOCOL
const _INDEX_POINTER_OFFSET := 4
## Stores a u32 int
const _INDEX_POINTER_SIZE := 4
const _PREAMBLE_SIZE := _INDEX_POINTER_OFFSET + _INDEX_POINTER_SIZE
## Compression is only used on permanent saves
const COMPRESSION_MODE := FileAccess.COMPRESSION_ZSTD

var TEMP_PATH: String
var SAVE_PATH: String = "%s/.%s"%[_SAVE_DIR, _SAVE_EXTENSION]

## Current context to assign to newly registered [PersistNode]s
var context: StringName
## Registered [PersistNode]s
var registry: Dictionary[StringName, Dictionary] # context -> path -> node
## Data to be flushed to temporary save file
var pending_writes: Dictionary[StringName, Dictionary] # context -> path -> data
## Free-form data stored alongside save-data fully defined by user
## Loaded by [method load_from_binary] and written on every flush
var metadata: Dictionary

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
	var bytes: PackedByteArray = file.get_buffer(index[load_context_name][1])
	var data: Dictionary = PersistEncoder.decode_dictionary(bytes, 0)[0]
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

## Validates the first [constant _PREAMBLE_SIZE] bytes of a save file.
## Returns {"version": int, "index_position": int}, or an empty [Dictionary]
## if the magic phrase, version, or index position is invalid
func _parse_preamble(bytes: PackedByteArray, file_length: int) -> Dictionary:
	if bytes.size() < _PREAMBLE_SIZE:
		return {}
	if bytes.slice(0, _MAGIC.length()).get_string_from_ascii() != _MAGIC:
		return {}
	var version: int = bytes[_MAGIC.length()]
	if not _HEADER_SIZES.has(version):
		return {}
	var index_position: int = bytes.decode_u32(_INDEX_POINTER_OFFSET)
	if index_position < _PREAMBLE_SIZE + _HEADER_SIZES[version] or index_position >= file_length:
		return {}
	return {"version": version, "index_position": index_position}

## Reads and validates the preamble of [param file]
func _read_preamble(file: FileAccess) -> Dictionary:
	file.seek(0)
	return _parse_preamble(file.get_buffer(_PREAMBLE_SIZE), file.get_length())

## Reads the header of [param file]. The header size is determined by
## [param version]. Leaves the file positioned at the start of the metadata.
func read_header(file: FileAccess, version: int) -> PackedByteArray:
	if not _HEADER_SIZES.has(version):
		push_error("Unsupported save protocol version: %s"%version)
		return PackedByteArray()
	file.seek(_PREAMBLE_SIZE)
	return file.get_buffer(_HEADER_SIZES[version])

## Builds the header for the current [constant PROTOCOL_VERSION].
func _build_header() -> PackedByteArray:
	var header := PackedByteArray()
	header.resize(_HEADER_SIZES[PROTOCOL_VERSION])
	match PROTOCOL_VERSION:
		1:
			pass # Unimplemented
	return header

## Reads the context index from [param file]. Returns {context: [offset, length]}.
func _read_index(file: FileAccess, preamble: Dictionary) -> Dictionary:
	if preamble.is_empty():
		return {}
	var index_position: int = preamble["index_position"]
	file.seek(index_position)
	var bytes := file.get_buffer(file.get_length() - index_position)
	if bytes.is_empty():
		return {}
	
	var count_result := PersistEncoder.decode_varint(bytes, 0)
	var position: int = count_result[1]
	var offsets: Dictionary = {}
	for i in count_result[0]:
		var name_result := PersistEncoder.decode_string(bytes, position)
		var offset_result := PersistEncoder.decode_varint(bytes, name_result[1])
		offsets[StringName(name_result[0])] = offset_result[0]
		position = offset_result[1]
	
	var sorted_offsets: Array = offsets.values()
	sorted_offsets.sort()
	var index: Dictionary = {}
	for context_name in offsets.keys():
		var offset: int = offsets[context_name]
		var next: int = sorted_offsets.find(offset) + 1
		var end: int = sorted_offsets[next] if next < sorted_offsets.size() else index_position
		index[context_name] = [offset, end - offset]
	return index

## Writes magic, version, a placeholder index position, header, and metadata.
## Must be followed by the contexts, then [method _finalize_file].
func _write_head(file: FileAccess) -> void:
	file.store_buffer(_MAGIC.to_ascii_buffer())
	file.store_8(PROTOCOL_VERSION)
	file.store_32(0) # Placeholder till we determine final size
	file.store_buffer(_build_header())
	file.store_buffer(PersistEncoder.encode_dictionary(metadata))

## Writes the context index, patches the index position written by
## [method _write_head], and closes [param file].
## [param offsets] is {context: absolute offset}.
func _finalize_file(file: FileAccess, offsets: Dictionary) -> void:
	var index_position: int = file.get_position()
	file.store_buffer(PersistEncoder.encode_varint(offsets.size()))
	for context_name in offsets.keys():
		file.store_buffer(PersistEncoder.encode_string(String(context_name)))
		file.store_buffer(PersistEncoder.encode_varint(offsets[context_name]))
	file.seek(_INDEX_POINTER_OFFSET)
	file.store_32(index_position)
	file.close()

## Returns a [Dictionary] of contexts and their file offset
## and length in our temporary save file
func read_temp_index() -> Dictionary:
	if not FileAccess.file_exists(TEMP_PATH):
		return {}
	var file := _temp_open(FileAccess.READ)
	var index := _read_index(file, _read_preamble(file))
	return index

## Returns the metadata stored in our temporary save file
func read_temp_metadata() -> Dictionary:
	if not FileAccess.file_exists(TEMP_PATH):
		return {}
	var file := _temp_open(FileAccess.READ)
	var preamble := _read_preamble(file)
	if preamble.is_empty():
		_temp_close()
		return {}
	var index := _read_index(file, preamble)
	read_header(file, preamble["version"])
	var start: int = file.get_position()
	# Metadata runs until the first context (or the index if there are none)
	var end: int = preamble["index_position"]
	for entry in index.values():
		end = mini(end, entry[0])
	var bytes := file.get_buffer(end - start)
	_temp_close()
	if bytes.is_empty():
		return {}
	return PersistEncoder.decode_dictionary(bytes, 0)[0]

## Flushes data from [member pending_writes] to our temporary save file
func flush_pending_writes(force: bool = false) -> void:
	if pending_writes.is_empty() and not force:
		return
	var old_index: Dictionary = read_temp_index()
	var old_file: FileAccess = null
	if _temp_file != null && _temp_file.is_open():
		old_file = _temp_file
	else:
		old_file = _temp_open(FileAccess.READ)
	
	var new_file := FileAccess.create_temp(FileAccess.WRITE, _TEMP_FILE_PREFIX)
	_write_head(new_file)
	var new_index: Dictionary = {}
	
	for context_name in old_index.keys():
		if pending_writes.has(context_name):
			continue
		var offset: int = old_index[context_name][0]
		var length: int = old_index[context_name][1]
		old_file.seek(offset)
		var raw_bytes: PackedByteArray = old_file.get_buffer(length)
		new_index[context_name] = new_file.get_position()
		new_file.store_buffer(raw_bytes)
	
	if old_file:
		_temp_close()
	
	for context_name in pending_writes.keys():
		new_index[context_name] = new_file.get_position()
		new_file.store_buffer(PersistEncoder.encode_dictionary(pending_writes[context_name]))
	
	_finalize_file(new_file, new_index)
	
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
	flush_pending_writes(true)

## Loads specified file. If the file has an invalid magic phrase, an
## unsupported version, or a bad index position, an error is pushed and
## a blank file is loaded instead
func load_from_binary() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var save_file := FileAccess.open_compressed(SAVE_PATH, FileAccess.READ, COMPRESSION_MODE)
	var bytes: PackedByteArray = save_file.get_buffer(save_file.get_length())
	save_file.close()
	if _parse_preamble(bytes, bytes.size()).is_empty():
		push_error("Invalid or unsupported save file, loading blank file: %s"%SAVE_PATH)
		new_binary()
		return
	var temp_file := _temp_open(FileAccess.WRITE)
	temp_file.store_buffer(bytes)
	temp_file.close() # Must be flushed before metadata is read back
	_temp_close()
	metadata = read_temp_metadata()
	pending_writes.clear()

## Saves currrent file
func save_to_binary() -> void:
	flush_all()
	if not FileAccess.file_exists(TEMP_PATH):
		return
	var temp_file := _temp_open(FileAccess.READ)
	var bytes: PackedByteArray = temp_file.get_buffer(temp_file.get_length())
	_temp_close()
	var save_file := FileAccess.open_compressed(SAVE_PATH, FileAccess.WRITE, COMPRESSION_MODE)
	save_file.store_buffer(bytes)
	save_file.close()

## Loads a new, blank file
func new_binary() -> void:
	metadata = {}
	var temp_file := _temp_open(FileAccess.WRITE)
	_write_head(temp_file)
	_finalize_file(temp_file, {})
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

## Erases all [param contexts_to_erase] from temporary save file.
## For more precise handling may use [param indexes_to_erase] to
## specify {context : indices} to erase.
func erase_from_temp(contexts_to_erase: Array[StringName] = [], 
					indexes_to_erase: Dictionary[StringName, PackedStringArray] = {}) -> void:
	var old_index: Dictionary = read_temp_index()
	if old_index.is_empty():
		return
	
	var old_file: FileAccess
	if _temp_file != null && _temp_file.is_open():
		old_file = _temp_file
	else:
		old_file = _temp_open(FileAccess.READ)
	var new_file := FileAccess.create_temp(FileAccess.WRITE, _TEMP_FILE_PREFIX)
	_write_head(new_file)
	var new_index: Dictionary = {}
	# Write modified version to new temp file
	for context_name in old_index.keys():
		# Skip entirely erased contexts
		if context_name in contexts_to_erase:
			continue
		# Find this context in the file
		var offset: int = old_index[context_name][0]
		var length: int = old_index[context_name][1]
		old_file.seek(offset)
		var context_bytes: PackedByteArray = old_file.get_buffer(length)
		var context_data: Dictionary = PersistEncoder.decode_dictionary(context_bytes, 0)[0]
		# Filter indexes within this context if specified
		if indexes_to_erase.has(context_name):
			for index_key in indexes_to_erase[context_name]:
				context_data.erase(index_key)
		# If this erased all context data we can skip rewriting it
		if context_data.is_empty():
			continue
		new_index[context_name] = new_file.get_position()
		new_file.store_buffer(PersistEncoder.encode_dictionary(context_data))
	_temp_close()
	
	_finalize_file(new_file, new_index)
	
	TEMP_PATH = new_file.get_path()
	_temp_file = new_file
	_temp_close()
	pending_writes.clear()

## Quickly saves with specified [param save_name] before restoring [member SAVE_PATH]
func quicksave(save_name: String) -> void:
	var current_path := SAVE_PATH
	set_save_path(save_name)
	save_to_binary()
	SAVE_PATH = current_path

## Quickly loads with specified [param save_name] before restoring [member SAVE_PATH]
func quickload(save_name: String) -> void:
	var current_path := SAVE_PATH
	set_save_path(save_name)
	load_from_binary()
	SAVE_PATH = current_path

## Gets name of current save by trimming [member _SAVE_DIR] and [member _SAVE_EXTENSION]
func get_save_name() -> String:
	return SAVE_PATH.trim_prefix(_SAVE_DIR).trim_suffix(_SAVE_EXTENSION)
