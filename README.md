# Blackjack

A Godot 4.8 project with an early LAN multiplayer lobby for a two-player game.
The current project covers hosting and joining a room; blackjack gameplay and
networked game-state synchronization are not implemented yet.

## Requirements

- Godot 4.8

## Run the project

1. Open `project.godot` in Godot 4.8.
2. Run the project (F6 runs the current scene; F5 runs the configured main
   scene).
3. Select **Host Game** on one device. Enter the host's LAN IPv4 address on
   the other device and select **Join Game**.

The lobby uses ENet over UDP port `7000` and accepts one remote player. Both
devices need to be able to communicate over the local network. The host's
firewall may need to allow inbound UDP traffic on port `7000`.

## Current scope

- Host or join a LAN room using an IP address.
- Show the host's LAN address and the connected player count.
- Report connection failures and disconnects.
- No automatic LAN discovery, internet matchmaking, or gameplay/state sync yet.

## Repository notes

No license has been selected. Add a license before granting permission for
others to reuse or distribute this project.
