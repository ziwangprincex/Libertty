### Throughput, MB/s (median sample; higher is better)

| benchmark | lumen | kitty | ghostty | otty | tern |
|---|---:|---:|---:|---:|---:|
| grid (cols×rows) | 120×40 | 120×40 | 123×42 | 97×31 | 160×45 |
| cursor_motion | 170 | 145 | 154 | 92 | **217** |
| dense_cells | 181 | 126 | 134 | 75 | **266** |
| light_cells | 139 | 154 | 132 | 101 | **272** |
| medium_cells | 143 | 83 | 110 | 85 | **209** |
| scrolling | **66** | 13 | 65 | 38 | 43 |
| scrolling_bottom_region | **69** | 37 | 55 | 27 | 51 |
| scrolling_bottom_small_region | **71** | 38 | 51 | 19 | 61 |
| scrolling_fullscreen | 138 | 127 | 131 | 115 | **221** |
| scrolling_top_region | **70** | 38 | 58 | 15 | 51 |
| scrolling_top_small_region | **70** | 38 | 59 | 33 | 59 |
| sync_medium_cells | **142** | 53 | 96 | 85 | 81 |
| unicode | 138 | 153 | 179 | 4 | **256** |

Geometric mean of throughput relative to the best per benchmark (1.00 = best everywhere):
- lumen: 0.79 over 12 benchmarks
- kitty: 0.48 over 12 benchmarks
- ghostty: 0.68 over 12 benchmarks
- otty: 0.30 over 12 benchmarks
- tern: 0.85 over 12 benchmarks

### Median ms per sample (lower is better; only comparable at equal grid sizes)

| benchmark | lumen | kitty | ghostty | otty | tern |
|---|---:|---:|---:|---:|---:|
| grid (cols×rows) | 120×40 | 120×40 | 123×42 | 97×31 | 160×45 |
| cursor_motion | 52 | 61 | 62 | 97 | **40** |
| dense_cells | 56 | 80 | 81 | 113 | **38** |
| light_cells | 61 | 55 | 64 | 84 | **31** |
| medium_cells | 60 | 103 | 78 | 101 | **41** |
| scrolling | **127** | 660 | 130 | 219 | 193 |
| scrolling_bottom_region | **121** | 224 | 152 | 315 | 164 |
| scrolling_bottom_small_region | **118** | 220 | 163 | 450 | 138 |
| scrolling_fullscreen | 61 | 66 | 64 | 73 | **38** |
| scrolling_top_region | **120** | 223.5 | 144 | 562 | 165 |
| scrolling_top_small_region | **119** | 220 | 142 | 255 | 142 |
| sync_medium_cells | **60** | 162 | 89 | 100 | 105 |
| unicode | 61 | 55 | 47 | 2323 | **33** |

