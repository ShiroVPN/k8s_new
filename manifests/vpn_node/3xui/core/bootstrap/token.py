import hashlib
import os
import sqlite3
import time

DATABASE = "/etc/x-ui/x-ui.db"
TOKEN_NAME = "shiro"

token = hashlib.sha256(os.environ["XUI_TOKEN"].encode()).hexdigest()

database = sqlite3.connect(DATABASE)
database.execute(
    "INSERT OR REPLACE INTO api_tokens (name, token, enabled, created_at, scope, expires_at)"
    " VALUES (?, ?, 1, ?, 'admin', 0)",
    (TOKEN_NAME, token, int(time.time())),
)
database.commit()
