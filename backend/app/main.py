from fastapi import FastAPI
from api.v1.health_routes import router as health_router
from api.v1.donation_routes import router as donation_router
from api.v1.receiving_routes import router as receiving_router


app = FastAPI()
app.include_router(health_router)
app.include_router(donation_router)
app.include_router(receiving_router)