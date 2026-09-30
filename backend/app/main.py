from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from api.v1.health_routes import router as health_router
from api.v1.dashboard_routes import router as dashboard_router
from api.v1.reports import router as report_router
from api.v1.deliveries import router as delivery_router
from api.v1.donation_routes import router as donation_router
from api.v1.receiving_routes import router as receiving_router
from api.v1.auth_router import router as auth_router
from api.v1.admin_router import router as admin_router
from api.v1.cmo_router import router as cmo_router
from api.v1.logistics_router import router as logistics_router
from api.v1.drrmo_router import router as drrmo_router
from api.v1.lookup_routes import router as lookup_router

app = FastAPI()

# DEV ONLY: lets the Flutter test app (Chrome / emulator) call the API.
# Tighten allow_origins before deployment.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health_router)
app.include_router(dashboard_router)
app.include_router(report_router)
app.include_router(delivery_router)
app.include_router(donation_router)
app.include_router(receiving_router)
app.include_router(auth_router)
app.include_router(admin_router)
app.include_router(cmo_router)
app.include_router(logistics_router)
app.include_router(drrmo_router)
app.include_router(lookup_router)
