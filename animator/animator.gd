extends Node

var _speed: float = 1  # set to 0 for speedrun with disabled rendering and console output

class _WaitAll:
	extends RefCounted
	signal finished
	var _remaining: int
	
	func _init(rem: int) -> void:
		_remaining = rem

	func dec() -> void:
		_remaining -= 1
		if _remaining == 0:
			finished.emit()


func _d(base: float) -> float:
	return base / _speed if _speed > 0 else 0.0


func delay(t: float) -> Signal:
	return get_tree().create_timer(_d(t)).timeout


func _immediate() -> Signal:
	return get_tree().create_timer(0).timeout


func all(signals: Array[Signal]) -> Signal:
	if signals.is_empty():
		return _immediate()
	var waiter = _WaitAll.new(signals.size())
	for s in signals:
		s.connect(func(): waiter.dec(), CONNECT_ONE_SHOT)
	return waiter.finished


func flip(card: Card, to_faceup: bool) -> Signal:
	if card.faceup != to_faceup:
		var pos = card.position
		var width = card._sprite.get_rect().size.x
		var tw = create_tween().set_trans(Tween.TRANS_SINE)
		tw.tween_property(card, "position:x", pos.x + width / 2, _d(0.25))
		tw.parallel().tween_property(card, "scale:x", 0, _d(0.25))
		tw.tween_callback(func (): card.faceup = to_faceup)
		tw.tween_property(card, "scale:x", 1, _d(0.25))
		tw.parallel().tween_property(card, "position:x", pos.x, _d(0.25))
		tw.finished.connect(func (): card.position = pos)
		return tw.finished
	return _immediate()


func reveal_hand(p: Player, hide_afterwards: bool = true) -> Signal:
	if p.hand.get_child_count() > 0:
		var card: Card = p.hand.get_child(0)
		await flip(card, true)
		await delay(1)
		if hide_afterwards:
			await flip(card, false)
	return _immediate()


func move_card(card: Card, to_global: Vector2, duration: float = 0.5) -> Signal:
	var tw = create_tween().set_trans(Tween.TRANS_QUAD)
	tw.tween_property(card, "global_position", to_global, _d(duration))
	return tw.finished
