extends VBoxContainer

@onready var heading = $Heading
@onready var body = $Body
@onready var page_count = $HBoxContainer/Page

var current_page = 0

const text: Array[Array] = [
	["Deckbuilding", "Be the first player to get rid of every card in your hand. \n\nA shuffled board of cards is shared by both players. Number cards are face down (shown as ?), and special cards are face up. \n\nPlayers take turns. On your turn, either draw 3 face-down cards or take 1 visible special card. The game starts when the board is empty."],
	["The Main Round", "Each round shows a target number between 12 and 30. Click cards in your hand in the order you want to play them. The equation builds in the middle of the screen. \n\nTurn hard mode on to hide the result (Not reccomended for new players!). \n\nPress Submit when you're ready. You have 90 seconds per round. When the first player submits, the other player has 10 seconds left. When time runs out, the hand is submitted automatically."],
	["Building Equations", "Cards are read left to right while also following BODMAS. There are no brackets within the game. \n\nThe default operation between two numbers is addition. \n\nDivision rounds to the nearest whole number. Your equation can't end on an operator. An invalid equation scores 0 and plays no cards."],
	["Winning a Round", "Get as close as you can to the target without going over, similar to Blackjack. \n\nBoth Under - Closer Wins \n\nOne Busts - Under Wins \n\nBoth Bust - Closer Wins \n\nTie - Player who uses more cards win \n\nDead Tie - Draw \n\nThe winner discards the cards they played. The loser keeps theirs."],
	["Special cards", "All face cards have special abilities. \n\nKing (Variable) - The card becomes any number from 1 to 10 of your liking. \n\nQueen (0) - Double-edged. If either player plays a Queen, the last two number cards in both players’ equations are voided and don’t count toward the result. The Queen itself adds nothing. \n\nJack (10) - Increase or decrease the target number by 3. Stackable. \n\nJoker (1) - Swaps your submitted hand for the opponents and vice versa. \n\nOperations perform their respective operations (division, multiplication, minus). Queens and Jokers are always discarded when they are played, even if you lose."],
	["Discard pile", "The discard pile is a special function that opens up when 12 cards or more have been discarded. \n\nThe discard pile's purpose is to alieviate players who might find themselves soft-locked with multiple operation or face cards with no number cards. \n\nChoosing to pick-up from the discard pile gives the player 3 cards and costs their turn. \n\nRemember, the goal is to get rid of all your cards! Don't click pick-up when you don't need to!"],
]

func _on_prev_pressed() -> void:
	if current_page > 0:
		current_page -= 1
	else:
		current_page = text.size()-1
	heading.text = text[current_page][0]
	body.text = text[current_page][1]
	page_count.text = "Page %d/%d" % [current_page+1, text.size()]

func _on_next_pressed() -> void:
	if current_page < text.size()-1:
		current_page += 1
	else:
		current_page = 0
	heading.text = text[current_page][0]
	body.text = text[current_page][1]
	page_count.text = "Page %d/%d" % [current_page+1, text.size()]
	
func _ready() -> void:
	heading.text = text[current_page][0]
	body.text = text[current_page][1]
	page_count.text = "Page %d/%d" % [current_page+1, text.size()]
