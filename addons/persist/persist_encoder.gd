## Manual binary encoder/decoder for Persist's save data
class_name PersistEncoder

enum Type {
	NIL = TYPE_NIL,
	BOOL = TYPE_BOOL,
	INT = TYPE_INT,
	FLOAT = TYPE_FLOAT,
	STRING = TYPE_STRING,
	STRING_NAME = TYPE_STRING_NAME,
	VECTOR2 = TYPE_VECTOR2,
	VECTOR3 = TYPE_VECTOR3,
	VECTOR4 = TYPE_VECTOR4,
	COLOR = TYPE_COLOR,
	ARRAY = TYPE_ARRAY,
	DICTIONARY = TYPE_DICTIONARY,
	PACKED_BYTE_ARRAY = TYPE_PACKED_BYTE_ARRAY,
	VECTOR2I = TYPE_VECTOR2I,
	VECTOR3I = TYPE_VECTOR3I,
	VECTOR4I = TYPE_VECTOR4I,
	QUATERNION = TYPE_QUATERNION,
	TRANSFORM2D = TYPE_TRANSFORM2D,
	TRANSFORM3D = TYPE_TRANSFORM3D,
	PACKED_INT32_ARRAY = TYPE_PACKED_INT32_ARRAY,
	PACKED_INT64_ARRAY = TYPE_PACKED_INT64_ARRAY,
	PACKED_FLOAT32_ARRAY = TYPE_PACKED_FLOAT32_ARRAY,
	PACKED_FLOAT64_ARRAY = TYPE_PACKED_FLOAT64_ARRAY,
	PACKED_STRING_ARRAY = TYPE_PACKED_STRING_ARRAY,
	VARIANT = TYPE_MAX,
}

const _CONTINUE_BIT := 0x80
const _PAYLOAD_MASK := 0x7F

const _FLAG_SINGLE := 0
const _FLAG_DOUBLE := 1

