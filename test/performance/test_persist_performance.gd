extends GutTest

# ~1GB across 50 contexts, run manually — not for regular CI suite
const CONTEXT_COUNT: int = 50
const BYTES_PER_CONTEXT: int = 20 * 1024 * 1024  # 20MB * 50 = ~1GB
var TEMP_PATH: String:
	get: return Persist.TEMP_PATH
var SAVE_PATH: String:
	get: return Persist.SAVE_PATH

class FakeBlobNode extends PersistNode:
	var blob: PackedByteArray

var fake_nodes: Array[FakeBlobNode] = []

func before_each() -> void:
	Persist.registry.clear()
	Persist.pending_writes.clear()
	_delete_file(TEMP_PATH)
	_delete_file(SAVE_PATH)
	fake_nodes.clear()

func after_each() -> void:
	for node in fake_nodes:
		node.free()
	fake_nodes.clear()
	_delete_file(TEMP_PATH)
	_delete_file(SAVE_PATH)

func _delete_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

# marker bytes at start/end so we can verify integrity without hashing the whole blob
func _make_blob(context_index: int) -> PackedByteArray:
	var blob := PackedByteArray()
	blob.resize(BYTES_PER_CONTEXT)
	blob[0] = context_index
	blob[blob.size() - 1] = context_index
	return blob

func test_large_file_save_load_performance() -> void:
	var context_names: Array[StringName] = []
	var blob_by_context: Dictionary = {}

	# build fake data directly into pending_writes, bypassing node lifecycle
	for i in range(CONTEXT_COUNT):
		var context_name: StringName = StringName("context_%d" % i)
		var path := NodePath("fake_node_%d" % i)
		var blob: PackedByteArray = _make_blob(i)
		context_names.append(context_name)
		blob_by_context[context_name] = blob
		Persist.pending_writes[context_name] = {StringName(path): {"blob": blob}}

		# live node for later restore-correctness check
		var node := FakeBlobNode.new()
		node.context = context_name
		node.index_name = StringName(path)
		node.properties = ["blob"]
		node.root = node
		fake_nodes.append(node)
		Persist.register_node(node)

	# --- generate the fake ~1GB temp file via real flush path ---
	var flush_start: int = Time.get_ticks_msec()
	Persist.flush_pending_writes()
	var flush_elapsed: int = Time.get_ticks_msec() - flush_start
	gut.p("flush_pending_writes (%d contexts, ~1GB): %d ms" % [CONTEXT_COUNT, flush_elapsed])

	assert_true(FileAccess.file_exists(TEMP_PATH))
	var file_size: int = FileAccess.open(TEMP_PATH, FileAccess.READ).get_length()
	gut.p("resulting temp file size: %.2f MB" % (file_size / 1024.0 / 1024.0))
	assert_true(file_size > 900 * 1024 * 1024, "expected file roughly 1GB")

	# --- index read performance ---
	var index_start: int = Time.get_ticks_msec()
	var index: Dictionary = Persist.read_temp_index()
	var index_elapsed: int = Time.get_ticks_msec() - index_start
	gut.p("read_temp_index: %d ms" % index_elapsed)
	assert_eq(index.size(), CONTEXT_COUNT)

	# --- per-context load performance ---
	var total_load_elapsed: int = 0
	for context_name in context_names:
		var load_start: int = Time.get_ticks_msec()
		Persist.load_context(context_name)
		total_load_elapsed += Time.get_ticks_msec() - load_start
	gut.p("load_context total (%d contexts): %d ms, avg %.2f ms" % [
		CONTEXT_COUNT, total_load_elapsed, float(total_load_elapsed) / CONTEXT_COUNT
	])

	# spot check restore correctness on a few contexts, not all (cheap sample)
	for i in [0, CONTEXT_COUNT / 2, CONTEXT_COUNT - 1]:
		var node: FakeBlobNode = fake_nodes[i]
		assert_eq(node.blob.size(), BYTES_PER_CONTEXT)
		assert_eq(node.blob[0], i)
		assert_eq(node.blob[node.blob.size() - 1], i)

	# --- final save (flush_all snapshots live nodes, then copies to save.bin) ---
	var save_start: int = Time.get_ticks_msec()
	Persist.save_to_binary()
	var save_elapsed: int = Time.get_ticks_msec() - save_start
	gut.p("save_to_binary: %d ms" % save_elapsed)
	assert_true(FileAccess.file_exists(SAVE_PATH))

	# --- load_from_binary (copy save file back into temp) ---
	_delete_file(TEMP_PATH)
	var load_binary_start: int = Time.get_ticks_msec()
	Persist.load_from_binary()
	var load_binary_elapsed: int = Time.get_ticks_msec() - load_binary_start
	gut.p("load_from_binary: %d ms" % load_binary_elapsed)
	assert_true(FileAccess.file_exists(TEMP_PATH))

	# round-trip integrity check after full save/load cycle
	for node in fake_nodes:
		node.blob = PackedByteArray()  # clear before re-loading
	var sample_context: StringName = context_names[0]
	Persist.load_context(sample_context)
	assert_eq(fake_nodes[0].blob.size(), BYTES_PER_CONTEXT)
	assert_eq(fake_nodes[0].blob[0], 0)
