extends GutTest

const TEST_TEMP_PATH: String = "user://save.tmp"
const TEST_SAVE_PATH: String = "user://save.bin"

var test_root: Node

class TestHealthNode extends PersistNode:
	var health: int = 0

func before_each() -> void:
	Persist.registry.clear()
	Persist.pending_writes.clear()
	Persist.context = &""
	_delete_file(TEST_TEMP_PATH)
	_delete_file(TEST_SAVE_PATH)
	test_root = Node.new()
	add_child_autofree(test_root)

func after_each() -> void:
	_delete_file(TEST_TEMP_PATH)
	_delete_file(TEST_SAVE_PATH)

func _delete_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

func _make_node(context: StringName, health_value: int, node_name: String = "") -> PersistNode:
	Persist.set_context(context)
	var node := TestHealthNode.new()
	node.properties = ["health"]
	node.set("health", health_value)
	if node_name != "":
		node.name = node_name
	test_root.add_child(node)
	return node

func test_set_context_changes_context() -> void:
	Persist.set_context(&"level_1")
	assert_eq(Persist.context, &"level_1")

func test_register_and_unregister_node() -> void:
	var node: PersistNode = _make_node(&"context_a", 10)
	assert_true(Persist.registry[&"context_a"].has(node.initial_path))
	test_root.remove_child(node)
	assert_false(Persist.registry[&"context_a"].has(node.initial_path))
	node.free()

func test_flush_pending_writes_creates_temp_file() -> void:
	var node: PersistNode = _make_node(&"context_a", 10)
	test_root.remove_child(node)
	Persist.flush_pending_writes()
	assert_true(FileAccess.file_exists(TEST_TEMP_PATH))
	node.free()

func test_flush_pending_writes_clears_buffer() -> void:
	var node: PersistNode = _make_node(&"context_a", 10)
	test_root.remove_child(node)
	Persist.flush_pending_writes()
	assert_true(Persist.pending_writes.is_empty())
	node.free()

func test_read_temp_index_after_flush() -> void:
	var node: PersistNode = _make_node(&"context_a", 10)
	test_root.remove_child(node)
	Persist.flush_pending_writes()
	var index: Dictionary = Persist.read_temp_index()
	assert_true(index.has(&"context_a"))
	node.free()

func test_flush_preserves_untouched_contexts() -> void:
	var node_a: PersistNode = _make_node(&"context_a", 1)
	test_root.remove_child(node_a)
	Persist.flush_pending_writes()

	var node_b: PersistNode = _make_node(&"context_b", 2)
	test_root.remove_child(node_b)
	Persist.flush_pending_writes()

	var index: Dictionary = Persist.read_temp_index()
	assert_true(index.has(&"context_a"))
	assert_true(index.has(&"context_b"))
	node_a.free()
	node_b.free()

func test_load_context_restores_live_node() -> void:
	var node: PersistNode = _make_node(&"context_a", 55)
	test_root.remove_child(node)
	Persist.flush_pending_writes()

	test_root.add_child(node)
	node.set("health", 0)
	Persist.load_context(&"context_a")
	assert_eq(node.get("health"), 55)
	node.free()

func test_load_context_does_nothing_for_missing_context() -> void:
	Persist.load_context(&"nonexistent_context")
	pass_test("no crash on missing context")

func test_flush_all_snapshots_live_nodes() -> void:
	var node: PersistNode = _make_node(&"context_a", 77)
	Persist.flush_all()
	var index: Dictionary = Persist.read_temp_index()
	assert_true(index.has(&"context_a"))
	node.free()

func test_save_to_binary_creates_save_file() -> void:
	var node: PersistNode = _make_node(&"context_a", 5)
	Persist.save_to_binary()
	assert_true(FileAccess.file_exists(TEST_SAVE_PATH))
	node.free()

func test_load_from_binary_copies_to_temp() -> void:
	var node: PersistNode = _make_node(&"context_a", 5)
	Persist.save_to_binary()

	_delete_file(TEST_TEMP_PATH)
	Persist.load_from_binary()
	assert_true(FileAccess.file_exists(TEST_TEMP_PATH))
	node.free()

func test_full_save_and_load_round_trip() -> void:
	var node: PersistNode = _make_node(&"context_a", 123, "persist_test_node")
	Persist.save_to_binary()
	test_root.remove_child(node)
	node.free()

	_delete_file(TEST_TEMP_PATH)
	Persist.load_from_binary()

	var new_node := TestHealthNode.new()
	new_node.name = "persist_test_node"
	new_node.properties = ["health"]
	new_node.set("health", 0)
	Persist.set_context(&"context_a")
	test_root.add_child(new_node)

	Persist.load_context(&"context_a")
	assert_eq(new_node.get("health"), 123)
	new_node.free()