## Encodes any supported variant into tagged bytes.
static func encode_variant(value) -> PackedByteArray:
	var out := PackedByteArray()
	match typeof(value):
		TYPE_NIL:
			out.append(Type.NIL)
		TYPE_BOOL:
			out.append(Type.BOOL)
			out.append(1 if value else 0)
		TYPE_INT:
			out.append(Type.INT)
			out.append_array(encode_varint(value))
		TYPE_FLOAT:
			out.append(Type.FLOAT)
			out.append_array(encode_floats([value]))
		TYPE_STRING:
			out.append(Type.STRING)
			out.append_array(encode_string(value))
		TYPE_STRING_NAME:
			out.append(Type.STRING_NAME)
			out.append_array(encode_string(String(value)))
		TYPE_VECTOR2:
			out.append(Type.VECTOR2)
			out.append_array(encode_floats([value.x, value.y]))
		TYPE_VECTOR3:
			out.append(Type.VECTOR3)
			out.append_array(encode_floats([value.x, value.y, value.z]))
		TYPE_VECTOR4:
			out.append(Type.VECTOR4)
			out.append_array(encode_floats([value.x, value.y, value.z, value.w]))
		TYPE_COLOR:
			out.append(Type.COLOR)
			out.append_array(encode_floats([value.r, value.g, value.b, value.a]))
		TYPE_ARRAY:
			out.append(Type.ARRAY)
			out.append_array(encode_varint(value.size()))
			for item in value:
				out.append_array(encode_variant(item))
		TYPE_DICTIONARY:
			out.append(Type.DICTIONARY)
			out.append_array(encode_dictionary(value))
		TYPE_PACKED_BYTE_ARRAY:
			out.append(Type.PACKED_BYTE_ARRAY)
			out.append_array(encode_varint(value.size()))
			out.append_array(value)
		TYPE_VECTOR2I:
			out.append(Type.VECTOR2I)
			out.append_array(encode_ints([value.x, value.y]))
		TYPE_VECTOR3I:
			out.append(Type.VECTOR3I)
			out.append_array(encode_ints([value.x, value.y, value.z]))
		TYPE_VECTOR4I:
			out.append(Type.VECTOR4I)
			out.append_array(encode_ints([value.x, value.y, value.z, value.w]))
		TYPE_QUATERNION:
			out.append(Type.QUATERNION)
			out.append_array(encode_floats([value.x, value.y, value.z, value.w]))
		TYPE_TRANSFORM2D:
			out.append(Type.TRANSFORM2D)
			out.append_array(encode_floats([
				value.x.x, value.x.y,
				value.y.x, value.y.y,
				value.origin.x, value.origin.y,
			]))
		TYPE_TRANSFORM3D:
			var basis: Basis = value.basis
			out.append(Type.TRANSFORM3D)
			out.append_array(encode_floats([
				basis.x.x, basis.x.y, basis.x.z,
				basis.y.x, basis.y.y, basis.y.z,
				basis.z.x, basis.z.y, basis.z.z,
				value.origin.x, value.origin.y, value.origin.z,
			]))
		TYPE_PACKED_INT32_ARRAY:
			out.append(Type.PACKED_INT32_ARRAY)
			out.append_array(encode_varint(value.size()))
			out.append_array(encode_ints(Array(value)))
		TYPE_PACKED_INT64_ARRAY:
			out.append(Type.PACKED_INT64_ARRAY)
			out.append_array(encode_varint(value.size()))
			out.append_array(encode_ints(Array(value)))
		TYPE_PACKED_FLOAT32_ARRAY:
			out.append(Type.PACKED_FLOAT32_ARRAY)
			out.append_array(encode_varint(value.size()))
			out.append_array(encode_floats(value, false))
		TYPE_PACKED_FLOAT64_ARRAY:
			out.append(Type.PACKED_FLOAT64_ARRAY)
			out.append_array(encode_varint(value.size()))
			out.append_array(encode_floats(value, true))
		TYPE_PACKED_STRING_ARRAY:
			out.append(Type.PACKED_STRING_ARRAY)
			out.append_array(encode_varint(value.size()))
			for text in value:
				out.append_array(encode_string(text))
		_:
			if _is_discarded(value):
				push_warning("Skipping attempt to encode unsupported type %s"%type_string(typeof(value)))
				out.append(Type.NIL)
			else:
				var encoded := var_to_bytes(value)
				out.append(Type.VARIANT)
				out.append_array(encode_varint(encoded.size()))
				out.append_array(encoded)
	return out

