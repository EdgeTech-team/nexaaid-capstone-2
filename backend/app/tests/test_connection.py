from sqlalchemy import text
from database import engine

with engine.connect() as conn:
    result = conn.execute(text("SELECT 1"))
    print("Connected! Test query returned:", result.scalar())
