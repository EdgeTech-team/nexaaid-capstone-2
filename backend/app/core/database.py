from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, declarative_base
from core.config import settings
    
engine = create_engine(settings.DATABASE_URL, pool_pre_ping=True, pool_recycle=300,)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

def get_db():
    db = SessionLocal()
    try:
        yield db
        # Several routers only flush() and rely on this commit
        # (reports.py, deliveries.py) — without it their writes were lost.
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()
