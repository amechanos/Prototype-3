extends Resource

enum face {NONE, JACK, QUEEN, KING, JOKER}
enum eq {NONE, MINUS, MULTIPLICATION, DIVISION}

@export var value: int = 1 # 0  if powerup
@export var type: face
@export var operation: eq
@export var texture: Texture2D
