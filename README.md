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
   LAN IPv4 address on the other device and select **Join Game**.
5. Once connected, the host selects **Play** to open the shared card board.
   Both players see the same shuffled board; collecting a card removes it for
   everyone and adds it to the collector's local deck.
6. Players take turns. On your turn, choose **Draw 3 face-down cards** or
   select one visible face-up special card. Number cards display `?` while
   face down.
7. After the board is empty, the host can select **Start Game** to send each
   player's collected cards and profile data through the `Global` autoload and
   open the table scene.

The lobby uses ENet over UDP port `7000` and accepts one remote player. Both
devices need to be able to communicate over the local network. The host's
firewall may need to allow inbound UDP traffic on port `7000`.

## Current scope

- Host or join a LAN room using an IP address.
- Show the host's LAN address and the connected player count.
- Report connection failures and disconnects.
- Shuffle and display the 50-card deck as labelled board buttons, then collect
  clicked cards into the collector's personal deck.
- Take turns drawing three concealed number cards or one visible special card;
  synchronize turns and draws over the existing LAN host connection.
- Show each player's collected cards in a single-row table hand, allow local
  card selection, and keep opponents' cards face down.
- No automatic LAN discovery or internet matchmaking.

## Repository notes

No license has been selected. Add a license before granting permission for
others to reuse or distribute this project.
