class_name Help
extends Node2D

signal back_pressed

@onready var _left_button: DigitButton = $LeftButton
@onready var _right_button: DigitButton = $RightButton
@onready var _pages: Node2D = $Pages

# Noble Family variant, todo §C.29: the 4 variant pages live in the scene ALWAYS; this flag decides
# whether they are reachable. `application.gd` pins it on EVERY page open from `Main.noble_family`
# (the same "re-pin on every open" rule the stats page uses), so a Start-page Help can never show
# variant rules and a Pause Help inside a variant game always can. It is a property SETTER, not a
# plain var, because the filter must re-run the moment the mode changes: a page opened in a variant
# game at page 10 and re-opened in a classic game must not stay parked on a hidden page.
var variant_active: bool = false:
	set(value):
		variant_active = value
		update_pages()

var _active_page: int = 0:
	set(value):
		_active_page = value
		update_pages()

var invoker: Node2D

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	update_pages()


func _on_back_button_pressed() -> void:
	hide()
	#_active_page = 0
	back_pressed.emit()


func _on_left_button_pressed() -> void:
	var reach: Array = reachable_pages()
	reach.reverse()  # `Array.reverse()` mutates in place and returns nothing, so it cannot inline
	for i in reach:
		if i < _active_page:
			_active_page = i
			return


func _on_right_button_pressed() -> void:
	for i in reachable_pages():
		if i > _active_page:
			_active_page = i
			return


# The page indices the player can reach in the CURRENT mode: every page, minus the `variant_only`
# ones while no variant game is active. Ascending, so "the page below/above" is a scan of this list.
func reachable_pages() -> Array:
	var out: Array = []
	for i in _pages.get_child_count():
		if is_reachable(i):
			out.append(i)
	return out


func is_reachable(i: int) -> bool:
	return variant_active or _pages.get_child(i).get("variant_only") != true


func update_pages() -> void:
	var reach: Array = reachable_pages()
	if reach.is_empty():
		return  # impossible while any classic page exists; a page list with no pages shows nothing
	if not reach.has(_active_page):
		# Clamp to the NEAREST reachable page (the classic page below a variant page), never to a
		# hidden index and never to 0. The assignment re-enters this function once and stops,
		# because the new value IS reachable, so the clamp cannot recurse.
		var nearest: int = reach[reach.size() - 1]
		for i in reach:
			if i <= _active_page:
				nearest = i
			else:
				break
		_active_page = nearest
	for i in _pages.get_child_count():
		_pages.get_child(i).visible = i == _active_page
	_left_button.visible = _active_page > reach[0]
	_right_button.visible = _active_page < reach[reach.size() - 1]
