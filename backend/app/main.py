from fastapi import FastAPI
from api.v1.health_routes import router as health_router
from api.v1.reports import router as report_router


app = FastAPI()
app.include_router(health_router)
app.include_router(report_router)