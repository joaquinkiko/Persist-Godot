extends GutTest

var test_root: Node
var test_node: PersistNode

class TestHealthNode extends PersistNode:
	var health: int = 0

func before_each() -> void:
	Persist.registry.clear()
	Persist.pending_writes.clear()
	Persist.context = &"test_context"
	test_root = Node.new()
	add_child_autofree(test_root)

	test_node = TestHealthNode.new()
	test_node.root = test_node
	test_node.properties = ["health"]
	test_node.set("health", 0)

func test_enter_tree_assigns_loaded_context() -> void:
	test_root.add_child(test_node)
	assert_eq(test_node.context, &"test_context")

func test_enter_tree_registers_node() -> void:
	test_root.add_child(test_node)
	assert_true(Persist.registry.has(&"test_context"))
	assert_true(Persist.registry[&"test_context"].has(test_node.index_name))

func test_exit_tree_unregisters_node() -> void:
	test_root.add_child(test_node)
	var path := StringName(test_node.index_name)
	test_root.remove_child(test_node)
	assert_false(Persist.registry[&"test_context"].has(path))
	test_node.free()

func test_exit_tree_queues_pending_write() -> void:
	test_root.add_child(test_node)
	test_node.set("health", 42)
	var path := StringName(test_node.index_name)
	test_root.remove_child(test_node)
	assert_true(Persist.pending_writes.has(&"test_context"))
	assert_eq(Persist.pending_writes[&"test_context"][path]["health"], 42)
	test_node.free()

func test_save_returns_only_listed_properties() -> void:
	test_node.set("health", 10)
	var data: Dictionary = test_node.get_state()
	assert_eq(data.size(), 1)
	assert_eq(data["health"], 10)

func test_restore_sets_properties() -> void:
	test_node.set_state({"health": 99})
	assert_eq(test_node.get("health"), 99)

func test_raise_error_for_missing_properties() -> void:
	test_node.properties.append("INVALID")
	test_node._validate_properties()
	assert_push_error_count(1)
	assert_false(test_node.properties.has("INVALID"))

func test_raise_error_for_object_properties() -> void:
	test_node.properties.append("root")
	test_node._validate_properties()
	assert_push_error_count(1)
	assert_false(test_node.properties.has("INVALID"))

func test_restore_ignores_unknown_keys() -> void:
	test_node.set_state({"health": 5, "nonexistent_property": true})
	assert_eq(test_node.get("health"), 5)

func test_save_restore_targets_explicit_root() -> void:
	var external_target := TestHealthNode.new()
	add_child_autofree(external_target)
	external_target.set("health", 0)

	test_node.root = external_target
	test_node.set("health", 77)  # sets on test_node itself, irrelevant now
	var data: Dictionary = test_node.get_state()
	assert_eq(data["health"], 0, "save should read from root, not self")

	test_node.set_state({"health": 55})
	assert_eq(external_target.get("health"), 55, "restore should write to root, not self")
