import os
from dotenv import load_dotenv

load_dotenv()

class Settings:
    DATABASE_URL: str = os.getenv("DATABASE_URL")
    DIRECT_URL: str = os.getenv("DIRECT_URL")
    SECRET_KEY: str = os.getenv("SECRET_KEY")
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 60

    # Email (temporary-password delivery)
    # EMAIL_DEV_MODE=true  -> email is PRINTED in the uvicorn terminal, nothing is sent
    # EMAIL_DEV_MODE=false -> real SMTP send (set the SMTP_* values)
    EMAIL_DEV_MODE: bool = os.getenv("EMAIL_DEV_MODE", "true").lower() == "true"
    SMTP_HOST: str = os.getenv("SMTP_HOST", "")
    SMTP_PORT: int = int(os.getenv("SMTP_PORT", "587"))
    SMTP_USER: str = os.getenv("SMTP_USER", "")
    SMTP_PASSWORD: str = os.getenv("SMTP_PASSWORD", "")
    SMTP_FROM: str = os.getenv("SMTP_FROM") or os.getenv("SMTP_USER", "")

settings = Settings()