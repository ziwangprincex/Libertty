#!/bin/sh
# Box drawing and block elements: lines must join across cells with no gaps.
printf 'light  ┌───┬───┐  heavy ┏━━━┳━━━┓  double ╔═══╦═══╗  round ╭───╮\r\n'
printf '       │ a │ b │        ┃ a ┃ b ┃         ║ a ║ b ║        │ x │\r\n'
printf '       ├───┼───┤        ┣━━━╋━━━┫         ╠═══╬═══╣        ╰───╯\r\n'
printf '       │ c │ d │        ┃ c ┃ d ┃         ║ c ║ d ║  mixed ┍━━┑╒══╕\r\n'
printf '       └───┴───┘        ┗━━━┻━━━┛         ╚═══╩═══╝        ┕━━┙╘══╛\r\n'
printf 'blocks ▁▂▃▄▅▆▇█  ▏▎▍▌▋▊▉█  ▀▄▌▐  ░▒▓█  ▖▗▘▙▚▛▜▝▞▟  ╱╲╳\r\n'
printf 'bars   ████████████████████████████████████████\r\n'
printf '       ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀\r\n'
printf 'htop   [||||||||||        ]  ▕▇▇▇▇▇▇▅▃▁    ▏\r\n'
