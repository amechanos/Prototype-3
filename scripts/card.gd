extends Resource

enum type {NONE, JACK, QUEEN, KING, JOKER, MINUS, MULTIPLICATION, DIVISION}

@export var value: int = 1 # 0  if powerup
@export var data: type
@export var texture: Texture2D