## Decodes a tagged variant starting at [param offset]. Returns [value, next_offset].
static func decode_variant(bytes: PackedByteArray, offset: int) -> Array:
	var tag: int = bytes[offset]
	offset += 1
	match tag:
		Type.NIL:
			return [null, offset]
		Type.BOOL:
			return [bytes[offset] == 1, offset + 1]
		Type.INT:
			return decode_varint(bytes, offset)
		Type.FLOAT:
			var result := decode_floats(bytes, offset, 1)
			return [result[0][0], result[1]]
		Type.STRING:
			return decode_string(bytes, offset)
		Type.STRING_NAME:
			var result := decode_string(bytes, offset)
			return [StringName(result[0]), result[1]]
		Type.VECTOR2:
			var result := decode_floats(bytes, offset, 2)
			return [Vector2(result[0][0], result[0][1]), result[1]]
		Type.VECTOR3:
			var result := decode_floats(bytes, offset, 3)
			return [Vector3(result[0][0], result[0][1], result[0][2]), result[1]]
		Type.VECTOR4:
			var result := decode_floats(bytes, offset, 4)
			return [Vector4(result[0][0], result[0][1], result[0][2], result[0][3]), result[1]]
		Type.COLOR:
			var result := decode_floats(bytes, offset, 4)
			return [Color(result[0][0], result[0][1], result[0][2], result[0][3]), result[1]]
		Type.ARRAY:
			var size_result := decode_varint(bytes, offset)
			var count: int = size_result[0]
			var position: int = size_result[1]
			var array_out := []
			for i in count:
				var item_result := decode_variant(bytes, position)
				array_out.append(item_result[0])
				position = item_result[1]
			return [array_out, position]
		Type.DICTIONARY:
			return decode_dictionary(bytes, offset)
		Type.PACKED_BYTE_ARRAY:
			var size_result := decode_varint(bytes, offset)
			var count: int = size_result[0]
			var position: int = size_result[1]
			return [bytes.slice(position, position + count), position + count]
		Type.VARIANT:
			var size_result := decode_varint(bytes, offset)
			var length: int = size_result[0]
			var position: int = size_result[1]
			return [bytes_to_var(bytes.slice(position, position + length)), position + length]
		Type.VECTOR2I:
			var result := decode_ints(bytes, offset, 2)
			return [Vector2i(result[0][0], result[0][1]), result[1]]
		Type.VECTOR3I:
			var result := decode_ints(bytes, offset, 3)
			return [Vector3i(result[0][0], result[0][1], result[0][2]), result[1]]
		Type.VECTOR4I:
			var result := decode_ints(bytes, offset, 4)
			return [Vector4i(result[0][0], result[0][1], result[0][2], result[0][3]), result[1]]
		Type.QUATERNION:
			var result := decode_floats(bytes, offset, 4)
			return [Quaternion(result[0][0], result[0][1], result[0][2], result[0][3]), result[1]]
		Type.TRANSFORM2D:
			var result := decode_floats(bytes, offset, 6)
			var values: Array = result[0]
			return [Transform2D(
				Vector2(values[0], values[1]),
				Vector2(values[2], values[3]),
				Vector2(values[4], values[5]),
			), result[1]]
		Type.TRANSFORM3D:
			var result := decode_floats(bytes, offset, 12)
			var values: Array = result[0]
			var basis := Basis(
				Vector3(values[0], values[1], values[2]),
				Vector3(values[3], values[4], values[5]),
				Vector3(values[6], values[7], values[8]),
			)
			return [Transform3D(basis, Vector3(values[9], values[10], values[11])), result[1]]
		Type.PACKED_INT32_ARRAY:
			var size_result := decode_varint(bytes, offset)
			var result := decode_ints(bytes, size_result[1], size_result[0])
			return [PackedInt32Array(result[0]), result[1]]
		Type.PACKED_INT64_ARRAY:
			var size_result := decode_varint(bytes, offset)
			var result := decode_ints(bytes, size_result[1], size_result[0])
			return [PackedInt64Array(result[0]), result[1]]
		Type.PACKED_FLOAT32_ARRAY:
			var size_result := decode_varint(bytes, offset)
			var result := decode_floats(bytes, size_result[1], size_result[0])
			return [PackedFloat32Array(result[0]), result[1]]
		Type.PACKED_FLOAT64_ARRAY:
			var size_result := decode_varint(bytes, offset)
			var result := decode_floats(bytes, size_result[1], size_result[0])
			return [PackedFloat32Array(result[0]), result[1]]
		Type.PACKED_STRING_ARRAY:
			var size_result := decode_varint(bytes, offset)
			var position: int = size_result[1]
			var strings := PackedStringArray()
			for index in size_result[0]:
				var string_result := decode_string(bytes, position)
				strings.append(string_result[0])
				position = string_result[1]
			return [strings, position]
		_:
			# Unknowns are silently skipped
			return [null, offset]

## Encodes a dictionary
static func encode_dictionary(dict: Dictionary) -> PackedByteArray:
	var body := PackedByteArray()
	var count := 0
	for key in dict.keys():
		if _is_discarded(key):
			push_warning("Skipping attempt to encode unsupported type %s"%type_string(typeof(key)))
			continue
		if _is_discarded(dict[key]):
			push_warning("Skipping attempt to encode unsupported type %s"%type_string(typeof(dict[key])))
			continue
		body.append_array(encode_variant(key))
		body.append_array(encode_variant(dict[key]))
		count += 1
	var out := PackedByteArray()
	out.append_array(encode_varint(count))
	out.append_array(body)
	return out

