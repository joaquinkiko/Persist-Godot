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
const _HEADER_SIZES := {
	0: 0,
	1: 64,
	}
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
## Meta-name of current save
var meta_name: String
## Free-form data stored alongside save-data fully defined by user
## Loaded by [method load_from_binary] and written on every flush
var metadata: Dictionary

## Temporary save file for read/write without effecting permanent save
var _temp_file: FileAccess

func _exit_tree() -> void:
	_temp_file = null

func _temp_create() -> void:
	if _temp_file != null:
		if _temp_file.is_open(): _temp_file.close()
		_temp_file = null
	_temp_file = FileAccess.create_temp(FileAccess.WRITE, _TEMP_FILE_PREFIX)
	if _temp_file == null:
		push_error("Couldn't create temporary save: %s"%FileAccess.get_open_error())
		TEMP_PATH = ""
		return
	TEMP_PATH = _temp_file.get_path()
	_temp_file.close()

func _temp_open(mode: FileAccess.ModeFlags) -> FileAccess:
	if _temp_file == null || !FileAccess.file_exists(TEMP_PATH):
		_temp_create()
	if _temp_file == null || TEMP_PATH.is_empty(): # Creation error
		push_error("No TEMP_PATH to open file from!")
		return null
	var file := FileAccess.open(TEMP_PATH, mode)
	if file == null:
		push_error("Error opening temp file: %s"%error_string(FileAccess.get_open_error()))
	return file

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
	if registry[node.context].has(node.index_name):
		push_warning("Node context/index collision (will overwrite with latest)")
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
	if file == null:
		push_error("Unable to load context!")
		return
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
func read_header(file: FileAccess) -> PackedByteArray:
	if file == null:
		push_error("No file to read header from!")
		return []
	var version: int = _parse_preamble(
		file.get_buffer(_PREAMBLE_SIZE), file.get_length()
		).get("version", 0)
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
			var buffer := PackedByteArray()
			# Meta name
			# size 32 (excess cut off)
			# Offset 0
			buffer.append_array(PersistEncoder.encode_string(meta_name))
			buffer.resize(32)
			buffer[buffer.size() - 1] = int(char(3)) # Force string terminator
			# Project Version
			# size 16 (excess cut off)
			# Offset 32
			buffer.append_array(PersistEncoder.encode_string(
				ProjectSettings.get_setting("application/config/version", "")))
			buffer.resize(48)
			buffer[buffer.size() - 1] = int(char(3)) # Force string terminator
			# Unix Time
			# size 4
			# Offset 48
			buffer.resize(buffer.size() - 4)
			buffer.encode_double(Time.get_unix_time_from_system(), buffer.size() - 4)
			# Unused Padding
			buffer.resize(64)
		_:
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
	if file == null:
		push_error("No file to write header to!")
		return
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
	if file == null:
		push_error("Unable to read temp index!")
		return {}
	var index := _read_index(file, _read_preamble(file))
	return index

## Returns the metadata stored in our temporary save file
func read_temp_metadata() -> Dictionary:
	if not FileAccess.file_exists(TEMP_PATH):
		return {}
	var file := _temp_open(FileAccess.READ)
	if file == null:
		push_error("Unable to read temp metadata!")
		return {}
	var preamble := _read_preamble(file)
	if preamble.is_empty():
		_temp_close()
		return {}
	var index := _read_index(file, preamble)
	read_header(file)
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
	if old_file == null:
		push_error("Unable to open temp while flushing data!")
		return
	var new_file := FileAccess.create_temp(FileAccess.WRITE, _TEMP_FILE_PREFIX)
	if new_file == null:
		push_error("Couldn't create temp file to flush too: %s"%FileAccess.get_open_error())
		return
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
	
	if old_file != null && old_file.is_open():
		old_file.close()
	
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
func load_from_binary() -> Error:
	if not FileAccess.file_exists(SAVE_PATH):
		if FileAccess.file_exists(SAVE_PATH + ".backup"):
			var error := DirAccess.copy_absolute(SAVE_PATH + ".backup", SAVE_PATH)
			if error != OK:
				push_error("Attempted to restore save from backup but encountered error: %s"%error_string(error))
				return error
		else:
			push_error("Missing file to load from!")
			return ERR_DOES_NOT_EXIST
	var success: bool = true
	var bytes: PackedByteArray
	var save_file := FileAccess.open_compressed(SAVE_PATH, FileAccess.READ, COMPRESSION_MODE)
	if save_file == null:
		push_error("Error loading binary from file: %s"%error_string(FileAccess.get_open_error()))
		success = false
	else:
		bytes = save_file.get_buffer(save_file.get_length())
		save_file.close()
	if success && _parse_preamble(bytes, bytes.size()).is_empty():
		push_error("Invalid or unsupported save file, loading blank file: %s"%SAVE_PATH)
		new_binary()
		success = false
	# Re-attempt load with backup
	if !success:
		if FileAccess.file_exists(SAVE_PATH + ".backup"):
			push_warning("Unable to load save, attempting to load from backup")
			save_file = FileAccess.open_compressed(SAVE_PATH + ".backup", FileAccess.READ, COMPRESSION_MODE)
			if save_file == null:
				push_error("Error loading binary from file: %s"%error_string(FileAccess.get_open_error()))
				return FileAccess.get_open_error()
			bytes = save_file.get_buffer(save_file.get_length())
			save_file.close()
			if _parse_preamble(bytes, bytes.size()).is_empty():
				push_error("Invalid or unsupported save file, loading blank file: %s"%SAVE_PATH + ".backup")
				new_binary()
				return ERR_INVALID_DATA
		else:
			push_error("Unable to load save: %s"%SAVE_PATH)
			return ERR_INVALID_DATA
	# We've now loaded from main or backup
	var temp_file := _temp_open(FileAccess.WRITE)
	if temp_file == null:
		push_error("Unable to store loaded binary to temp!")
		return ERR_FILE_CANT_WRITE
	temp_file.store_buffer(bytes)
	temp_file.close() # Must be flushed before metadata is read back
	_temp_close()
	metadata = read_temp_metadata()
	pending_writes.clear()
	return OK

