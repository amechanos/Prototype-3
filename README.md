# Blackjack

A Godot 4.8 project with an early LAN multiplayer lobby and a shared card-board
prototype.

## Requirements

- Godot 4.8

## Run the project

1. Open `project.godot` in Godot 4.8.
2. Run the project (F6 runs the current scene; F5 runs the configured main
   scene).
3. Select **Play** to open the card board offline.
4. For a shared LAN board, select **Host Game** on one device. Enter the host's
   LAN IPv4 address on the other device and select **Join Game**. The lobby
   also looks up the public IPv4 address for remote connections.
5. Once connected, the host selects **Play** to open the shared card board.
   Both players see the same shuffled board; collecting a card removes it for
   everyone and adds it to the collector's local deck.
6. Players take turns. On your turn, choose **Draw 3 face-down cards** or
   select one visible face-up special card. Number cards display `?` while
   face down.
7. After the board is empty, the host can select **Start Game** to send each
   player's collected cards and profile data through the `Global` autoload and
   open the table scene.

8. On the table, each round shows a weighted-random target (12-30). Click
   cards in the order you want them played; the equation reads left to right
   with x and / before - (no brackets). Neighbouring numbers are added by
   default, and each division rounds to the nearest whole number.
   Each round also has a 90 second limit; when it runs out, whatever you have
   selected is submitted automatically. Submit your hand: a 10 second timer
   starts for the other player when the
   first hand is submitted (the current selection is auto-sent at zero).
9. Closest to the target without going over wins the round. Ties and double
   busts go to the player who used the most cards. The winner discards the
   cards played; the loser keeps them. First player with an empty hand wins.
   If the shared discard pile has at least 12 cards, each player may pick up to
   three random number cards from it once per round, before submitting.

For table debugging, run `table.tscn` directly in a debug build. When no game
players are loaded, it starts an offline practice round with the full 50-card
deck. This debug setup is not used in release builds or LAN games.

Special cards: King (choose 1-10), Queen (value 1; if the opponent wins, each
Queen spares 50% of their discards, rounded down, so two Queens cancel the
discard; Face/Joker cards are spared
first), Jack (value 10; its player chooses to raise or lower the target by 3),
Joker (value 1; swaps your hand result with your opponent's). Queens and
Jokers are discarded as soon as they are played.

The lobby uses ENet over UDP port `7000` and accepts one remote player. For LAN
play, both devices need to be able to communicate over the local network. For
play across networks, give the joining player the host's public IPv4 address,
allow inbound UDP port `7000` in the host's firewall, and forward UDP port
`7000` from the host's router to the host device. Public Wi-Fi restrictions or
carrier-grade NAT can prevent direct connections; those networks require an
internet relay, which this prototype does not provide.

## Current scope

- Host or join a room using a LAN or public IPv4 address.
- Show the LAN address, look up the public IPv4 address, and display the
  connected player count.
- Report connection failures and disconnects.
- Shuffle and display the 50-card deck as labelled board buttons, then collect
  clicked cards into the collector's personal deck.
- Take turns drawing three concealed number cards or one visible special card;
  synchronize turns and draws over the existing LAN host connection.
- Show each player's collected cards in a single-row table hand, allow local
  card selection, and keep opponents' cards face down.
- No automatic LAN discovery, automatic port forwarding, or internet relay.

## Repository notes

No license has been selected. Add a license before granting permission for
others to reuse or distribute this project.