## Decodes a dictionary. Returns [dictionary, next_offset].
static func decode_dictionary(bytes: PackedByteArray, offset: int) -> Array:
	var size_result := decode_varint(bytes, offset)
	var count: int = size_result[0]
	var position: int = size_result[1]
	var result := {}
	for i in count:
		var key_result := decode_variant(bytes, position)
		position = key_result[1]
		var value_result := decode_variant(bytes, position)
		position = value_result[1]
		result[key_result[0]] = value_result[0]
	return [result, position]

## Zigzag + LEB128 varint. Small numbers cost 1 byte instead of 8.
static func encode_varint(value: int) -> PackedByteArray:
	var zigzag: int = (value << 1) ^ (value >> 63)
	var bytes := PackedByteArray()
	while true:
		var byte: int = zigzag & _PAYLOAD_MASK
		zigzag >>= 7
		if zigzag != 0:
			bytes.append(byte | _CONTINUE_BIT)
		else:
			bytes.append(byte)
			break
	return bytes

## Returns [value, next_offset].
static func decode_varint(bytes: PackedByteArray, offset: int) -> Array:
	var result: int = 0
	var shift: int = 0
	var position := offset
	while true:
		var byte: int = bytes[position]
		position += 1
		result |= (byte & _PAYLOAD_MASK) << shift
		if byte & _CONTINUE_BIT == 0:
			break
		shift += 7
	var value: int = (result >> 1) ^ -(result & 1)
	return [value, position]

## Encode UTF-8 string followed by ETX terminator.
static func encode_string(text: String) -> PackedByteArray:
	if text.contains(char(3)): # Replace any null terminators already in string
		text = text.replace(char(3), "")
	var out := text.to_utf8_buffer()
	out.append(0)
	return out

## Returns [string, next_offset].
static func decode_string(bytes: PackedByteArray, offset: int) -> Array:
	var terminator_position := bytes.find(0, offset)
	if terminator_position == -1:
		return ["", bytes.size()]
	var slice := bytes.slice(offset, terminator_position)
	return [slice.get_string_from_utf8(), terminator_position + 1]

## Flag specifying precision, then each value at that width.
## Precision based on engine settings, or by setting [param force_double]
static func encode_floats(values: Array, force_double: bool = false) -> PackedByteArray:
	var use_double := OS.has_feature("double") || force_double
	var byte_width := 8 if use_double else 4
	var bytes := PackedByteArray()
	bytes.resize(1 + byte_width * values.size())
	bytes[0] = _FLAG_DOUBLE if use_double else _FLAG_SINGLE
	for index in values.size():
		var position := 1 + index * byte_width
		if use_double:
			bytes.encode_double(position, values[index])
		else:
			bytes.encode_float(position, values[index])
	return bytes

## Returns [array_of_floats, next_offset].
static func decode_floats(bytes: PackedByteArray, offset: int, count: int) -> Array:
	var use_double: bool = bytes[offset] == _FLAG_DOUBLE
	var byte_width := 8 if use_double else 4
	var position := offset + 1
	var values := []
	for index in count:
		if use_double:
			values.append(bytes.decode_double(position))
		else:
			values.append(bytes.decode_float(position))
		position += byte_width
	return [values, position]

static func encode_ints(values: Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	for value in values:
		bytes.append_array(encode_varint(value))
	return bytes

## Returns [array_of_ints, next_offset].
static func decode_ints(bytes: PackedByteArray, offset: int, count: int) -> Array:
	var values := []
	var position := offset
	for index in count:
		var result := decode_varint(bytes, position)
		values.append(result[0])
		position = result[1]
	return [values, position]

## Types to be discarded by encoder
static func _is_discarded(value) -> bool:
	return typeof(value) in [TYPE_OBJECT, TYPE_CALLABLE, TYPE_SIGNAL]
