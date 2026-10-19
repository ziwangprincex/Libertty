# The notebook probe's notebook: Markdown (with a script that must not run
# or show), a print, an expression, an error.
import json, sys
def cell(kind, source, **extra):
    c = {"cell_type": kind, "id": f"c{len(cells)}", "metadata": {}, "source": source}
    if kind == "code": c.update(outputs=[], execution_count=None)
    return c
cells = []
cells.append(cell("markdown", "# Probe Title\n\nSome **bold** text.<script>alert('owned')</script>"))
cells.append(cell("code", "print(6 * 7)"))
cells.append(cell("code", "x = 1 + 1\nx"))
cells.append(cell("code", "1 / 0"))
nb = {"cells": cells, "metadata": {"kernelspec": {"name": "python3", "display_name": "Python 3", "language": "python"}}, "nbformat": 4, "nbformat_minor": 5}
json.dump(nb, open(sys.argv[1], "w"), indent=1)
