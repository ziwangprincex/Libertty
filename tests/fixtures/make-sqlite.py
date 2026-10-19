# The SQLite block's test database: 450 users, an index, a view.
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL, avatar BLOB)")
db.execute("CREATE INDEX idx_users_name ON users(name)")
db.executemany("INSERT INTO users VALUES (?, ?, ?, ?)", [(i, f"user {i}", i - 0.5, bytes([i % 256]) * 4 if i % 3 == 0 else None) for i in range(1, 451)])
db.execute("CREATE VIEW top_users AS SELECT name, score FROM users WHERE score > 400")
# A cell too long for the grid, and the smallest integer (abs() of it traps).
db.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT, n INTEGER)")
db.execute("INSERT INTO notes VALUES (1, ?, -9223372036854775808)", ("x" * 50000,))
db.commit()
