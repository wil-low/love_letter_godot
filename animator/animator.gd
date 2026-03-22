extends Node

@export var _speed: float = 0.5


class _WaitAll:
	extends RefCounted
	signal finished
	var remaining: int
	
	func _init(_remaining: int) -> void:
		remaining = _remaining



func _d(base: float) -> float:
	return base / _speed


func delay(t: float) -> Signal:
	return get_tree().create_timer(_d(t)).timeout


func _immediate() -> Signal:
	return get_tree().create_timer(0).timeout


func all(signals: Array[Signal]) -> Signal:
	if signals.is_empty():
		return _immediate()
	var waiter = _WaitAll.new(signals.size())
	for s in signals:
		s.connect(func():
			waiter.remaining -= 1
			if waiter.remaining == 0:
				waiter.finished.emit()
		, CONNECT_ONE_SHOT)
	return waiter.finished


func flip(card: Card, to_faceup: bool) -> Signal:
	if card.faceup != to_faceup:
		var pos = card.position
		var width = card._sprite.get_rect().size.x
		var tw = create_tween().set_trans(Tween.TRANS_SINE)
		tw.tween_property(card, "position:x", pos.x + width / 2, _speed / 4)
		tw.parallel().tween_property(card, "scale:x", 0, _speed / 4)
		tw.tween_callback(func (): card.faceup = to_faceup)
		tw.tween_property(card, "scale:x", 1, _speed / 4)
		tw.parallel().tween_property(card, "position:x", pos.x, _speed / 4)
		tw.finished.connect(func (): card.position = pos)
		return tw.finished
	return _immediate()


func reveal_hand(p: Player, hide_afterwards: bool = true) -> Signal:
	if p.hand.get_child_count() > 0:
		var card: Card = p.hand.get_child(0)
		await Animator.flip(card, true)
		await Animator.delay(_speed)
		if hide_afterwards:
			await Animator.flip(card, false)
	return _immediate()


func move_card(card: Card, to_global: Vector2) -> Signal:
	var tw = create_tween().set_trans(Tween.TRANS_QUAD)
	tw.tween_property(card, "global_position", to_global, _speed / 2)
	return tw.finished
