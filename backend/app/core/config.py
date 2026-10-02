import os
from dotenv import load_dotenv

load_dotenv()


def _required(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"{name} is not set. Check backend/app/.env")
    return value


class Settings:
    DATABASE_URL: str = _required("DATABASE_URL")
    DIRECT_URL: str | None = os.getenv("DIRECT_URL")   # only Alembic uses this
    SECRET_KEY: str = _required("SECRET_KEY")
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 60
    UPLOAD_DIR: str = os.getenv("UPLOAD_DIR", "var/uploads")
    MAX_UPLOAD_MB: int = int(os.getenv("MAX_UPLOAD_MB", "5"))


settings = Settings()