## Saves currrent file
func save_to_binary() -> Error:
	if FileAccess.file_exists(SAVE_PATH):
		var error := DirAccess.copy_absolute(SAVE_PATH, SAVE_PATH + ".backup")
		if error != OK:
			push_warning("Couldn't backup save (continuing without backup): %s"%error_string(error))
	flush_all()
	if not FileAccess.file_exists(TEMP_PATH):
		push_error("No temp file exists to save from")
		return ERR_DOES_NOT_EXIST
	var temp_file := _temp_open(FileAccess.READ)
	if temp_file == null:
		push_error("Unable to read temp to save binary from!")
		return ERR_FILE_CANT_READ
	var bytes: PackedByteArray = temp_file.get_buffer(temp_file.get_length())
	_temp_close()
	var save_file := FileAccess.open_compressed(SAVE_PATH + ".tmp", FileAccess.WRITE, COMPRESSION_MODE)
	if save_file == null:
		push_error("Error saving binary to file: %s"%error_string(FileAccess.get_open_error()))
		if FileAccess.file_exists(SAVE_PATH + ".backup"):
			DirAccess.remove_absolute(SAVE_PATH + ".backup")
		return FileAccess.get_open_error()
	save_file.store_buffer(bytes)
	save_file.close()
	var error := DirAccess.rename_absolute(SAVE_PATH + ".tmp", SAVE_PATH)
	if error != OK:
		push_error("Error writing save: %s"%error_string(error))
	if FileAccess.file_exists(SAVE_PATH + ".backup"):
			DirAccess.remove_absolute(SAVE_PATH + ".backup")
	return error

## Loads a new, blank file
func new_binary() -> Error:
	metadata = {}
	var temp_file := _temp_open(FileAccess.WRITE)
	if temp_file == null:
		push_error("Unable to write new temp for new binary!")
		return ERR_FILE_CANT_WRITE
	_write_head(temp_file)
	_finalize_file(temp_file, {})
	_temp_close()
	pending_writes.clear()
	return OK

## Updates [member SAVE_PATH] using [member _SAVE_DIR], [param save_name],
## and [member _SAVE_EXTENSION]. [param save_name] will have invalid
## file characters replaced with '_'.
func set_save_path(save_name: String) -> void:
	for part in save_name.split('/', false):
		if part != part.validate_filename():
			push_error("'%s' in '%s' is invalid for filename"%[part, save_name])
		save_name.replace(part, part.validate_filename())
	var path := "%s/%s.%s"%[_SAVE_DIR, save_name, _SAVE_EXTENSION]
	if !DirAccess.dir_exists_absolute(path.get_base_dir()):
		var error := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		if error != OK:
			push_error("Couldn't create save directory: %s"%error_string(error))
	if !DirAccess.dir_exists_absolute(path.get_base_dir()):
		var error := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		if error != OK:
			push_error("Couldn't create save directory: %s"%error_string(error))
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
	if old_file == null:
		push_error("Unable to read temp while deleting data!")
		return
	var new_file := FileAccess.create_temp(FileAccess.WRITE, _TEMP_FILE_PREFIX)
	if new_file == null:
		push_error("Couldn't create new temp while deleting data: %s"%FileAccess.get_open_error())
		return
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
	if old_file.is_open(): old_file.close()
	_temp_close()
	pending_writes.clear()

## Quickly saves with specified [param save_name] before restoring [member SAVE_PATH]
## Can specify a [param image] to be saved alongside it too.
func quicksave(save_name: String, image: Image = null) -> void:
	var current_path := SAVE_PATH
	set_save_path(save_name)
	save_to_binary()
	if image != null:
		write_save_image(image, save_name)
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

## Returns [FileAccess] for save file specified by [param save_name]
func get_file_by_name(save_name: String) -> FileAccess:
	if !save_name.is_valid_filename():
		return null
	var path := "%s/%s.%s"%[_SAVE_DIR, save_name, _SAVE_EXTENSION]
	if !DirAccess.dir_exists_absolute(path.get_base_dir()):
		return null
	if not FileAccess.file_exists(path):
		return null
	var save_file := FileAccess.open_compressed(SAVE_PATH, FileAccess.READ, COMPRESSION_MODE)
	if save_file == null:
		push_error("Error accessing file: %s"%error_string(FileAccess.get_open_error()))
		return null
	save_file.close()
	return save_file

## Gets header buffer from [param save_name]. Uses current save if left blank.
func _get_header_buffer(save_name: String = "") -> PackedByteArray:
	if save_name.is_empty():
		save_name = get_save_name()
	if save_name.is_empty():
		save_name = get_save_name()
	var file := get_file_by_name(save_name)
	if file == null:
		return []
	return read_header(file)

## Returns meta-name from header of [param save_name]. Uses current save if left blank.
func get_header_name(save_name: String = "") -> String:
	if save_name.is_empty():
		save_name = get_save_name()
	var buffer := _get_header_buffer(save_name)
	if buffer.is_empty():
		return ""
	return PersistEncoder.decode_string(buffer, 0)[0]

## Returns game version from header of [param save_name]. Uses current save if left blank.
func get_header_game_version(save_name: String = "") -> String:
	if save_name.is_empty():
		save_name = get_save_name()
	var buffer := _get_header_buffer(save_name)
	if buffer.is_empty():
		return ""
	var offset: int = 32
	return PersistEncoder.decode_string(buffer, offset)[0]

## Returns save time from header of [param save_name]. Uses current save if left blank.
func get_header_unix_save_time(save_name: String = "") -> float:
	if save_name.is_empty():
		save_name = get_save_name()
	var buffer := _get_header_buffer(save_name)
	if buffer.is_empty():
		return 0.0
	var offset: int = 48
	return buffer.decode_double(offset)

## Creates and save image for [param save_name]. Uses current save if left blank.
## Leave [param image] blank to just erase image from that save
func write_save_image(image: Image, save_name: String = "") -> void:
	if save_name.is_empty():
		save_name = get_save_name()
	var path := SAVE_PATH.get_basename() + ".png"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	if image != null:
		var error := image.save_png(path)
		if error != OK:
			push_error("Unable to write save image: %s"%error_string(error))

## Returns image related to [param save_name]. Uses current save if left blank.
func get_save_image(save_name: String = "") -> ImageTexture:
	if save_name.is_empty():
		save_name = get_save_name()
	var path := SAVE_PATH.get_basename() + ".png"
	if !FileAccess.file_exists(path):
		return null
	var image := Image.load_from_file(path)
	if image == null:
		return null
	return ImageTexture.create_from_image(image)

## Stores a quick save for current save in autosave subdir relative to save
func autosave(image: Image = null) -> void:
	var path: String
	# Seperate subdir (if any)
	var split: PackedStringArray = get_save_name().split("/")
	if split.size() > 0: split.remove_at(split.size() - 1)
	for dir in split:
		path += dir + "/"
	var save_name := "autosave/autosave"
	quicksave(path + save_name, image)

## Returns true if save exists
func save_exists(save_name: String = "") -> bool:
	if save_name.is_empty():
		save_name = get_save_name()
	var path := "%s/%s.%s"%[_SAVE_DIR, save_name, _SAVE_EXTENSION]
	return FileAccess.file_exists(path)

## Deletes specified save
func erase_save(save_name: String = "") -> void:
	if save_name.is_empty():
		save_name = get_save_name()
	var path := "%s/%s.%s"%[_SAVE_DIR, save_name, _SAVE_EXTENSION]
	if FileAccess.file_exists(path):
		var error := DirAccess.remove_absolute(path)
		if error != OK:
			push_error("Couldn't erase save: %s"%error_string(error))
